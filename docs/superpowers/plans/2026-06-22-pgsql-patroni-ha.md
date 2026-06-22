# PostgreSQL/Patroni Backend + Zabbix-Server HA Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `ansible-zabbix` connect `zabbix-server` to a PostgreSQL/Patroni cluster (managed by the separate `ansible-role-postgres-timescaledb-patroni` role), import/upgrade the Zabbix (+ TimescaleDB) schema idempotently, support 2+ `zabbix-server` HA nodes with a frontend that auto-follows the active node, and prove it with a login test plus a zero-changes second run.

**Architecture:** HAProxy runs locally on each `zabbix-server` host and health-checks each Patroni node's REST API (`/primary` on `:8008`), forwarding TCP 5432 traffic only to the current leader; `zabbix-server`/frontend connect to `127.0.0.1:6432`. Zabbix's native HA feature (`HANodeName`/`NodeAddress` in `zabbix_server.conf`) handles server-side failover; leaving `$ZBX_SERVER` undefined in `zabbix.conf.php` makes the frontend auto-discover the active node via the database's `ha_node` table — no custom code for either.

**Tech Stack:** Ansible (`ansible.builtin`, `community.postgresql`), HAProxy, PostgreSQL 16 + TimescaleDB (via the separate Patroni role), Zabbix 7.4, Molecule (Docker driver) for testing.

## Global Constraints

- Design source of truth: `docs/superpowers/specs/2026-06-22-pgsql-patroni-ha-design.md`. Every variable name/default below matches that spec exactly.
- `ansible-zabbix` must NOT take a role dependency on `ansible-role-postgres-timescaledb-patroni` — it only consumes a connection endpoint (HAProxy-fronted by default, or direct/external when `zabbix_db_proxy_mode: none`).
- Existing MySQL behavior (`db_backend: mysql`) must be unchanged by every task — all new logic is gated by `when: db_backend == "pgsql"` or `zabbix_ha_enabled`.
- Schema import and DB/user provisioning must be `run_once: true` + `delegate_to` a single designated node — never run per-server-host once there are 2+ `zabbix-server` hosts.
- Idempotency is mandatory: every new/modified task must be safe to re-run with `changed: false` on the second run. Verified by Molecule's `idempotence` step in Task 9.
- DB tier for testing is the Patroni role's own `cluster` Molecule scenario (3-node, Docker driver) — `ansible-zabbix` does not reimplement Patroni cluster bring-up.

---

### Task 1: Collections requirement + schema-path bug fix

**Files:**
- Create: `requirements.yml`
- Modify: `vars/main.yml`

**Interfaces:**
- Produces: `zabbix_db_sql_dir` (string: `"postgresql"` when `db_backend == "pgsql"`, else `db_backend`), `zabbix_server_schema_path` (corrected), `zabbix_server_timescaledb_schema_path` (new), `zabbix_psql_client_packages` (dict keyed by `ansible_facts['os_family']`) — all consumed by Task 3.

- [ ] **Step 1: Write `requirements.yml`**

```yaml
---
collections:
  - name: community.postgresql
    version: ">=3.0.0"
```

- [ ] **Step 2: Fix the schema-path bug in `vars/main.yml`**

The directory Zabbix's `zabbix-sql-scripts` package actually installs to is named `postgresql`, not `pgsql` (`pgsql` is only the package-name suffix `zabbix-server-pgsql`). Replace the whole file:

```yaml
---

zabbix_service: zabbix-server
apache_service_RedHat: httpd
apache_service_Debian: apache2

zabbix_db_sql_dir: "{{ 'postgresql' if db_backend == 'pgsql' else db_backend }}"

zabbix_server_schema_path: "/usr/share/zabbix/sql-scripts/{{ zabbix_db_sql_dir }}/server.sql.gz"
zabbix_server_timescaledb_schema_path: "/usr/share/zabbix/sql-scripts/postgresql/timescaledb/schema.sql"
zabbix_proxy_schema_path: "/usr/share/zabbix/sql-scripts/{{ proxy_db_backend }}/proxy.sql"

zabbix_psql_client_packages:
  Debian:
    - postgresql-client
    - python3-psycopg2
  RedHat:
    - postgresql
    - python3-psycopg2
```

- [ ] **Step 3: Verify YAML is valid**

Run: `ansible-lint vars/main.yml requirements.yml` (or `yamllint vars/main.yml requirements.yml` if `ansible-lint` isn't installed)
Expected: no syntax errors. `ansible-lint` may report style warnings on pre-existing files — only fail the task on errors in the lines you just added.

- [ ] **Step 4: Commit**

```bash
git add requirements.yml vars/main.yml
git commit -m "fix: correct postgresql sql-scripts path, add timescaledb schema path and collection requirement"
```

---

### Task 2: New HA / pgsql-proxy variables

**Files:**
- Modify: `defaults/main.yml`

**Interfaces:**
- Produces: `zabbix_ha_enabled` (bool, default `false`), `zabbix_ha_node_port` (int, default `10051`), `zabbix_db_proxy_mode` (string: `haproxy`|`none`, default `haproxy`), `zabbix_db_proxy_port` (int, default `6432`), `zabbix_pg_nodes` (list of `{host, port, restapi_port}`, default `[]`), `zabbix_db_host`/`zabbix_db_port` (string/int, defaults `""`/`5432`), `zabbix_db_timescaledb` (bool, default `true`) — consumed by Tasks 3, 4, 5, 6, 7.

- [ ] **Step 1: Add the new block to `defaults/main.yml`**

Append after the existing `## Database connection ##` block (after line 11, `zabbix_pass: zabbix`):

```yaml
### High availability (zabbix-server + frontend) ###
zabbix_ha_enabled: false  # set true when targeting 2+ zabbix-server hosts
zabbix_ha_node_port: 10051  # advertised in NodeAddress for frontend->active-node routing

### PostgreSQL/Patroni connection routing ###
zabbix_db_proxy_mode: haproxy  # haproxy (manage local HAProxy) | none (direct/external endpoint)
zabbix_db_proxy_port: 6432  # local port zabbix-server/frontend connect to when proxy mode is haproxy
zabbix_pg_nodes: []  # required when zabbix_db_proxy_mode == haproxy: [{host, port, restapi_port}]
zabbix_db_host: ""  # used as DBHost directly when zabbix_db_proxy_mode == none
zabbix_db_port: 5432  # used as DBPort directly when zabbix_db_proxy_mode == none
zabbix_db_timescaledb: true  # apply the TimescaleDB schema after the base pgsql schema
```

- [ ] **Step 2: Verify YAML is valid**

Run: `ansible-lint defaults/main.yml`
Expected: no errors on the new lines.

- [ ] **Step 3: Commit**

```bash
git add defaults/main.yml
git commit -m "feat: add HA and pgsql/HAProxy connection variables"
```

---

### Task 3: PostgreSQL DB/user provisioning + schema import tasks

**Files:**
- Create: `tasks/server/postgresql_db.yml`

**Interfaces:**
- Consumes: `zabbix_db_proxy_mode`, `zabbix_db_proxy_port` (Task 2); `zabbix_db_host`, `zabbix_db_port` (Task 2); `zabbix_psql_client_packages`, `zabbix_server_schema_path`, `zabbix_server_timescaledb_schema_path` (Task 1); `zabbix_db`, `zabbix_user`, `zabbix_pass` (existing `defaults/main.yml`); `zabbix_db_timescaledb` (Task 2).
- Produces: a connect-host fact `_zabbix_pg_connect_host`/`_zabbix_pg_connect_port` other tasks could reuse (set via `ansible.builtin.set_fact`, not consumed outside this file in this plan).

- [ ] **Step 1: Write `tasks/server/postgresql_db.yml`**

```yaml
---
- name: Install PostgreSQL client packages
  ansible.builtin.package:
    name: "{{ zabbix_psql_client_packages[ansible_facts['os_family']] }}"
    state: present
  tags:
    - server.install

- name: Determine PostgreSQL connection endpoint
  ansible.builtin.set_fact:
    _zabbix_pg_connect_host: "{{ '127.0.0.1' if zabbix_db_proxy_mode == 'haproxy' else zabbix_db_host }}"
    _zabbix_pg_connect_port: "{{ zabbix_db_proxy_port if zabbix_db_proxy_mode == 'haproxy' else zabbix_db_port }}"
  tags:
    - server.install

- name: Create Zabbix database
  community.postgresql.postgresql_db:
    name: "{{ zabbix_db }}"
    login_host: "{{ _zabbix_pg_connect_host }}"
    login_port: "{{ _zabbix_pg_connect_port }}"
    login_user: "{{ zabbix_pg_admin_user | default('postgres') }}"
    login_password: "{{ zabbix_pg_admin_pass | default(omit) }}"
  run_once: true
  delegate_to: "{{ ansible_play_hosts_all[0] }}"
  tags:
    - server.install

- name: Create Zabbix database user
  community.postgresql.postgresql_user:
    name: "{{ zabbix_user }}"
    password: "{{ zabbix_pass }}"
    db: "{{ zabbix_db }}"
    priv: ALL
    login_host: "{{ _zabbix_pg_connect_host }}"
    login_port: "{{ _zabbix_pg_connect_port }}"
    login_user: "{{ zabbix_pg_admin_user | default('postgres') }}"
    login_password: "{{ zabbix_pg_admin_pass | default(omit) }}"
  run_once: true
  delegate_to: "{{ ansible_play_hosts_all[0] }}"
  tags:
    - server.install

- name: Check if Zabbix schema is already imported
  ansible.builtin.shell: >
    PGPASSWORD={{ zabbix_pass }} psql
    --host={{ _zabbix_pg_connect_host }} --port={{ _zabbix_pg_connect_port }}
    --username={{ zabbix_user }} --dbname={{ zabbix_db }}
    --tuples-only --no-align
    --command="SELECT to_regclass('public.dbversion')"
  register: zabbix_pg_schema_check
  changed_when: false
  run_once: true
  delegate_to: "{{ ansible_play_hosts_all[0] }}"
  tags:
    - server.install

- name: Import Zabbix server database schema
  ansible.builtin.shell: >
    zcat {{ zabbix_server_schema_path }} |
    PGPASSWORD={{ zabbix_pass }} psql
    --host={{ _zabbix_pg_connect_host }} --port={{ _zabbix_pg_connect_port }}
    --username={{ zabbix_user }} --dbname={{ zabbix_db }}
  when: zabbix_pg_schema_check.stdout | default('') | trim == ''
  run_once: true
  delegate_to: "{{ ansible_play_hosts_all[0] }}"
  tags:
    - server.install

- name: Import TimescaleDB schema
  ansible.builtin.shell: >
    PGPASSWORD={{ zabbix_pass }} psql
    --host={{ _zabbix_pg_connect_host }} --port={{ _zabbix_pg_connect_port }}
    --username={{ zabbix_user }} --dbname={{ zabbix_db }}
    --file={{ zabbix_server_timescaledb_schema_path }}
  when:
    - zabbix_db_timescaledb
    - zabbix_pg_schema_check.stdout | default('') | trim == ''
  run_once: true
  delegate_to: "{{ ansible_play_hosts_all[0] }}"
  tags:
    - server.install
```

`ansible_play_hosts_all[0]` pins schema work to the first host in the play regardless of how many `zabbix-server` hosts are targeted, satisfying the "exactly once" constraint without hardcoding an inventory hostname.

- [ ] **Step 2: Verify YAML is valid**

Run: `ansible-lint tasks/server/postgresql_db.yml`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add tasks/server/postgresql_db.yml
git commit -m "feat: add postgresql db/user provisioning and schema import tasks"
```

---

### Task 4: HAProxy task file + config template

**Files:**
- Create: `tasks/server/haproxy.yml`
- Create: `templates/haproxy.cfg.j2`

**Interfaces:**
- Consumes: `zabbix_pg_nodes` (Task 2, list of `{host, port, restapi_port}`), `zabbix_db_proxy_port` (Task 2).
- Produces: running `haproxy` service listening on `127.0.0.1:{{ zabbix_db_proxy_port }}`, consumed by Task 5's wiring (the `DBHost`/`DBPort` in Task 6 point at this).

- [ ] **Step 1: Write `templates/haproxy.cfg.j2`**

```
# Managed by ansible-zabbix - do not edit by hand
global
    maxconn 100
    log /dev/log local0

defaults
    mode tcp
    timeout connect 5s
    timeout client 30s
    timeout server 30s
    log global

frontend pg_primary
    bind 127.0.0.1:{{ zabbix_db_proxy_port }}
    default_backend pg_primary_nodes

backend pg_primary_nodes
    option httpchk GET /primary
    http-check expect status 200
{% for node in zabbix_pg_nodes %}
    server {{ node.host }} {{ node.host }}:{{ node.port }} check port {{ node.restapi_port }}
{% endfor %}
```

- [ ] **Step 2: Write `tasks/server/haproxy.yml`**

```yaml
---
- name: Install HAProxy
  ansible.builtin.package:
    name: haproxy
    state: present
  tags:
    - server.install

- name: Configure HAProxy for Patroni primary routing
  ansible.builtin.template:
    src: haproxy.cfg.j2
    dest: /etc/haproxy/haproxy.cfg
    mode: "0644"
    owner: root
    group: root
  notify: restart haproxy
  tags:
    - server.install
    - server.config

- name: Enable and start HAProxy
  ansible.builtin.service:
    name: haproxy
    enabled: true
    state: started
  tags:
    - server.install
```

- [ ] **Step 3: Add the `restart haproxy` handler**

Read `handlers/main.yml` first to match its existing style, then append a handler that mirrors the existing `restart zabbix` handler's module/pattern, targeting the `haproxy` service.

- [ ] **Step 4: Verify YAML is valid**

Run: `ansible-lint tasks/server/haproxy.yml templates/haproxy.cfg.j2 handlers/main.yml`
Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add tasks/server/haproxy.yml templates/haproxy.cfg.j2 handlers/main.yml
git commit -m "feat: add HAProxy task and config for Patroni primary routing"
```

---

### Task 5: Wire pgsql + HAProxy into server install tasks

**Files:**
- Modify: `tasks/server/install_zabbix_server.Debian.yml`
- Modify: `tasks/server/install_zabbix_server.RedHat.yml`

**Interfaces:**
- Consumes: `tasks/server/haproxy.yml` (Task 4), `tasks/server/postgresql_db.yml` (Task 3), `zabbix_db_proxy_mode` (Task 2).

- [ ] **Step 1: Modify `tasks/server/install_zabbix_server.Debian.yml`**

Insert immediately after the existing `when: db_backend == "mysql"` MySQL block (after line 15, before "Fix any broken package state before install"):

```yaml
- name: Set up HAProxy for Patroni primary routing
  ansible.builtin.include_tasks: haproxy.yml
  when:
    - db_backend == "pgsql"
    - zabbix_db_proxy_mode == "haproxy"

- name: Provision PostgreSQL database, user, and schema
  ansible.builtin.include_tasks: postgresql_db.yml
  when: db_backend == "pgsql"
```

Then **delete** the existing MySQL-only "Check if Zabbix schema is already imported" and "Import Zabbix server database schema" tasks at the bottom of the file (lines 53-71) — schema import for `pgsql` now lives in `postgresql_db.yml`; the `mysql` schema-check/import block must be made conditional rather than deleted, since `db_backend: mysql` still needs it. Replace those two tasks' `tags:` blocks by adding `when: db_backend == "mysql"` to both.

- [ ] **Step 2: Modify `tasks/server/install_zabbix_server.RedHat.yml`**

Apply the equivalent change: insert the same two `include_tasks` blocks after the existing MySQL `when: db_backend == "mysql"` block, and add `when: db_backend == "mysql"` to the existing "Check if Zabbix schema is already imported" / "Import Zabbix server database schema" tasks at the bottom.

- [ ] **Step 3: Verify YAML is valid**

Run: `ansible-lint tasks/server/install_zabbix_server.Debian.yml tasks/server/install_zabbix_server.RedHat.yml`
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add tasks/server/install_zabbix_server.Debian.yml tasks/server/install_zabbix_server.RedHat.yml
git commit -m "feat: wire HAProxy and postgresql provisioning into server install, gate mysql path"
```

---

### Task 6: `zabbix_server.conf.j2` — DBHost/DBPort + HA block

**Files:**
- Modify: `templates/zabbix_server.conf.j2`

**Interfaces:**
- Consumes: `db_backend`, `zabbix_db_proxy_mode`, `zabbix_db_proxy_port`, `zabbix_db_host`, `zabbix_db_port` (Task 2/existing), `zabbix_ha_enabled`, `zabbix_ha_node_port` (Task 2).

- [ ] **Step 1: Add explicit `DBHost`/`DBPort` for pgsql**

Immediately after line 101 (`DBName={{ zabbix_db }}`), insert:

```
{% if db_backend == "pgsql" %}
DBHost={{ '127.0.0.1' if zabbix_db_proxy_mode == 'haproxy' else zabbix_db_host }}
DBPort={{ zabbix_db_proxy_port if zabbix_db_proxy_mode == 'haproxy' else zabbix_db_port }}
{% endif %}
```

This is gated to `pgsql` only — the existing `mysql` behavior (DBHost omitted, defaults to `localhost` socket) is untouched.

- [ ] **Step 2: Add the HA cluster block**

At the end of the file (after the `LoadModule` comment block, end of file), append:

```

####### HIGH AVAILABILITY #######

{% if zabbix_ha_enabled %}
### Option: HANodeName
#       Unique high availability cluster node name. Managed by ansible-zabbix.
HANodeName={{ zabbix_ha_node_name | default(inventory_hostname) }}

### Option: NodeAddress
#       Address:port the frontend uses to reach this node.
NodeAddress={{ zabbix_ha_node_address | default(ansible_host) }}:{{ zabbix_ha_node_port }}
{% endif %}
```

- [ ] **Step 3: Verify the template renders**

Run: `ansible-playbook --syntax-check` is not sufficient for Jinja2 template bodies (it doesn't render templates). Instead, smoke-test rendering directly:

```bash
python3 -c "
from jinja2 import Environment, FileSystemLoader
env = Environment(loader=FileSystemLoader('templates'))
tpl = env.get_template('zabbix_server.conf.j2')
print(tpl.render(zabbix_db=1, zabbix_user='zabbix', zabbix_pass='zabbix',
    db_backend='pgsql', zabbix_db_proxy_mode='haproxy', zabbix_db_proxy_port=6432,
    zabbix_db_host='', zabbix_db_port=5432, zabbix_ha_enabled=True,
    inventory_hostname='zabbix-server-1', ansible_host='10.0.0.1', zabbix_ha_node_port=10051,
    external_script_dir='/usr/lib/zabbix/externalscripts', tls=False))
" | grep -E "DBHost|DBPort|HANodeName|NodeAddress"
```

Expected output contains:
```
DBHost=127.0.0.1
DBPort=6432
HANodeName=zabbix-server-1
NodeAddress=10.0.0.1:10051
```

- [ ] **Step 4: Commit**

```bash
git add templates/zabbix_server.conf.j2
git commit -m "feat: render pgsql DBHost/DBPort and HA cluster config in zabbix_server.conf"
```

---

### Task 7: `zabbix.conf.php.j2` — pgsql type + HA frontend auto-discovery

**Files:**
- Modify: `templates/zabbix.conf.php.j2`

**Interfaces:**
- Consumes: `db_backend`, `zabbix_db_proxy_mode`, `zabbix_db_proxy_port`, `zabbix_db_host`, `zabbix_db_port`, `zabbix_ha_enabled` (Task 2/existing).

- [ ] **Step 1: Rewrite the file**

```php
<?php
// Zabbix GUI configuration file.
global $DB;

$DB['TYPE']     = '{{ "POSTGRESQL" if db_backend == "pgsql" else "MYSQL" }}';
$DB['SERVER']   = '{{ "127.0.0.1" if (db_backend == "pgsql" and zabbix_db_proxy_mode == "haproxy") else (zabbix_db_host if db_backend == "pgsql" else "localhost") }}';
$DB['PORT']     = '{{ (zabbix_db_proxy_port if zabbix_db_proxy_mode == "haproxy" else zabbix_db_port) if db_backend == "pgsql" else "0" }}';
$DB['DATABASE'] = '{{ zabbix_db }}';
$DB['USER']     = '{{ zabbix_user }}';
$DB['PASSWORD'] = '{{ zabbix_pass }}';

// Schema name. Used for IBM DB2 and PostgreSQL.
$DB['SCHEMA'] = '';

{% if not zabbix_ha_enabled %}
$ZBX_SERVER      = 'localhost';
$ZBX_SERVER_PORT = '10051';
{% endif %}
$ZBX_SERVER_NAME = '{{ ansible_hostname }}';

$IMAGE_FORMAT_DEFAULT = IMAGE_FORMAT_PNG;
```

When `zabbix_ha_enabled` is true, `$ZBX_SERVER`/`$ZBX_SERVER_PORT` are omitted entirely, per Zabbix's documented HA frontend behavior — the frontend reads the active node from the `ha_node` table instead.

- [ ] **Step 2: Verify the template renders for both HA states**

```bash
python3 -c "
from jinja2 import Environment, FileSystemLoader
env = Environment(loader=FileSystemLoader('templates'))
tpl = env.get_template('zabbix.conf.php.j2')
for ha in (True, False):
    out = tpl.render(zabbix_db='zabbix', zabbix_user='zabbix', zabbix_pass='zabbix',
        db_backend='pgsql', zabbix_db_proxy_mode='haproxy', zabbix_db_proxy_port=6432,
        zabbix_db_host='', zabbix_db_port=5432, zabbix_ha_enabled=ha, ansible_hostname='zabbix-server-1')
    print(f'--- ha={ha} ---')
    print(out)
"
```

Expected: with `ha=True`, no `\$ZBX_SERVER` line appears; with `ha=False`, it does.

- [ ] **Step 3: Commit**

```bash
git add templates/zabbix.conf.php.j2
git commit -m "feat: render pgsql DB type/endpoint and HA-aware frontend server discovery"
```

---

### Task 8: Molecule HA scenario scaffold

**Files:**
- Create: `molecule/ha/molecule.yml`
- Create: `molecule/ha/converge.yml`
- Create: `molecule/ha/requirements.yml`

**Interfaces:**
- Consumes: all variables from Tasks 1-7. The Patroni role's `cluster` Molecule scenario
  (`../ansible-role-postgres-timescaledb-patroni/molecule/cluster/molecule.yml`, already read) defines
  3 containers named exactly `pg-node1`, `pg-node2`, `pg-node3` (group `pg_cluster`), each running
  PostgreSQL on 5432 and Patroni's REST API on 8008. **That scenario's `molecule.yml` declares no
  explicit `networks:` key**, so Molecule's docker driver does not put them on a shared, externally
  joinable network by default — `zabbix-server-1`/`zabbix-server-2` cannot reach `pg-node1-3` by
  hostname unless both scenarios are explicitly attached to the same Docker network. Do not assume a
  network name exists; this task creates one.
- Produces: 2 running containers (`zabbix-server-1`, `zabbix-server-2`) with `ansible-zabbix` applied,
  consumed by Task 9's verify step.

- [ ] **Step 1: Write `molecule/ha/requirements.yml`**

```yaml
---
collections:
  - name: community.postgresql
    version: ">=3.0.0"
  - name: community.docker
    version: ">=3.0.0"
```

- [ ] **Step 2: Create a shared external Docker network for both scenarios**

```bash
docker network create zabbix-ha-test 2>/dev/null || true
```

This network must exist before either Molecule scenario's `create` step runs. It's idempotent
(`|| true` tolerates "already exists").

- [ ] **Step 3: Attach the patroni role's `cluster` scenario to that network**

Modify `../ansible-role-postgres-timescaledb-patroni/molecule/cluster/molecule.yml`: add a
`networks:` key to each of the three platform entries (`pg-node1`, `pg-node2`, `pg-node3`), e.g.:

```yaml
  - name: pg-node1
    image: geerlingguy/docker-debian12-ansible:latest
    command: "/lib/systemd/systemd"
    cgroupns_mode: host
    privileged: true
    volumes:
      - /sys/fs/cgroup:/sys/fs/cgroup:rw
    pre_build_image: true
    groups:
      - pg_cluster
    networks:
      - name: zabbix-ha-test
```

(repeat the `networks:` addition for `pg-node2` and `pg-node3`, keeping every other line unchanged).
This is the one change this plan makes outside `ansible-zabbix` — it's additive (one new key per
platform) and does not alter that role's own test behavior when run standalone.

- [ ] **Step 4: Write `molecule/ha/molecule.yml`**

```yaml
---
driver:
  name: docker
platforms:
  - name: zabbix-server-1
    image: "geerlingguy/docker-debian12-ansible:latest"
    command: "/lib/systemd/systemd"
    cgroupns_mode: host
    privileged: true
    volumes:
      - /sys/fs/cgroup:/sys/fs/cgroup:rw
    pre_build_image: true
    networks:
      - name: zabbix-ha-test
  - name: zabbix-server-2
    image: "geerlingguy/docker-debian12-ansible:latest"
    command: "/lib/systemd/systemd"
    cgroupns_mode: host
    privileged: true
    volumes:
      - /sys/fs/cgroup:/sys/fs/cgroup:rw
    pre_build_image: true
    networks:
      - name: zabbix-ha-test
provisioner:
  name: ansible
  playbooks:
    converge: converge.yml
verifier:
  name: ansible
```

`command`/`cgroupns_mode`/`privileged`/`volumes` mirror the patroni role's own platform config
(`systemd` must run as PID 1 inside the container for `ansible.builtin.service` to manage
`haproxy`/`zabbix-server`/`apache2` — copy this pattern exactly, it's already proven working there).

- [ ] **Step 5: Write `molecule/ha/converge.yml`**

```yaml
---
- name: Converge
  hosts: all
  become: true
  vars:
    db_backend: pgsql
    zabbix_function: server
    zabbix_ha_enabled: true
    zabbix_db_proxy_mode: haproxy
    zabbix_db_proxy_port: 6432
    zabbix_pg_nodes:
      - { host: pg-node1, port: 5432, restapi_port: 8008 }
      - { host: pg-node2, port: 5432, restapi_port: 8008 }
      - { host: pg-node3, port: 5432, restapi_port: 8008 }
    zabbix_db: zabbix
    zabbix_user: zabbix
    zabbix_pass: zabbix
    zabbix_pg_admin_user: testuser
    zabbix_pg_admin_pass: TestAppPass123!
  roles:
    - role: ansible-zabbix
```

`zabbix_pg_admin_user`/`zabbix_pg_admin_pass` match the `timescaledb_app_user`/
`timescaledb_app_password` the patroni role's `cluster` scenario already provisions
(`molecule/cluster/molecule.yml` group_vars: `timescaledb_app_user: testuser`,
`timescaledb_app_password: TestAppPass123!`) — this user already has privileges on the `testdb`
database in that scenario, but **not** automatically on a new `zabbix` database; Task 3's
`postgresql_db`/`postgresql_user` modules create the `zabbix` database/role using this admin
identity, so it must be a Postgres role with `CREATEDB`/superuser-equivalent rights. If connecting as
`testuser` fails with a permission error during Step 6, use `patroni_superuser_username`/
`patroni_superuser_password` from that same scenario instead (`postgres` / `TestSuperPass123!`).

- [ ] **Step 6: Run the patroni cluster scenario, then converge this scenario**

```bash
docker network create zabbix-ha-test 2>/dev/null || true
cd ../ansible-role-postgres-timescaledb-patroni && molecule converge -s cluster
cd ../ansible-zabbix && molecule converge -s ha
```

Expected: both scenarios report `PLAY RECAP` with no `failed` tasks. If `postgresql_db`/
`postgresql_user` in Task 3 fail with an authentication/permission error, switch
`zabbix_pg_admin_user`/`zabbix_pg_admin_pass` in `converge.yml` to the superuser credentials noted in
Step 5 and re-run `molecule converge -s ha`.

- [ ] **Step 5: Commit**

```bash
git add molecule/ha/molecule.yml molecule/ha/converge.yml molecule/ha/requirements.yml
git commit -m "test: add molecule ha scenario for 2-node zabbix-server against patroni cluster"
```

---

### Task 9: Login verification + idempotence

**Files:**
- Create: `molecule/ha/verify.yml`

**Interfaces:**
- Consumes: containers from Task 8 (`zabbix-server-1`, `zabbix-server-2`), default Zabbix frontend credentials (`Admin`/`zabbix`, unchanged by this role).

- [ ] **Step 1: Write `molecule/ha/verify.yml`**

```yaml
---
- name: Verify
  hosts: all
  become: true
  tasks:
    - name: Wait for Zabbix frontend to respond
      ansible.builtin.uri:
        url: "http://localhost/api_jsonrpc.php"
        method: POST
        headers:
          Content-Type: "application/json-rpc"
        body_format: json
        body:
          jsonrpc: "2.0"
          method: apiinfo.version
          params: {}
          id: 1
        status_code: 200
      register: api_check
      retries: 30
      delay: 5
      until: api_check.status == 200

    - name: Log in with default Admin/zabbix credentials
      ansible.builtin.uri:
        url: "http://localhost/api_jsonrpc.php"
        method: POST
        headers:
          Content-Type: "application/json-rpc"
        body_format: json
        body:
          jsonrpc: "2.0"
          method: user.login
          params:
            username: Admin
            password: zabbix
          id: 1
        status_code: 200
      register: login_result
      failed_when: login_result.json.result is not defined

    - name: Assert login returned a session token
      ansible.builtin.assert:
        that:
          - login_result.json.result is defined
          - login_result.json.result | length > 0
        fail_msg: "Login did not return a session token: {{ login_result.json }}"
```

- [ ] **Step 2: Run verify**

```bash
cd /Users/kirk/Development/ansible-zabbix && molecule verify -s ha
```

Expected: `PLAY RECAP` shows `failed=0` on both `zabbix-server-1` and `zabbix-server-2` — proves schema import, DB connectivity, and (since the frontend has no static `$ZBX_SERVER`) HA-aware frontend operation all work on both nodes independently.

- [ ] **Step 3: Run idempotence**

```bash
molecule idempotence -s ha
```

Expected: exits 0. Molecule's idempotence step re-runs `converge.yml` and fails the build if any task reports `changed`, directly satisfying the "rerun multiple times without any errors or changes" requirement.

- [ ] **Step 4: Commit**

```bash
git add molecule/ha/verify.yml
git commit -m "test: add login verification and rely on molecule idempotence for rerun safety"
```

---

### Task 10: README documentation

**Files:**
- Modify: `README.md` (read it first to match existing structure/tone)

- [ ] **Step 1: Document the new variables**

Add a table row (matching whatever table format `README.md` already uses for variables — check the existing `db_backend`/`zabbix_db` documentation style before adding) for each of: `zabbix_ha_enabled`, `zabbix_ha_node_port`, `zabbix_db_proxy_mode`, `zabbix_db_proxy_port`, `zabbix_pg_nodes`, `zabbix_db_host`, `zabbix_db_port`, `zabbix_db_timescaledb`.

- [ ] **Step 2: Document the HA + pgsql usage pattern**

Add a short example block (following the README's existing example-playbook style) showing a 2-node `zabbix-server` HA deployment against an existing Patroni cluster:

```yaml
- hosts: zabbix_server
  become: true
  vars:
    db_backend: pgsql
    zabbix_ha_enabled: true
    zabbix_pg_nodes:
      - { host: db1.example.com, port: 5432, restapi_port: 8008 }
      - { host: db2.example.com, port: 5432, restapi_port: 8008 }
      - { host: db3.example.com, port: 5432, restapi_port: 8008 }
  roles:
    - sifungurux.zabbix
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document pgsql/patroni HA variables and example playbook"
```

---

## Self-Review Notes

- **Spec coverage:** DB routing (Task 4/6/7), schema/path fix (Task 1/3), HA server config (Task 6), HA frontend (Task 7), DB/user provisioning (Task 3), testing/login/idempotence (Task 8/9) — every spec section has a task.
- **Existing mysql path:** Tasks 5-7 all gate new behavior behind `db_backend == "pgsql"` or `zabbix_ha_enabled`; mysql-only tasks gain an explicit `when: db_backend == "mysql"` rather than being deleted, so `db_backend: mysql` users see zero behavior change.
- **Docker network gap resolved:** inspected `../ansible-role-postgres-timescaledb-patroni/molecule/cluster/molecule.yml` directly — container names are `pg-node1`/`pg-node2`/`pg-node3`, and that scenario declares no `networks:` key, so Task 8 now creates an explicit shared `zabbix-ha-test` Docker network and adds a `networks:` key to both scenarios' platform configs rather than assuming a name.
