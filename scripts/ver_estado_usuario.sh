#!/bin/bash
USUARIO="$1"
EASYRSA_DIR="/data/easy-rsa"
CRL_FILE="${EASYRSA_DIR}/pki/crl.pem"
SUSPEND_LIST="/etc/openvpn/suspendidos/lista"

if [ -z "$USUARIO" ]; then
  echo "❌ Uso: $0 <nombre_usuario>"
  exit 1
fi

# Verificar si está en la lista de suspendidos
if [ -f "$SUSPEND_LIST" ] && grep -Fxq "$USUARIO" "$SUSPEND_LIST"; then
  echo "🟡 SUSPENDIDO"
  exit 0
fi

# Verificar si está revocado
if [ -f "$CRL_FILE" ] && openssl crl -inform PEM -text -noout -in "$CRL_FILE" | grep -q "$USUARIO"; then
  echo "🔴 REVOCADO"
  exit 0
fi

# Si no está suspendido ni revocado, se considera activo
echo "🟢 ACTIVO"
