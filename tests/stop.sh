#!/bin/bash

ACTION=${1:-stop}

for name in zabbix-server zabbix-agent zabbix-proxy; do
  if [ "$ACTION" = "delete" ]; then
    echo "Deleting $name..."
    limactl delete -f "$name" 2>/dev/null || true
  else
    echo "Stopping $name..."
    limactl stop "$name" 2>/dev/null || true
  fi
done
