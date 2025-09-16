#!/bin/bash
USUARIO="$1"
if [ -z "$USUARIO" ]; then
  echo "Uso: $0 <nombre_usuario>"
  exit 1
fi

echo "kill $USUARIO" | nc localhost 7505
echo "Desconectado: $USUARIO"
