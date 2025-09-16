#!/bin/bash
USUARIO="$1"
CERT_PATH="/data/easy-rsa/pki/issued/${USUARIO}.crt"

if [ -z "$USUARIO" ]; then
  echo "❌ Uso: $0 <nombre_usuario>"
  exit 1
fi

if [ ! -f "$CERT_PATH" ]; then
  echo "❌ Certificado no encontrado para $USUARIO"
  exit 1
fi

openssl x509 -in "$CERT_PATH" -text -noout
