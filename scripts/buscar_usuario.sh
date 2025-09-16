#!/bin/bash

USUARIO="$1"
EASYRSA_DIR="/data/easy-rsa"
CRL_FILE="${EASYRSA_DIR}/pki/crl.pem"
SUSPEND_LIST="/etc/openvpn/suspendidos/lista"
CERT_PATH="${EASYRSA_DIR}/pki/issued/${USUARIO}.crt"

if [ -z "$USUARIO" ]; then
  echo "❌ Uso: $0 <nombre_usuario>"
  exit 1
fi

echo "🔍 Buscando usuario: $USUARIO"

if [ -f "$SUSPEND_LIST" ] && grep -Fxq "$USUARIO" "$SUSPEND_LIST"; then
  echo "🟡 Estado: SUSPENDIDO"
elif [ -f "$CRL_FILE" ] && openssl crl -inform PEM -text -noout -in "$CRL_FILE" | grep -q "$USUARIO"; then
  echo "🔴 Estado: REVOCADO"
elif [ -f "$CERT_PATH" ]; then
  echo "🟢 Estado: ACTIVO"
else
  echo "❌ Usuario no encontrado en certificados emitidos"
fi

echo "🔗 Verificando conexión actual..."
echo "status" | nc localhost 7505 | awk '/CLIENT LIST/,/ROUTING TABLE/' | grep "$USUARIO"
