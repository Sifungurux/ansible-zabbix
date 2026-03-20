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
1. Start all three Lima VMs (downloading the Ubuntu 22.04 ARM64 image on first run)
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

## File structure

```
tests/
├── lima/
│   ├── zabbix-server.yaml   # Lima VM config
│   ├── zabbix-agent.yaml
│   └── zabbix-proxy.yaml
├── run.sh                   # Start VMs + run Ansible
├── stop.sh                  # Stop or delete VMs
├── inventory.ini            # Generated at runtime (do not edit)
└── zabbix_prep.yml          # Ansible playbook
```
