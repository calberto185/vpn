#!/usr/bin/env bash
set -euo pipefail

ARG="${1:-}"
[ -n "$ARG" ] || { echo "Uso: $0 <CN|archivo.ovpn>"; exit 1; }

# --- Resolver CN (acepta .ovpn) ---
CN="$ARG"
if [[ "$ARG" == *.ovpn ]]; then
  BASE="$(basename "$ARG" .ovpn)"
  META="/data/ovpn/metadatos/${BASE}.json"
  OVPN="/data/ovpn/${BASE}.ovpn"
  if [ -f "$META" ]; then
    CN="$(grep -oE '"cn"[[:space:]]*:[[:space:]]*"[^"]+"' "$META" | sed -E 's/.*"cn"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
  elif [ -f "$OVPN" ]; then
    CN="$(grep -oE '^# *"cn": *"[^"]+"' "$OVPN" | head -1 | sed -E 's/^# *"cn": *"([^"]+)".*/\1/')"
  else
    echo "❌ No encuentro metadata para $ARG"; exit 1
  fi
fi
[ -n "$CN" ] || { echo "❌ No pude resolver CN"; exit 1; }

# --- Marker para tls-verify (bloquea reconexiones) ---
MARKER_DIR="/etc/openvpn/suspendidos"
MARKER="${MARKER_DIR}/${CN}"
install -d -m 0750 -o root -g nogroup "$MARKER_DIR"
: > "$MARKER"
chgrp nogroup "$MARKER" 2>/dev/null || true
chmod 640 "$MARKER"

# --- Management ---
MGMT_HOST="${MGMT_HOST:-127.0.0.1}"
MGMT_PORT="${MGMT_PORT:-7505}"

# Si no hay management, igual queda suspendido para el próximo handshake
timeout 1 bash -lc "</dev/tcp/$MGMT_HOST/$MGMT_PORT" >/dev/null 2>&1 || {
  echo "✅ Suspendido ${CN} (sin management; corte en próximo intento)"; exit 0; }

# 1) Matar por CN (cadena)
printf 'kill %s\n' "$CN" | timeout 1s nc -w 1 "$MGMT_HOST" "$MGMT_PORT" >/dev/null 2>&1 || true

# 2) Tomar snapshot y matar por CID (números)
mapfile -t CIDS < <(
  printf 'status 2\n' | timeout 1s nc -w 1 "$MGMT_HOST" "$MGMT_PORT" 2>/dev/null |
  awk -F, -v cn="$CN" '
    BEGIN{cncol=cidcol=0}
    /^HEADER,CLIENT_LIST/{
      for(i=1;i<=NF;i++){ gsub(/^ *| *$/,"",$i);
        if($i=="Common Name") cncol=i;
        if($i=="Client ID")   cidcol=i; }
      next }
    $1=="CLIENT_LIST" && cncol>0 && cidcol>0 && $cncol==cn { print $cidcol }'
)
for cid in "${CIDS[@]:-}"; do
  [[ "$cid" =~ ^[0-9]+$ ]] || continue
  printf 'client-kill %s\n' "$cid" | timeout 1s nc -w 1 "$MGMT_HOST" "$MGMT_PORT" >/dev/null 2>&1 || true
done

echo "✅ Suspendido ${CN} (sesiones activas cortadas si existían)"
