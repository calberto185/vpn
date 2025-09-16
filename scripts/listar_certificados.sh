#!/bin/bash
EASYRSA_DIR="/data/easy-rsa"
cd "$EASYRSA_DIR" || { echo "❌ No se encontró $EASYRSA_DIR"; exit 1; }

CERT_DIR="$EASYRSA_DIR/pki/issued"
if [ ! -d "$CERT_DIR" ]; then
  echo "❌ Directorio de certificados no encontrado: $CERT_DIR"
  exit 1
fi

echo "📄 Certificados emitidos:"
for cert in "$CERT_DIR"/*.crt; do
  usuario=$(basename "$cert" .crt)
  echo "- $usuario"
done
