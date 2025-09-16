#!/bin/bash
USUARIO="$1"
EASYRSA_DIR="/data/easy-rsa"
OVPN_PATH="/data/ovpn/${USUARIO}.ovpn"
ZIP_PATH="/data/ovpn/${USUARIO}.zip"
CERT_PATH="${EASYRSA_DIR}/pki/issued/${USUARIO}.crt"
KEY_PATH="${EASYRSA_DIR}/pki/private/${USUARIO}.key"
REQ_PATH="${EASYRSA_DIR}/pki/reqs/${USUARIO}.req"

if [ -z "$USUARIO" ]; then
  echo "❌ Uso: $0 <nombre_usuario>"
  exit 1
fi

echo "🧹 Eliminando datos del usuario: $USUARIO"

rm -f "$OVPN_PATH" "$ZIP_PATH" "$CERT_PATH" "$KEY_PATH" "$REQ_PATH"
echo "✅ Archivos eliminados para: $USUARIO"
