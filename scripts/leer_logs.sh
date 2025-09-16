#!/bin/bash
LOG_FILE="/var/log/openvpn/openvpn.log"
if [ ! -f "$LOG_FILE" ]; then
  echo "❌ Archivo de log no encontrado: $LOG_FILE"
  exit 1
fi
tail -n 50 "$LOG_FILE"
