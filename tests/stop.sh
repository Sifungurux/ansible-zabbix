#!/usr/bin/env bash
set -euo pipefail

ACTION=${1:-stop}
VMS=(zabbix-server zabbix-agent zabbix-proxy)

if [ "$ACTION" = "delete" ]; then
  echo "This will stop and delete the following Lima VMs:"
  for name in "${VMS[@]}"; do
    echo "  - $name"
  done
  echo ""
  read -r -p "Are you sure? [y/N] " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
fi

for name in "${VMS[@]}"; do
  if ! limactl list --format '{{.Name}}' | grep -q "^${name}$"; then
    echo "Skipping $name (not found)"
    continue
  fi

  if [ "$ACTION" = "delete" ]; then
    echo "Stopping $name..."
    limactl stop "$name" --force 2>/dev/null || true
    echo "Deleting $name..."
    limactl delete "$name"
    echo "Done: $name"
  else
    echo "Stopping $name..."
    limactl stop "$name" 2>/dev/null || true
  fi
done

[ "$ACTION" = "delete" ] && echo "" && echo "All Zabbix Lima VMs removed."
