#!/bin/bash
USUARIO="$1"
OVPN_PATH="/data/ovpn/${USUARIO}.ovpn"
ZIP_PATH="/data/ovpn/${USUARIO}.zip"

if [ -z "$USUARIO" ]; then
  echo "❌ Uso: $0 <nombre_usuario>"
  exit 1
fi

if [ ! -f "$OVPN_PATH" ]; then
  echo "❌ No se encontró archivo .ovpn: $OVPN_PATH"
  exit 1
fi

TEMP_DIR="/tmp/ovpn_${USUARIO}"
mkdir -p "$TEMP_DIR"
cp "$OVPN_PATH" "$TEMP_DIR/"

echo "📎 Archivo de configuración para OpenVPN (${USUARIO})" > "$TEMP_DIR/README.txt"
echo "" >> "$TEMP_DIR/README.txt"
echo "1. Descarga este archivo zip y extrae el .ovpn." >> "$TEMP_DIR/README.txt"
echo "2. Abre tu cliente OpenVPN (ej: OpenVPN Connect, Tunnelblick, etc.)." >> "$TEMP_DIR/README.txt"
echo "3. Importa el archivo ${USUARIO}.ovpn para conectarte." >> "$TEMP_DIR/README.txt"

cd "$TEMP_DIR"
zip -r "$ZIP_PATH" ./* > /dev/null
cd -

rm -rf "$TEMP_DIR"

echo "✅ Archivo generado: $ZIP_PATH"
