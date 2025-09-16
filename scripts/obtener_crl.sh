#!/bin/bash
CRL_PATH="/data/easy-rsa/pki/crl.pem"

if [ ! -f "$CRL_PATH" ]; then
  echo "❌ CRL no encontrada: $CRL_PATH"
  exit 1
fi

cat "$CRL_PATH"
