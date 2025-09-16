#!/usr/bin/env bash
set -euo pipefail
umask 077

# -------- Args --------
USUARIO="${1:-}"
DEVICE="${2:-}"
DEVICE_ID="${3:-}"
USER_ID="${4:-}"
SERVER_ID="${5:-}"
HOSTNAME="${6:-}"
VALID_DAYS="${7:-}"
TAGS_RAW="${8:-}"       # Ej: '"peru","laptop","temporal"'  o  peru,laptop,temporal
NOTE="${9:-}"

if [ "$#" -lt 9 ]; then
  echo "❌ Uso: $0 <usuario> <device> <device_id> <user_id> <server_id> <hostname> <valid_days> <tags> <note>"
  exit 1
fi
case "${VALID_DAYS}" in (*[!0-9]*|'') echo "❌ VALID_DAYS debe ser un número de días (ej. 30)"; exit 1;; esac

# -------- Config / Env --------
EASYRSA_DIR="${EASYRSA_DIR:-/data/easy-rsa}"
OUTPUT_DIR="${OVPN_OUTPUT_DIR:-/data/ovpn}"
OPENVPN_DIR="/etc/openvpn"
TLS_MODE="${TLS_MODE:-tls-crypt}"                     # tls-crypt (recomendado) | tls-auth
TLS_KEY_PATH="${TLS_CRYPT_KEY:-$OPENVPN_DIR/ta.key}"  # misma ruta para ambos modos
OVPN_ENDPOINT="${OVPN_ENDPOINT:-}"
CLIENT_MSSFIX="${CLIENT_MSSFIX:-1400}"                      # ajusta los paquetes de envio para evitar over


# Dependencias
for c in curl uuidgen date openssl; do
  command -v "$c" >/dev/null || { echo "❌ Falta comando requerido: $c"; exit 1; }
done

# -------- Auto-curación Easy-RSA / PKI --------
if [ ! -d "$EASYRSA_DIR" ]; then
  echo "⚠️ $EASYRSA_DIR no existe; copiando Easy-RSA..."
  mkdir -p "$EASYRSA_DIR"
  cp -r /usr/share/easy-rsa/* "$EASYRSA_DIR" || { echo "❌ No se pudo copiar /usr/share/easy-rsa a $EASYRSA_DIR"; exit 1; }
fi

cd "$EASYRSA_DIR" || { echo "❌ No se encontró $EASYRSA_DIR"; exit 1; }

if [ ! -f "pki/ca.crt" ]; then
  echo "⚠️ PKI no inicializada. Inicializando..."
  ./easyrsa init-pki
  echo -ne '\n' | ./easyrsa build-ca nopass
fi

# Asegurar clave simétrica para tls-{auth,crypt}
if [ ! -f "$TLS_KEY_PATH" ]; then
  echo "⚠️ $TLS_KEY_PATH no existe; generando..."
  openvpn --genkey --secret "$TLS_KEY_PATH"
  chmod 600 "$TLS_KEY_PATH"
fi

mkdir -p "$OUTPUT_DIR" "${OUTPUT_DIR}/metadatos"

# -------- Sanitizar CN (para el certificado) --------
RAW_CN="$USUARIO"
SAFE_CN="$(printf '%s' "$RAW_CN" \
  | tr '[:upper:]' '[:lower:]' \
  | sed 's/[^a-z0-9._-]/-/g' \
  | sed 's/-\{2,\}/-/g; s/^-//; s/-$//')"

SUFFIX="$(uuidgen | cut -d- -f1)"
MAX=63
NEEDED=$(( MAX - 1 - ${#SUFFIX} ))
if [ ${#SAFE_CN} -gt $NEEDED ]; then
  SAFE_CN="${SAFE_CN:0:$NEEDED}-$SUFFIX"
fi

# -------- Generar cert del cliente con expiración = VALID_DAYS --------
export EASYRSA_CERT_EXPIRE="${VALID_DAYS}"
EASYRSA_BATCH=1 /bin/bash ./easyrsa build-client-full "$SAFE_CN" nopass || {
  echo "❌ Error al generar certificado para $USUARIO (CN: $SAFE_CN)"
  exit 1
}

CRT_PATH="${EASYRSA_DIR}/pki/issued/${SAFE_CN}.crt"
KEY_PATH="${EASYRSA_DIR}/pki/private/${SAFE_CN}.key"
CA_PATH="${EASYRSA_DIR}/pki/ca.crt"
[ -f "$CRT_PATH" ] && [ -f "$KEY_PATH" ] && [ -f "$CA_PATH" ] || {
  echo "❌ Faltan archivos de ${SAFE_CN}"
  exit 1
}

# -------- Endpoint --------
if [ -z "$OVPN_ENDPOINT" ]; then
  OVPN_ENDPOINT="$(curl -s ifconfig.me || true)"
fi
[ -n "$OVPN_ENDPOINT" ] || { echo "❌ No se pudo obtener endpoint público"; exit 1; }

# -------- Tiempos --------
NOW_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
EXPIRES_UTC="$(date -u -d "+${VALID_DAYS} days" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v+${VALID_DAYS}d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")"

# -------- Extraer PEM puro --------
CERT_PEM="$(openssl x509 -in "$CRT_PATH" -outform PEM)"
KEY_PEM="$(openssl pkey -in "$KEY_PATH" 2>/dev/null || cat "$KEY_PATH")"
CA_PEM="$(cat "$CA_PATH")"
TLS_KEY_CONTENT="$(cat "$TLS_KEY_PATH")"

# -------- Normalizar tags a JSON --------
if printf '%s' "$TAGS_RAW" | grep -q '^\s*\['; then
  TAGS_JSON="$TAGS_RAW"
else
  IFS=',' read -ra _tags <<< "$TAGS_RAW"
  _out=""
  for t in "${_tags[@]}"; do
    t="$(printf '%s' "$t" | sed 's/^ *//; s/ *$//' | sed 's/^"//; s/"$//')"
    t_escaped="$(printf '%s' "$t" | sed 's/"/\\"/g')"
    [ -z "$_out" ] && _out="\"$t_escaped\"" || _out="$_out,\"$t_escaped\""
  done
  TAGS_JSON="[$_out]"
fi

# -------- Nombre del archivo .ovpn (amigable) --------
SAFE_OVPN_NAME="$(printf '%s' "$USUARIO" | sed 's/[^A-Za-z0-9._-]/_/g')"
OVPN_FILE="${OUTPUT_DIR}/${SAFE_OVPN_NAME}.ovpn"
[ -f "$OVPN_FILE" ] && { echo "⚠️ $OVPN_FILE ya existe. Elimínalo o usa otro nombre."; exit 1; }

# -------- Metadata JSON (archivo aparte) --------
META_JSON="${OUTPUT_DIR}/metadatos/${SAFE_OVPN_NAME}.json"

TLS_AUTH_FLAG="false"
TLS_CRYPT_FLAG="false"
if [ "$TLS_MODE" = "tls-auth" ]; then
  TLS_AUTH_FLAG="true"
else
  TLS_CRYPT_FLAG="true"
fi


cat > "$META_JSON" <<JSON
{
  "version": 2,
  "user": "${USUARIO}",
  "user_id": "${USER_ID}",
  "device": "${DEVICE}",
  "device_id": "${DEVICE_ID}",
  "server": "${OVPN_ENDPOINT}",
  "server_id": "${SERVER_ID}",
  "hostname": "${HOSTNAME}",
  "ip": "${OVPN_ENDPOINT}",
  "created_at": "${NOW_UTC}",
  "expires_at": "${EXPIRES_UTC}",
  "valid_days": ${VALID_DAYS},
  "revoked": false,
  "suspended": false,
  "tls_auth": ${TLS_AUTH_FLAG},
  "tls_crypt": ${TLS_CRYPT_FLAG},
  "cipher": "AES-256-CBC",
  "auth": "SHA256",
  "restrict_client": true,
  "profile_type": "personal",
  "tags": ${TAGS_JSON},
  "note": "$(printf '%s' "$NOTE" | sed 's/"/\\"/g')",
  "cn": "${SAFE_CN}",
  "ovpn_file": "${OVPN_FILE}"
}
JSON
chmod 600 "$META_JSON"

# -------- Escribir .ovpn --------
cat > "$OVPN_FILE" <<EOF
# ===BEGIN METADATA===
$(sed 's/^/# /' "$META_JSON")
# ===END METADATA===
client
dev tun
proto udp4
remote ${OVPN_ENDPOINT} 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-CBC
auth SHA256

sndbuf 0
rcvbuf 0
verb 3
pull
redirect-gateway def1
dhcp-option DNS 1.1.1.1
dhcp-option DNS 8.8.8.8
<ca>
${CA_PEM}
</ca>
<cert>
${CERT_PEM}
</cert>
<key>
${KEY_PEM}
</key>
EOF

# Añadir mssfix SOLO si fue definido
if [ -n "${CLIENT_MSSFIX}" ]; then
  echo "mssfix ${CLIENT_MSSFIX}" >> "$OVPN_FILE"
fi


if [ "$TLS_MODE" = "tls-auth" ]; then
  cat >> "$OVPN_FILE" <<EOF
<tls-auth>
${TLS_KEY_CONTENT}
</tls-auth>
key-direction 1
EOF
else
  cat >> "$OVPN_FILE" <<EOF
<tls-crypt>
${TLS_KEY_CONTENT}
</tls-crypt>
EOF
fi

chmod 600 "$OVPN_FILE"
echo "✅ Archivo generado: $OVPN_FILE"
