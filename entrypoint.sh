#!/usr/bin/env bash
set -euo pipefail
umask 077

echo "🔧 Habilitando reenvío IP..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null || true

# -------- Variables --------
OPENVPN_DIR="/etc/openvpn"
EASYRSA_DIR="${EASYRSA_DIR:-/data/easy-rsa}"
OVPN_OUTPUT_DIR="${OVPN_OUTPUT_DIR:-/data/ovpn}"
TLS_MODE="${TLS_MODE:-tls-crypt}"                 # tls-crypt (recomendado) | tls-auth
TLS_KEY_PATH="${TLS_CRYPT_KEY:-$OPENVPN_DIR/ta.key}"
OVPN_OUT_IFACE_DEFAULT="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
OUT_IF="${OVPN_OUT_IFACE:-${OVPN_OUT_IFACE_DEFAULT:-eth0}}"
OVPN_NET="${OVPN_NET:-10.8.0.0/24}"
OVPN_NET6="${OVPN_NET6:-fd00::/64}"

echo "🌐 Interfaz de salida para NAT: ${OUT_IF}"
echo "🧭 Redes tun: ${OVPN_NET} / ${OVPN_NET6}"

# -------- Asegurar herramientas --------
if ! command -v iptables >/dev/null; then apt-get update && apt-get install -y iptables || true; fi
command -v ip6tables >/dev/null || true
command -v nft >/dev/null || true

# -------- NAT IPv4 --------
if ! iptables -t nat -C POSTROUTING -s "${OVPN_NET}" -o "${OUT_IF}" -j MASQUERADE 2>/dev/null; then
  iptables -t nat -A POSTROUTING -s "${OVPN_NET}" -o "${OUT_IF}" -j MASQUERADE || true
fi
if ! iptables -C FORWARD -i tun0 -j ACCEPT 2>/dev/null; then
  iptables -A FORWARD -i tun0 -j ACCEPT || true
fi
if ! iptables -C FORWARD -o tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
  iptables -A FORWARD -o tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT || true
fi

# -------- NAT IPv6 --------
if command -v ip6tables >/dev/null; then
  modprobe ip6table_nat || true
  if ! ip6tables -t nat -C POSTROUTING -s "${OVPN_NET6}" -o "${OUT_IF}" -j MASQUERADE 2>/dev/null; then
    ip6tables -t nat -A POSTROUTING -s "${OVPN_NET6}" -o "${OUT_IF}" -j MASQUERADE || echo "⚠️ NAT IPv6 no soportado. Continuando."
  fi
fi
if command -v nft >/dev/null; then
  nft list ruleset >/dev/null 2>&1 || true
  nft list table ip6 nat >/dev/null 2>&1 || nft add table ip6 nat
  nft list chain ip6 nat postrouting >/dev/null 2>&1 || nft add chain ip6 nat postrouting "{ type nat hook postrouting priority 100 ; }"
  if ! nft list ruleset 2>/dev/null | grep -F "ip6 saddr ${OVPN_NET6}" | grep -F "masquerade" >/dev/null; then
    nft add rule ip6 nat postrouting ip6 saddr "${OVPN_NET6}" oifname "${OUT_IF}" masquerade || true
  fi
fi

# -------- Autocuración Easy-RSA / PKI / server.conf --------
mkdir -p "$OVPN_OUTPUT_DIR" /var/log/openvpn

if [ ! -d "$EASYRSA_DIR/pki" ] || [ ! -f "$OPENVPN_DIR/server.conf" ]; then
  echo "🔧 Inicializando OpenVPN/Easy-RSA (faltan assets)"
  /usr/local/bin/init-openvpn.sh
else
  echo "🟢 OpenVPN y Easy-RSA ya están listos."
fi

# -------- Asegurar clave simétrica TLS --------
if [ ! -f "$TLS_KEY_PATH" ]; then
  echo "⚠️ $TLS_KEY_PATH no existe; generando..."
  openvpn --genkey --secret "$TLS_KEY_PATH"
  chmod 600 "$TLS_KEY_PATH"
fi

# -------- Alinear server.conf con TLS_MODE --------
if [ -f "$OPENVPN_DIR/server.conf" ]; then
  if ! grep -qE '^[[:space:]]*management[[:space:]]+0\.0\.0\.0[[:space:]]+7505' "$OPENVPN_DIR/server.conf"; then
    echo "management 0.0.0.0 7505" >> "$OPENVPN_DIR/server.conf"
  fi

  if [ "${TLS_MODE}" = "tls-auth" ]; then
    sed -i '/^[[:space:]]*tls-crypt[[:space:]]\+/d' "$OPENVPN_DIR/server.conf"
    if grep -q 'tls-auth' "$OPENVPN_DIR/server.conf"; then
      sed -i 's|^[[:space:]]*tls-auth .*|tls-auth ta.key 0|' "$OPENVPN_DIR/server.conf"
    else
      echo "tls-auth ta.key 0" >> "$OPENVPN_DIR/server.conf"
    fi
  else
    sed -i '/^[[:space:]]*tls-auth[[:space:]]\+/d' "$OPENVPN_DIR/server.conf"
    if grep -q 'tls-crypt' "$OPENVPN_DIR/server.conf"; then
      sed -i 's|^[[:space:]]*tls-crypt .*|tls-crypt ta.key|' "$OPENVPN_DIR/server.conf"
    else
      echo "tls-crypt ta.key" >> "$OPENVPN_DIR/server.conf"
    fi
  fi
fi

# -------- Monitor opcional --------
if [ -x /scripts/log-conexiones.sh ]; then
  echo "📡 Iniciando monitoreo de conexiones VPN..."
  /scripts/log-conexiones.sh &
fi

# Asegurar permisos de ejecución en scripts
if [ -f /scripts/notificar_estado.sh ]; then
  chmod +x /scripts/notificar_estado.sh
fi
# -------- Endpoint --------
IP_PUBLICA="${OVPN_ENDPOINT:-$(curl -s ifconfig.me || echo "YOUR_SERVER_IP")}"
echo "🚀 Iniciando OpenVPN en primer plano..."
echo "✅ Public endpoint: $IP_PUBLICA   (TLS_MODE=${TLS_MODE})"

exec openvpn --config "$OPENVPN_DIR/server.conf" --cd "$OPENVPN_DIR" --log /var/log/openvpn/openvpn.log
