# ansible-zabbix: PostgreSQL/Patroni backend + HA design

## Goal

Modify `ansible-zabbix` so that:

1. `zabbix-server` uses a PostgreSQL database managed by the separate, already-working
   `ansible-role-postgres-timescaledb-patroni` role (Patroni + etcd + TimescaleDB), instead of MySQL.
2. The Zabbix database schema (including the TimescaleDB schema) is imported/upgraded idempotently.
3. `ansible-zabbix` supports running with 2+ `zabbix-server` nodes in an HA cluster, with a frontend
   that transparently follows whichever node is currently active.
4. The whole thing is verified end-to-end: default `Admin`/`zabbix` login succeeds, and a second
   full playbook run produces zero changes.

The Patroni role is **not** a dependency of `ansible-zabbix` (unlike the current `ansible-mysql`
dependency). It is deployed separately, to its own host group, and exposes a PostgreSQL endpoint.
`ansible-zabbix` is purely a *client* of that endpoint.

## Architecture

```
[ etcd/Patroni cluster: db1, db2, db3 ]  <- separate role/playbook, already works standalone
              ^
              | TCP 5432, routed to current primary
              |
        [ HAProxy ]  <- new, colocated on each zabbix-server node
              ^
              | 127.0.0.1:6432
   +----------+----------+
   |                     |
[zabbix-server-1]   [zabbix-server-2]   <- both run zabbix-server, both HA cluster nodes
   |                     |               (HANodeName/NodeAddress, same DB)
[frontend-1]         [frontend-2]       <- both stateless, auto-discover active node via DB
```

### DB connection routing: HAProxy, with an escape hatch

Patroni doesn't provide a single stable address for "the current primary" — only individual node
addresses plus a REST API (`:8008`) that answers `/primary` with 200 only on the leader. Zabbix's
`DBHost`/`DBPort` (and the frontend's `$DB['SERVER']`) only accept one address, so something must
route around failover.

**Default: HAProxy**, installed locally on each `zabbix-server` host (new `tasks/server/haproxy.yml`,
templated `haproxy.cfg`), with an `httpchk GET /primary` against each Patroni node's REST API on
`:8008`. Zabbix connects to `127.0.0.1:{{ zabbix_db_proxy_port }}`. This is the pattern documented by
Patroni itself, needs no custom failover scripting, and has no L2/VRRP network dependency (relevant
since testing runs on Lima VMs).

This is gated by a variable, not hardcoded, so a site that already has its own router/VIP in front of
the Patroni cluster can skip it entirely:

```yaml
zabbix_db_proxy_mode: haproxy   # haproxy | none
zabbix_db_proxy_port: 6432
zabbix_pg_nodes:                # Patroni node inventory: host + patroni REST API port
  - { host: db1.example.com, port: 5432, restapi_port: 8008 }
  - { host: db2.example.com, port: 5432, restapi_port: 8008 }
  - { host: db3.example.com, port: 5432, restapi_port: 8008 }
```

When `zabbix_db_proxy_mode: none`, `zabbix_db_host`/`zabbix_db_port` are used directly as `DBHost`/
`DBPort` (the "I already have a VIP/LB" case) and no HAProxy is installed.

### Database backend (`db_backend: pgsql`)

- `defaults/main.yml`: `db_backend` already supports `pgsql`; no change needed there.
- **Path bug fix**: `vars/main.yml` currently computes
  `zabbix_server_schema_path: ".../sql-scripts/{{ db_backend }}/server.sql.gz"`. On disk the
  directory is named `postgresql`, not `pgsql` (`pgsql` is only the package-name suffix,
  `zabbix-server-pgsql`). Introduce `zabbix_db_sql_dir: "{{ 'postgresql' if db_backend == 'pgsql' else db_backend }}"`
  and use it for schema paths. Add `zabbix_server_timescaledb_schema_path:
  ".../sql-scripts/postgresql/timescaledb/schema.sql"` (uncompressed, applied via `psql`, not `zcat`).
- **DB/user provisioning**: `ansible-zabbix` creates the `zabbix` database and role directly against
  the (HAProxy-fronted or direct) endpoint using `community.postgresql.postgresql_db` /
  `postgresql_user` — mirroring today's self-contained mysql user creation, without adding a role
  dependency on the Patroni role. Runs `delegate_to` the connection endpoint, `run_once: true`.
- **Schema import**: replace the `mysql ... | mysql` shell pipeline with the `psql` equivalent.
  Idempotency check translates the existing "does `dbversion` table exist" query to
  `SELECT to_regclass('public.dbversion')`. Import `server.sql.gz` (via `zcat | psql`) and, when
  `zabbix_db_timescaledb: true`, follow with `timescaledb/schema.sql`. All of this is `run_once: true`,
  `delegate_to` a single designated node (first host in the play's `zabbix-server` group) — schema
  import must happen exactly once, not per zabbix-server host, since all HA nodes share one database.

### Zabbix server HA (native feature, not custom-built)

Verified against current Zabbix docs: Zabbix server has built-in HA — each node sets `HANodeName`
(unique id) and `NodeAddress` (`host:port`, used by the frontend) in `zabbix_server.conf`; all nodes
point at the same database; Zabbix elects the active node internally and the others stand by.

- New var `zabbix_ha_enabled: false` (explicit opt-in; not auto-detected from group size — keeps
  behavior predictable and testable). User sets it `true` and targets a play with 2+ hosts.
- Template additions to `zabbix_server.conf.j2`:
  ```
  {% if zabbix_ha_enabled %}
  HANodeName={{ zabbix_ha_node_name | default(inventory_hostname) }}
  NodeAddress={{ zabbix_ha_node_address | default(ansible_host) }}:{{ zabbix_ha_node_port | default(10051) }}
  {% endif %}
  ```
- No new coordination tooling. The shared Patroni-backed Postgres database *is* the coordination
  substrate Zabbix's HA feature already expects.

### Frontend: follows the active node automatically

Verified against current Zabbix docs ("Enabling high availability > Preparing frontend"): when
`$ZBX_SERVER` / `$ZBX_SERVER_PORT` are left undefined in `zabbix.conf.php`, the frontend detects the
active node by reading the `ha_node` table in the database. No custom failover logic needed in this
role at all.

- `templates/zabbix.conf.php.j2`: when `zabbix_ha_enabled`, omit the `$ZBX_SERVER`/`$ZBX_SERVER_PORT`
  lines entirely; otherwise keep today's static behavior.
- Each `zabbix-server` host in the play also runs its own frontend (existing behavior, unchanged) —
  HA here means "run 2+ frontends, each pointed at the shared HA-aware DB," not a separate frontend
  failover mechanism.

## New/changed variables (`defaults/main.yml`)

| Variable | Default | Purpose |
|---|---|---|
| `zabbix_ha_enabled` | `false` | Enable Zabbix native server HA + frontend auto-discovery |
| `zabbix_ha_node_port` | `10051` | Port advertised in `NodeAddress` |
| `zabbix_db_proxy_mode` | `haproxy` | `haproxy` (manage local HAProxy) or `none` (direct/external endpoint) |
| `zabbix_db_proxy_port` | `6432` | Local port zabbix-server/frontend connect to when proxy mode is `haproxy` |
| `zabbix_pg_nodes` | `[]` | Patroni node list (host, port, restapi_port) — required when proxy mode is `haproxy` |
| `zabbix_db_host` / `zabbix_db_port` | `""` / `5432` | Used directly as `DBHost`/`DBPort` when proxy mode is `none` |
| `zabbix_db_timescaledb` | `true` | Whether to apply the TimescaleDB schema after the base schema |

## Testing

Two test harnesses are combined rather than duplicating the DB cluster bring-up logic:

- **DB tier**: reuse `ansible-role-postgres-timescaledb-patroni`'s existing `cluster` Molecule
  scenario (Docker driver, 3 Debian 12 nodes, already verifies etcd quorum + one elected primary +
  streaming replicas). `ansible-zabbix` does not reimplement Patroni cluster bring-up.
- **App tier**: a new Molecule scenario in `ansible-zabbix/molecule/ha/` (Docker driver, to share the
  same network namespace/driver as the patroni role's scenario) with 2 `zabbix-server` containers.
  `converge.yml` first triggers (or depends on) the patroni role's `cluster` scenario being up on the
  same Docker network, then runs `ansible-zabbix` against the 2 server nodes with
  `zabbix_ha_enabled: true` and `zabbix_pg_nodes` pointing at the 3 DB containers by their Docker
  network hostnames.
- The existing Lima-based `tests/` harness (`run.sh`) remains for manual/single-node smoke testing on
  macOS; it is not extended to the multi-node HA case — Molecule/Docker is the harness for that,
  consistent with how the patroni role itself tests HA.
- **Login test**: scripted JSON-RPC call to `user.login` (`Admin`/`zabbix`) against each frontend
  container, asserting success — proves schema import + DB connectivity + HA frontend discovery all
  work.
- **Idempotency test**: Molecule's built-in `idempotence` sequence (`molecule converge` then
  `molecule idempotence`, which re-runs and asserts zero `changed`/`failed` tasks) — same mechanism
  the patroni role already relies on for its own idempotency guarantee.

## Out of scope

- Building custom failover orchestration for HAProxy beyond its built-in health checks.
- Modifying the Patroni role itself.
- TimescaleDB compression policies (existing `timescaledb_*` vars in the Patroni role cover this if
  needed later).
