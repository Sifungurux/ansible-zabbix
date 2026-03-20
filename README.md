Zabbix Server, Agent, and Proxy
================================

Installs and configures Zabbix 6.x/8.x on RHEL 8/9 and Ubuntu 22.04+/Debian. Supports agent, server, and proxy deployment via the `zabbix_function` variable. The server and proxy modes depend on the `ansible-mysql` role for database setup when using a MySQL/MariaDB backend.

Requirements
------------

- Ansible 2.14+
- Python 3 on managed hosts
- `community.zabbix` >= 4.x and `community.mysql` collections:

```bash
ansible-galaxy collection install -r collections/requirements.yml
```

> **Note:** `community.zabbix` 4.x uses Ansible's `httpapi` connection plugin to communicate with the Zabbix API. This requires a dedicated inventory host for API calls (see [Inventory Structure](#inventory-structure) below).

Supported platforms:

| OS | Zabbix version |
|----|----------------|
| RHEL / Rocky / AlmaLinux 8, 9 | 6.x, 8.x |
| Ubuntu 24.04 (Noble) | 8.x |
| Ubuntu 22.04 (Jammy) | 6.x |
| Debian 12 (Bookworm) | 6.x, 8.x |

> Zabbix 8.x requires Ubuntu 24.04 or later. Ubuntu 22.04 only supports Zabbix 6.x due to library version constraints (`libc6`, `libssl`, etc.).

---

Inventory Structure
-------------------

A real-world deployment requires four inventory groups. The `ZABBIX_API` group is mandatory — the `community.zabbix` collection modules use an `httpapi` persistent connection rather than direct HTTP calls, and they must target a host configured with that connection type.

### inventory/hosts.ini

```ini
[ZABBIX_SERVER]
zabbix01.example.com

[ZABBIX_AGENTS]
web01.example.com
web02.example.com
db01.example.com

[ZABBIX_PROXIES]
proxy-dc1.example.com
proxy-dc2.example.com

# Required for community.zabbix 4.x API modules (zabbix_host, zabbix_proxy).
# Must point at your Zabbix server's web interface IP or hostname.
[ZABBIX_API]
zabbix-api ansible_host=<zabbix_server_ip_or_hostname>

[ZABBIX_API:vars]
ansible_connection=httpapi
ansible_network_os=community.zabbix.zabbix
ansible_user=Admin
ansible_httpapi_port=80
ansible_httpapi_use_ssl=false
ansible_httpapi_validate_certs=false
```

For HTTPS set `ansible_httpapi_use_ssl=true`, `ansible_httpapi_port=443`, and `ansible_httpapi_validate_certs=true` (or `false` if using a self-signed certificate).

---

Variable Configuration
----------------------

Set variables in `group_vars/` files alongside your inventory. Do not put secrets in the inventory file itself.

### group_vars/all.yml

Variables shared across all hosts:

```yaml
---
zabbix_version: "8.0"     # Zabbix version to install
zabbix_server: 192.168.1.10  # IP/hostname of the Zabbix server
                              # Used in agent/proxy config and API host registration
zabbix_proxies:
  - 192.168.1.20             # List of proxy IPs — agents accept connections from these too
```

### group_vars/ZABBIX_SERVER.yml

```yaml
---
zabbix_function: server
db_backend: mysql           # mysql or pgsql

# MySQL root password — passed to ansible-mysql role to create the DB and user
db_pass: "CHANGE_ME_strong_root_password"

# Zabbix database credentials
zabbix_db: zabbix
zabbix_user: zabbix
zabbix_pass: "CHANGE_ME_strong_db_password"

# Zabbix web UI admin password — used when registering hosts/proxies via API
zabbix_admin_password: "CHANGE_ME_strong_admin_password"
```

### group_vars/ZABBIX_PROXIES.yml

```yaml
---
zabbix_function: proxy
db_backend: mysql
proxyMode: active           # active or passive

# MySQL root password for the proxy database host
proxy_db_pass: "CHANGE_ME_strong_root_password"

# Proxy database credentials — must be different from the server's database
zabbix_proxy_db: zabbixProxy
zabbix_proxy_user: zabbixProxy
zabbix_proxy_pass: "CHANGE_ME_strong_proxy_db_password"
```

### group_vars/ZABBIX_AGENTS.yml

```yaml
---
zabbix_function: agent
```

### group_vars/ZABBIX_API.yml

The `ansible_password` for the API host must be defined here (not in `hosts.ini`) so Jinja2 templating resolves correctly:

```yaml
---
ansible_password: "{{ zabbix_admin_password | default('zabbix') }}"
```

---

All Role Variables
------------------

| Variable | Default | Description |
|---|---|---|
| `zabbix_version` | `8.0` | Zabbix version to install (`6.0`, `6.2`, `6.4`, `8.0`) |
| `zabbix_function` | `agent` | Component to deploy: `agent`, `server`, or `proxy` |
| `zabbix_server` | `127.0.0.1` | Zabbix server IP/hostname. Written into agent/proxy config and used in `add.host` API calls |
| `zabbix_proxies` | `[]` | List of proxy IPs. Agents accept passive checks from these in addition to `zabbix_server` |
| `zabbix_admin_password` | `zabbix` | Zabbix web UI admin password. Used by `add.host` and `add.proxy` API calls. **Change this** |
| `db_backend` | `mysql` | Database backend for server/proxy: `mysql` or `pgsql` |
| `db_pass` | `changeme` | MySQL root password — passed to `ansible-mysql` for database provisioning. **Change this** |
| `zabbix_db` | `zabbix` | Zabbix server database name |
| `zabbix_user` | `zabbix` | Zabbix server database user |
| `zabbix_pass` | `zabbix` | Zabbix server database password. **Change this** |
| `zabbix_proxy_db` | `zabbixProxy` | Zabbix proxy database name |
| `zabbix_proxy_user` | `zabbixProxy` | Zabbix proxy database user |
| `zabbix_proxy_pass` | `zabbixProxy` | Zabbix proxy database password. **Change this** |
| `proxy_db_pass` | `changeme` | MySQL root password on the proxy host for database provisioning. **Change this** |
| `proxyMode` | `active` | Proxy operating mode: `active` or `passive` |
| `ListenPort` | `10050` | Port the Zabbix agent listens on |
| `external_script_dir` | `/usr/lib/zabbix/externalscripts` | Directory for external alert scripts on the server |
| `tls` | `false` | Enable TLS for agent/server communication. When `true`, includes `/etc/zabbix/zabbix_server.conf.d/*.conf` |

---

Playbooks
---------

### site.yml — full deployment

```yaml
---
- name: Deploy Zabbix server
  hosts: ZABBIX_SERVER
  become: yes
  roles:
    - role: ansible-zabbix

- name: Deploy Zabbix proxies
  hosts: ZABBIX_PROXIES
  become: yes
  roles:
    - role: ansible-zabbix

- name: Deploy Zabbix agents
  hosts: ZABBIX_AGENTS
  become: yes
  roles:
    - role: ansible-zabbix
```

Run the full deployment:

```bash
ansible-playbook -i inventory/hosts.ini site.yml
```

---

Common Operations
-----------------

### Install or re-install the Zabbix repository only

```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags repo
```

### Install agent on new hosts

```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags agent.install -l web03.example.com
```

### Re-apply agent configuration without reinstalling

```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags agent.config -l ZABBIX_AGENTS
```

### Register a host in Zabbix via the API

This uses the `community.zabbix.zabbix_host` module, which runs against the `ZABBIX_API` host group. The task is delegated to `zabbix-api` automatically.

```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags add.host -l web03.example.com
```

The host will be added to the `Linux servers` host group and linked to the `Template OS Linux` template, using the host's FQDN and primary IP.

### Register a proxy in Zabbix via the API

```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags add.proxy -l proxy-dc1.example.com
```

### Re-install the Zabbix server (re-runs package install, schema import, and config)

```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags server.install -l ZABBIX_SERVER
```

### Deploy UserParameters to agents

```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags userparam -l ZABBIX_AGENTS \
  --extra-vars '{"userparam_dir":"/local/params","userparam":[{"name":"cpu","script":"cpu.conf"}]}'
```

### Deploy external scripts to the server

```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags externalScript -l ZABBIX_SERVER \
  --extra-vars '{"external_dir":"/local/scripts","external_script":[{"script":"check_service.sh"}]}'
```

---

Tags Reference
--------------

| Tag | What it runs |
|---|---|
| `repo` | Installs the Zabbix apt/yum repository |
| `agent.install` | Installs and configures the Zabbix agent |
| `agent.config` | Re-applies agent configuration only (no package install) |
| `server.install` | Installs Zabbix server packages, imports the DB schema, and applies config |
| `server.config` | Re-applies server and web configuration only |
| `proxy.install` | Installs Zabbix proxy packages, imports the DB schema, and applies config |
| `proxy.config` | Re-applies proxy configuration only |
| `add.host` | Registers the target host in Zabbix via the API |
| `add.proxy` | Registers the target proxy in Zabbix via the API |
| `userparam` | Deploys UserParameter config files to agents |
| `externalScript` | Deploys external scripts to the server |

---

File Layout (real environment)
-------------------------------

```
your-ansible-project/
├── site.yml                        # Main playbook
├── collections/
│   └── requirements.yml            # ansible-galaxy collection dependencies
├── inventory/
│   ├── hosts.ini                   # Inventory with all groups including ZABBIX_API
│   └── group_vars/
│       ├── all.yml                 # zabbix_version, zabbix_server, zabbix_proxies
│       ├── ZABBIX_SERVER.yml       # zabbix_function, db credentials, admin password
│       ├── ZABBIX_PROXIES.yml      # zabbix_function, proxy db credentials, proxyMode
│       ├── ZABBIX_AGENTS.yml       # zabbix_function: agent
│       └── ZABBIX_API.yml          # ansible_password (Jinja reference to zabbix_admin_password)
└── roles/
    ├── ansible-zabbix/             # This role
    └── ansible-mysql/              # Required for server and proxy database setup
```

---

Secrets Management
------------------

The variables marked **"Change this"** must not be stored in plain text in version-controlled files. Use one of the following:

**Ansible Vault** — encrypt the sensitive group_vars files:

```bash
ansible-vault encrypt inventory/group_vars/ZABBIX_SERVER.yml
ansible-playbook -i inventory/hosts.ini site.yml --ask-vault-pass
```

**Vault password file** (for CI/CD):

```bash
ansible-playbook -i inventory/hosts.ini site.yml --vault-password-file ~/.vault_pass
```

**External secrets** (1Password, HashiCorp Vault, AWS Secrets Manager) — use the relevant Ansible lookup plugin to inject values at runtime rather than storing them in files.

---

License
-------

BSD
