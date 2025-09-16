#!/usr/bin/env bash
set -euo pipefail
umask 077


# -------- Config/Env --------
EASYRSA_DIR="${EASYRSA_DIR:-/data/easy-rsa}"
OPENVPN_DIR="/etc/openvpn"
OVPN_OUTPUT_DIR="${OVPN_OUTPUT_DIR:-/data/ovpn}"
TLS_MODE="${TLS_MODE:-tls-crypt}"                     # tls-crypt (recomendado) | tls-auth
TLS_KEY_PATH="${TLS_CRYPT_KEY:-$OPENVPN_DIR/ta.key}"  # misma ruta para ambos modos
OVPN_NET="${OVPN_NET:-10.8.0.0/24}"
OVPN_NET6="${OVPN_NET6:-fd00::/64}"
CLIENT_NAME="${CLIENT_NAME:-clienteAdminPrueba}"
OVPN_ENDPOINT="${OVPN_ENDPOINT:-}"
MSSFIX_VAL="${MSSFIX_VAL:-1400}"                      # ajusta los paquetes de envio para evitar over

mkdir -p "$EASYRSA_DIR" "$OPENVPN_DIR" "$OVPN_OUTPUT_DIR" /var/log/openvpn
mkdir -p "$OPENVPN_DIR/suspendidos" 

# -------- Easy-RSA disponible en /data --------
if [ ! -f "$EASYRSA_DIR/easyrsa" ]; then
  cp -r /usr/share/easy-rsa/* "$EASYRSA_DIR"
fi
cd "$EASYRSA_DIR"

# -------- PKI: crear si no existe --------
if [ ! -f "$EASYRSA_DIR/pki/ca.crt" ]; then
  echo "⚠️ PKI no válida o ausente. Inicializando..."
  rm -rf "$EASYRSA_DIR/pki"
  ./easyrsa init-pki
  echo -ne '\n' | ./easyrsa build-ca nopass
fi

# -------- Cert/clave del servidor y DH --------
if [ ! -f "$EASYRSA_DIR/pki/issued/server.crt" ] || [ ! -f "$EASYRSA_DIR/pki/private/server.key" ]; then
  EASYRSA_BATCH=1 /bin/bash ./easyrsa build-server-full server nopass
fi
[ -f "$EASYRSA_DIR/pki/dh.pem" ] || ./easyrsa gen-dh

# -------- CRL (para revocaciones) --------
if [ ! -f "$EASYRSA_DIR/pki/crl.pem" ]; then
  EASYRSA_CRL_DAYS="${EASYRSA_CRL_DAYS:-3650}" ./easyrsa gen-crl
fi
install -m 0644 "$EASYRSA_DIR/pki/crl.pem" "$OPENVPN_DIR/crl.pem"

# -------- Clave simétrica para tls-* --------
if [ ! -f "$TLS_KEY_PATH" ]; then
  openvpn --genkey --secret "$TLS_KEY_PATH"
  chmod 600 "$TLS_KEY_PATH"
fi

# -------- Copiar artefactos al directorio del servidor --------
cp -f \
  "$EASYRSA_DIR/pki/ca.crt" \
  "$EASYRSA_DIR/pki/issued/server.crt" \
  "$EASYRSA_DIR/pki/private/server.key" \
  "$EASYRSA_DIR/pki/dh.pem" \
  "$OPENVPN_DIR"

chmod 600 "$OPENVPN_DIR/server.key" "$TLS_KEY_PATH"
chmod 644 "$OPENVPN_DIR/ca.crt" "$OPENVPN_DIR/server.crt" "$OPENVPN_DIR/dh.pem"

# -------- Bloque condicional para tls-verify --------
TLS_VERIFY_BLOCK=""
if [ -x /usr/local/bin/tls-verify.sh ]; then
  TLS_VERIFY_BLOCK=$'script-security 2\n'\
$'tls-verify /usr/local/bin/tls-verify.sh'
else
  echo "⚠️ /usr/local/bin/tls-verify.sh no encontrado; se omite tls-verify"
fi

# -------- Generar server.conf con TLS_MODE --------
TLS_LINE="tls-crypt ta.key"
if [ "$TLS_MODE" = "tls-auth" ]; then
  TLS_LINE="tls-auth ta.key 0"
fi

# -------- Utilidades para netmask desde CIDR --------
CIDR="${OVPN_NET#*/}"
NET_BASE="${OVPN_NET%/*}"
mask_from_cidr() {
  local p="$1"; local m=$(( 0xffffffff << (32 - p) & 0xffffffff ))
  printf "%d.%d.%d.%d" $(( (m>>24)&255 )) $(( (m>>16)&255 )) $(( (m>>8)&255 )) $(( m&255 ))
}
NETMASK="$(mask_from_cidr "${CIDR:-24}")"

# -------- server.conf --------
cat > "$OPENVPN_DIR/server.conf" <<CONF
port 1194
proto udp4
dev tun

ca ca.crt
cert server.crt
key server.key
dh dh.pem
${TLS_LINE}
crl-verify crl.pem

topology subnet
server ${OVPN_NET%/*} 255.255.255.0
server-ipv6 ${OVPN_NET6}

push "redirect-gateway def1 bypass-dhcp"
push "route-ipv6 2000::/3"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS6 2606:4700:4700::1111"
push "dhcp-option DNS6 2001:4860:4860::8888"

push-peer-info
persist-key
persist-tun
keepalive 10 120
explicit-exit-notify 1

cipher AES-256-CBC
auth SHA256


${TLS_VERIFY_BLOCK}

mssfix ${MSSFIX_VAL}
sndbuf 0
rcvbuf 0
push "sndbuf 0"
push "rcvbuf 0"
# (opcional) tun-mtu 1400

user nobody
group nogroup

status /var/log/openvpn/status.log
log /var/log/openvpn/openvpn.log
verb 3

# Interfaz de management (exponla en docker-compose con 7505)
management 0.0.0.0 7505


script-security 2
client-connect /scripts/notificar_estado.sh
client-disconnect /scripts/notificar_estado.sh
CONF

# -------- Crear un cliente de prueba si no existe --------
if [ ! -f "$EASYRSA_DIR/pki/issued/${CLIENT_NAME}.crt" ]; then
  EASYRSA_BATCH=1 /bin/bash ./easyrsa build-client-full "$CLIENT_NAME" nopass
fi

CRT_PATH="$EASYRSA_DIR/pki/issued/${CLIENT_NAME}.crt"
KEY_PATH="$EASYRSA_DIR/pki/private/${CLIENT_NAME}.key"
CA_PATH="$EASYRSA_DIR/pki/ca.crt"

# Endpoint público (si no se definió OVPN_ENDPOINT)
if [ -z "$OVPN_ENDPOINT" ]; then
  OVPN_ENDPOINT="$(curl -s ifconfig.me || echo "YOUR_SERVER_IP")"
fi

# Extraer PEM puro para el .ovpn de ejemplo
CERT_PEM="$(openssl x509 -in "$CRT_PATH" -outform PEM)"
KEY_PEM="$(openssl pkey -in "$KEY_PATH" 2>/dev/null || cat "$KEY_PATH")"
CA_PEM="$(cat "$CA_PATH")"
TLS_KEY_CONTENT="$(cat "$TLS_KEY_PATH")"

OVPN_SAMPLE="$OVPN_OUTPUT_DIR/${CLIENT_NAME}.ovpn"
cat > "$OVPN_SAMPLE" <<EOF
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
mssfix ${MSSFIX_VAL}
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

if [ "$TLS_MODE" = "tls-auth" ]; then
  cat >> "$OVPN_SAMPLE" <<EOF
<tls-auth>
${TLS_KEY_CONTENT}
</tls-auth>
key-direction 1
EOF
else
  cat >> "$OVPN_SAMPLE" <<EOF
<tls-crypt>
${TLS_KEY_CONTENT}
</tls-crypt>
EOF
fi

chmod 600 "$OVPN_SAMPLE"

# -------- Verificación mínima --------
for f in ca.crt server.crt server.key dh.pem; do
  [ -f "$OPENVPN_DIR/$f" ] || { echo "❌ Falta $OPENVPN_DIR/$f"; exit 1; }
done
[ -s "$TLS_KEY_PATH" ] || { echo "❌ Falta $TLS_KEY_PATH"; exit 1; }
[ -s "$OPENVPN_DIR/crl.pem" ] || { echo "❌ Falta $OPENVPN_DIR/crl.pem"; exit 1; }

echo "✅ OpenVPN inicializado. TLS_MODE=${TLS_MODE}. Cliente de ejemplo: $OVPN_SAMPLE"
