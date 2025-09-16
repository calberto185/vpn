#!/usr/bin/env bash
# /usr/local/bin/tls-verify.sh
set -euo pipefail

# CN fiable en tls-verify:
CN="${X509_0_CN:-${common_name:-${1:-}}}"

if [ -z "$CN" ]; then
  echo "tls-verify: CN vacío; negando por seguridad" >&2
  exit 1
fi

MARKER="/etc/openvpn/suspendidos/${CN}"
if [ -f "$MARKER" ]; then
  echo "tls-verify: ${CN} suspendido" >&2
  exit 1
fi

exit 0
