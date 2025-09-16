#!/usr/bin/env bash
# /scripts/notificar_estado.sh
# Notifica al backend el estado de conexión de un perfil .ovpn (conectado/desconectado)
# Incluye IP pública del cliente y ubicación (ipinfo.io).
# Requiere: curl
# Lee metadatos desde /data/ovpn/metadatos/*.json (generados por crear_usuario.sh)
# Cómo usar con OpenVPN (server.conf):
#   script-security 2
#   client-connect /scripts/notificar_estado.sh
#   client-disconnect /scripts/notificar_estado.sh
set -euo pipefail
umask 077

LOG_FILE="${LOG_FILE:-/var/log/openvpn/notificar_estado.log}"
API_URL="${API_URL:-http://localhost:3000/api/vpn/certificates/updatestate}"
AUTH_TOKEN="${AUTH_TOKEN:-${BACKEND_TOKEN:-}}"
METADATA_DIR="${METADATA_DIR:-/data/ovpn/metadatos}"
STATUS_FILE="${STATUS_FILE:-/var/log/openvpn/status.log}"
IPINFO_TOKEN="${IPINFO_TOKEN:-}"

timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log() {
  local level="$1"; shift || true
  printf "%s [%s] %s\n" "$(timestamp)" "$level" "$*" >> "$LOG_FILE"
}

# Determinar CN y estado desde variables de entorno que OpenVPN exporta
CN="${common_name:-${X509_0_CN:-${username:-}}}"
ST=""
case "${script_type:-}" in
  client-connect)    ST="true"  ;;
  client-disconnect) ST="false" ;;
  *)
    # Modo manual/CLI: permitir 'connect'/'disconnect' como argumento opcional
    if [[ "${1:-}" == "connect" ]]; then ST="true"; fi
    if [[ "${1:-}" == "disconnect" ]]; then ST="false"; fi
  ;;
esac

mkdir -p "$(dirname "$LOG_FILE")"

if [[ -z "${CN:-}" ]]; then
  log "WARN" "CN vacío; no se notificará"
  exit 0
fi
if [[ -z "${ST:-}" ]]; then
  log "WARN" "Estado no reconocido (script_type='${script_type:-}'); no se notificará para CN='${CN}'"
  exit 0
fi
if [[ -z "${AUTH_TOKEN:-}" ]]; then
  log "ERROR" "AUTH_TOKEN/BACKEND_TOKEN vacío; defínelo en el contenedor/env"
  exit 0
fi

# Buscar archivo de metadatos que contenga "cn": "<CN>"
META_FILE=""
if [[ -d "$METADATA_DIR" ]]; then
  while IFS= read -r -d '' f; do
    if grep -q "\"cn\"[[:space:]]*:[[:space:]]*\"${CN}\"" "$f"; then
      META_FILE="$f"
      break
    fi
  done < <(find "$METADATA_DIR" -type f -name "*.json" -print0 2>/dev/null || true)
fi

if [[ -z "${META_FILE:-}" || ! -f "$META_FILE" ]]; then
  log "ERROR" "No se encontró metadatos para CN='${CN}' en ${METADATA_DIR}"
  exit 0
fi

# Función robusta para extraer valores de JSON (formato pretty por línea)
_extract_json() {
  local key="$1" file="$2"
  sed -n -E "s/^[[:space:]]*\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" "$file" | head -n1
}

USER_ID="$(_extract_json user_id "$META_FILE")"
DEVICE_ID="$(_extract_json device_id "$META_FILE")"
SERVER_ID="$(_extract_json server_id "$META_FILE")"
SERVER_IP="$(_extract_json ip "$META_FILE")"

if [[ -z "${USER_ID:-}" || -z "${DEVICE_ID:-}" || -z "${SERVER_ID:-}" || -z "${SERVER_IP:-}" ]]; then
  log "ERROR" "Campos faltantes en metadatos (user_id='${USER_ID}', device_id='${DEVICE_ID}', server_id='${SERVER_ID}'), ip='${SERVER_IP}') para CN='${CN}' (file=${META_FILE})"
  exit 0
fi

API_URL="http://${SERVER_IP}:3000/api/vpn/certificates/updatestate"

# ---------- Obtener IP pública del cliente ----------
CLIENT_IP=""
# Variables que OpenVPN puede exportar
if [[ -n "${untrusted_ip:-}" ]]; then
  CLIENT_IP="$untrusted_ip"
elif [[ -n "${trusted_ip:-}" ]]; then
  CLIENT_IP="$trusted_ip"
fi

# Si no hay env var, intentar desde status.log (CLIENT_LIST)
# Formato esperado de línea: CLIENT_LIST,<CN>,<VPN_IP>,<REAL_ADDR>,...
if [[ -z "$CLIENT_IP" && -r "$STATUS_FILE" ]]; then
  REAL_ADDR="$(tac "$STATUS_FILE" | awk -F',' -v cn="$CN" '/^CLIENT_LIST/ { if ($2==cn) { print $4; exit } }' 2>/dev/null || true)"
  # REAL_ADDR suele ser "IP:PORT"
  if [[ -n "$REAL_ADDR" ]]; then
    CLIENT_IP="${REAL_ADDR%%:*}"
  fi
fi

# ---------- Geolocalización vía ipinfo.io ----------
GEO_COUNTRY=""; GEO_REGION=""; GEO_CITY=""; GEO_LAT=""; GEO_LON=""
if [[ -n "$CLIENT_IP" ]]; then
  GEO_URL="https://ipinfo.io/${CLIENT_IP}/json"
  if [[ -n "$IPINFO_TOKEN" ]]; then
    GEO_URL="${GEO_URL}?token=${IPINFO_TOKEN}"
  fi
  set +e
  GEO_JSON="$(curl -m 5 -sS "$GEO_URL")"
  CURL_RC=$?
  set -e
  if [[ $CURL_RC -eq 0 && -n "$GEO_JSON" ]]; then
    GEO_COUNTRY="$(printf '%s' "$GEO_JSON" | sed -n -E 's/.*"country"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1)"
    GEO_REGION="$(printf '%s' "$GEO_JSON" | sed -n -E 's/.*"region"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1)"
    GEO_CITY="$(printf '%s' "$GEO_JSON" | sed -n -E 's/.*"city"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1)"
    LOC_PAIR="$(printf '%s' "$GEO_JSON" | sed -n -E 's/.*"loc"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1)"
    if [[ -n "$LOC_PAIR" && "$LOC_PAIR" == *","* ]]; then
      GEO_LAT="${LOC_PAIR%%,*}"
      GEO_LON="${LOC_PAIR##*,}"
    fi
  else
    log "WARN" "Geo lookup falló para IP=${CLIENT_IP} rc=${CURL_RC}"
  fi
fi

# Construir JSON y enviar
PAYLOAD=$(cat <<JSON
{
  "server_id": "${SERVER_ID}",
  "user_id":   "${USER_ID}",
  "device_id": "${DEVICE_ID}",
  "state": ${ST},
  "client_ip": "${CLIENT_IP}",
  "location": {
    "country": "${GEO_COUNTRY}",
    "region":  "${GEO_REGION}",
    "city":    "${GEO_CITY}",
    "lat":     "${GEO_LAT}",
    "lon":     "${GEO_LON}"
  }
}
JSON
)

set +e
HTTP_RES=$(curl -sS -o /tmp/noti_resp.$$ -w "%{http_code}" -X POST "$API_URL" \
  -H "Authorization: ${AUTH_TOKEN}" \
  -H "Content-Type: application/json" \
  --data "${PAYLOAD}" \
  --retry 5 --retry-delay 2 --max-time 15)
CURL_RC=$?
RESP_SNIP=$(head -c 300 /tmp/noti_resp.$$ 2>/dev/null | tr '\n' ' ' || true)
rm -f /tmp/noti_resp.$$
set -e

if [[ $CURL_RC -ne 0 ]]; then
  log "ERROR" "curl fallo rc=${CURL_RC} http=${HTTP_RES} CN='${CN}' payload=${PAYLOAD} resp='${RESP_SNIP}'"
  exit 0
fi

if [[ "$HTTP_RES" != 2* && "$HTTP_RES" != 3* ]]; then
  log "ERROR" "HTTP ${HTTP_RES} al notificar CN='${CN}'. Resp='${RESP_SNIP}'"
  exit 0
fi

log "INFO" "Notificado OK CN='${CN}' state=${ST} ip=${CLIENT_IP} http=${HTTP_RES}"
exit 0
