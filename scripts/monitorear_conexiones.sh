#!/bin/bash
INTERVALO=${1:-5}
echo "⏱ Monitoreando conexiones activas cada $INTERVALO segundos (Ctrl+C para salir)..."
while true; do
  date
  echo "status" | nc localhost 7505 | awk '/CLIENT LIST/,/ROUTING TABLE/' | head -n -1
  echo "----------------------------------"
  sleep "$INTERVALO"
done
