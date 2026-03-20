#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INVENTORY="$SCRIPT_DIR/inventory.ini"

# --- Checks ---
if ! command -v limactl &>/dev/null; then
  echo "ERROR: lima is not installed. Run: brew install lima"
  exit 1
fi
if ! command -v ansible-playbook &>/dev/null; then
  echo "ERROR: ansible is not installed. Run: brew install ansible"
  exit 1
fi

# --- Start instances ---
for name in zabbix-server zabbix-agent zabbix-proxy; do
  if limactl list "$name" --format '{{.Status}}' 2>/dev/null | grep -q "Running"; then
    echo "$name is already running"
  else
    echo "Starting $name..."
    limactl start --name="$name" "$SCRIPT_DIR/lima/$name.yaml"
  fi
done

# --- Get IPs ---
get_ip() {
  limactl shell "$1" -- ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{print $7}'
}

echo "Waiting for IPs..."
for name in zabbix-server zabbix-agent zabbix-proxy; do
  for i in $(seq 1 30); do
    IP=$(get_ip "$name")
    if [ -n "$IP" ]; then break; fi
    sleep 2
  done
  if [ -z "$IP" ]; then
    echo "ERROR: Could not get IP for $name"
    exit 1
  fi
  echo "$name -> $IP"
  declare "${name//-/_}_IP=$IP"
done

SSH_KEY="$HOME/.lima/_config/user"
SSH_USER="$(whoami)"

# --- Generate inventory ---
cat > "$INVENTORY" <<EOF
[PRODUCTION]
zabbix-server ansible_host=${zabbix_server_IP} zabbix_function=server note="Zabbix server"
zabbix-agent  ansible_host=${zabbix_agent_IP}  note="Zabbix agent"
zabbix-proxy  ansible_host=${zabbix_proxy_IP}  note="Zabbix proxy"

[ZABBIX_SERVER]
zabbix-server

[ZABBIX_PROXIES]
zabbix-proxy

[PRODUCTION:vars]
ansible_user=${SSH_USER}
ansible_ssh_private_key_file=${SSH_KEY}
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
ansible_become=true
ansible_python_interpreter=/usr/bin/python3
environ=PRE-PRODUCTION
warn="This is a pre-prod server - Think about what you are doing and BE CAREFULL"
zabbix_server=${zabbix_server_IP}
zabbix_proxies=["${zabbix_proxy_IP}"]
EOF

echo "Inventory written to $INVENTORY"

# --- Bootstrap Python ---
echo "Installing Python on hosts..."
ansible -i "$INVENTORY" PRODUCTION -m raw -a "apt-get install -y python3" --become

# --- Run Ansible ---
echo "Running Ansible..."
ansible-playbook -i "$INVENTORY" -v "$SCRIPT_DIR/zabbix.yml"
