#!/usr/bin/env bash
set -euo pipefail
trap '' PIPE  # evita que nc cierre el pipe y mate el script

# ---- Args ----
ARG="${1:-}"
[ -n "$ARG" ] || { echo "Uso: $0 <CN|archivo.ovpn>"; exit 1; }

# ---- Rutas / Env ----
EASYRSA_DIR="${EASYRSA_DIR:-/data/easy-rsa}"
OPENVPN_DIR="${OPENVPN_DIR:-/etc/openvpn}"
MGMT_HOST="${MGMT_HOST:-127.0.0.1}"
MGMT_PORT="${MGMT_PORT:-7505}"
META_DIR="/data/ovpn/metadatos"

# ---- Resolver CN (acepta .ovpn) ----
CN="$ARG"
if [[ "$ARG" == *.ovpn ]]; then
  BASE="$(basename "$ARG" .ovpn)"
  META="/data/ovpn/metadatos/${BASE}.json"
  OVPN="/data/ovpn/${BASE}.ovpn"
  if [ -f "$META" ]; then
    CN="$(grep -oE '"cn"[[:space:]]*:[[:space:]]*"[^"]+"' "$META" \
         | sed -E 's/.*"cn"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
  elif [ -f "$OVPN" ]; then
    CN="$(grep -oE '^# *"cn": *"[^"]+"' "$OVPN" | head -1 \
         | sed -E 's/^# *"cn": *"([^"]+)".*/\1/')"
  else
    echo "❌ No encuentro metadata para $ARG"; exit 1
  fi
fi
[ -n "$CN" ] || { echo "❌ No pude resolver CN"; exit 1; }

# ---- Helpers Management (mismo patrón que suspender_usuario.sh) ----
mgmt_up() { timeout 1 bash -lc "</dev/tcp/$MGMT_HOST/$MGMT_PORT" >/dev/null 2>&1; }
client_kill_cn() { printf 'kill %s\n' "$1" | timeout 1s nc -w 1 "$MGMT_HOST" "$MGMT_PORT" >/dev/null 2>&1 || true; }
client_kill_cid() { printf 'client-kill %s\n' "$1" | timeout 1s nc -w 1 "$MGMT_HOST" "$MGMT_PORT" >/dev/null 2>&1 || true; }

list_cids_for_cn() {
  printf 'status 2\n' | timeout 1s nc -w 1 "$MGMT_HOST" "$MGMT_PORT" 2>/dev/null |
  awk -F, -v cn="$CN" '
    BEGIN{cncol=cidcol=0}
    /^HEADER,CLIENT_LIST/{
      for(i=1;i<=NF;i++){
        gsub(/^ *| *$/,"",$i)
        if($i=="Common Name") cncol=i
        if($i=="Client ID")   cidcol=i
      }
      next
    }
    $1=="CLIENT_LIST" && cncol>0 && cidcol>0 && $cncol==cn { print $cidcol }
  '
}

# ---- 1) Cortar sesiones activas (idéntico enfoque al suspend) ----
if mgmt_up; then
  # por CN (best-effort)
  client_kill_cn "$CN"
  # por cada Client ID del CN
  mapfile -t CIDS < <(list_cids_for_cn || true)
  for cid in "${CIDS[@]:-}"; do
    [[ "$cid" =~ ^[0-9]+$ ]] && client_kill_cid "$cid"
  done
else
  echo "⚠️ Management no disponible; se cerrará al reconectar tras la revocación."
fi

# ---- 2) Revocar en Easy-RSA y regenerar CRL ----
cd "$EASYRSA_DIR" || { echo "❌ No encuentro $EASYRSA_DIR"; exit 1; }
[ -x ./easyrsa ] || { echo "❌ No encuentro ./easyrsa en $EASYRSA_DIR"; exit 1; }

EASYRSA_BATCH=1 ./easyrsa revoke "$CN"
EASYRSA_CRL_DAYS="${EASYRSA_CRL_DAYS:-3650}" ./easyrsa gen-crl
install -m 0644 -o root -g root "$EASYRSA_DIR/pki/crl.pem" "$OPENVPN_DIR/crl.pem"

# ---- 3) Quitar marcador de suspensión (si existiera) ----
rm -f "/etc/openvpn/suspendidos/${CN}" 2>/dev/null || true

# ---- 4) Actualizar metadata (revoked:true, suspended:false) ----
if [ -n "${BASE:-}" ] && [ -f "$META_DIR/${BASE}.json" ]; then
  sed -i -E 's/"revoked":[[:space:]]*(true|false)/"revoked": true/' "$META_DIR/${BASE}.json" || true
  sed -i -E 's/"suspended":[[:space:]]*(true|false)/"suspended": false/' "$META_DIR/${BASE}.json" || true
else
  for f in "$META_DIR"/*.json; do
    grep -q "\"cn\"[[:space:]]*:[[:space:]]*\"${CN}\"" "$f" 2>/dev/null || continue
    sed -i -E 's/"revoked":[[:space:]]*(true|false)/"revoked": true/' "$f" || true
    sed -i -E 's/"suspended":[[:space:]]*(true|false)/"suspended": false/' "$f" || true
  done
fi

echo "✅ Revocado ${CN} (CRL instalada; sesiones activas cortadas si existían)"
echo "ℹ️ La revocación es permanente: para re-habilitar acceso necesitas emitir un NUEVO certificado."
