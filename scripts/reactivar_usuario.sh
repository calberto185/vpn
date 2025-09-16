#!/usr/bin/env bash
set -euo pipefail

ARG="${1:-}"
[ -n "$ARG" ] || { echo "Uso: $0 <CN|archivo.ovpn>"; exit 1; }

CN="$ARG"
if [[ "$ARG" == *.ovpn ]]; then
  BASE="$(basename "$ARG" .ovpn)"
  META="/data/ovpn/metadatos/${BASE}.json"
  OVPN="/data/ovpn/${BASE}.ovpn"
  if [ -f "$META" ]; then
    CN="$(grep -oE '"cn"[[:space:]]*:[[:space:]]*"[^"]+"' "$META" | sed -E 's/.*"cn"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
  elif [ -f "$OVPN" ]; then
    CN="$(grep -oE '^# *"cn": *"[^"]+"' "$OVPN" | head -1 | sed -E 's/^# *"cn": *"([^"]+)".*/\1/')"
  fi
fi
[ -n "$CN" ] || { echo "❌ No pude resolver CN"; exit 1; }

rm -f "/etc/openvpn/suspendidos/${CN}" 2>/dev/null || true
echo "✅ Reactivado ${CN}"
