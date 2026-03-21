# Zabbix Test Environment

Three-VM test environment using [Lima](https://lima-vm.io) on Apple Silicon (M-series Macs).

| VM | Role |
|----|------|
| zabbix-server | Zabbix Server |
| zabbix-agent | Zabbix Agent |
| zabbix-proxy | Zabbix Proxy |

---

## Prerequisites

Install the required tools via Homebrew:

```bash
brew install lima ansible
```

Verify both are installed:

```bash
limactl --version
ansible --version
```

---

## Running the environment

From the `tests/` directory:

```bash
cd tests
./run.sh
```

This will:
1. Start all three Lima VMs (downloading the Ubuntu 24.04 ARM64 image on first run)
2. Wait for each VM to get an IP address
3. Generate `inventory.ini` with the real IPs
4. Bootstrap Python 3 on each VM using Ansible's `raw` module
5. Run the Ansible playbook against all three VMs

> First run takes a few minutes to download the VM image (~600MB).

---

## Stopping the VMs

```bash
# Stop (keep disk, can restart later)
./stop.sh

# Delete completely (removes disk)
./stop.sh delete
```

---

## Connecting to a VM

```bash
limactl shell zabbix-server
limactl shell zabbix-agent
limactl shell zabbix-proxy
```

---

## Re-running Ansible only

If the VMs are already running and you just want to re-run the playbook:

```bash
./run.sh
```

The script skips starting VMs that are already running and goes straight to re-generating the inventory and running Ansible.

---

## Running tests only

If the VMs are already running and the role has been applied, run the test playbook directly:

```bash
ansible-playbook -i inventory.ini test_zabbix.yml
```

Tests verify per host (based on `zabbix_function`):
- Service is running and enabled
- Correct port is listening (10050 for agent, 10051 for server/proxy)
- Config file is deployed
- Agent/proxy config points to the correct server IP
- **Server only:** database schema is imported, web UI responds on port 80

---

## File structure

```
tests/
├── lima/
│   ├── zabbix-server.yaml   # Lima VM config (Ubuntu 24.04)
│   ├── zabbix-agent.yaml
│   └── zabbix-proxy.yaml
├── group_vars/
│   ├── PRODUCTION.yml       # Shared role vars
│   └── ZABBIX_API.yml       # Zabbix API credentials (httpapi)
├── run.sh                   # Start VMs + run Ansible + run tests
├── stop.sh                  # Stop or delete VMs
├── inventory.ini            # Generated at runtime (do not edit)
├── zabbix.yml               # Main deployment playbook
└── test_zabbix.yml          # Verification playbook (run after deploy)
```
