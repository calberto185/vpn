#!/bin/bash
set -e

PKI_DIR="/etc/openvpn/pki"

echo "🔧 Iniciando configuración de PKI y certificados..."

# Crear PKI si no existe
if [ ! -d "$PKI_DIR" ]; then
    echo "📁 Inicializando PKI..."
    ./easyrsa init-pki
fi

# Crear CA si no existe
if [ ! -f "$PKI_DIR/ca.crt" ]; then
    echo "📜 Generando CA..."
    ./easyrsa build-ca nopass
fi

# Generar Diffie-Hellman
if [ ! -f "$PKI_DIR/dh.pem" ]; then
    echo "🔑 Generando parámetros Diffie-Hellman..."
    ./easyrsa gen-dh
fi

# Generar certificado del servidor
if [ ! -f "$PKI_DIR/issued/server.crt" ]; then
    echo "🖥️ Generando certificado del servidor..."
    ./easyrsa build-server-full server nopass
fi

# Generar lista de revocados
if [ ! -f "$PKI_DIR/crl.pem" ]; then
    echo "🚫 Generando CRL..."
    ./easyrsa gen-crl
fi

# Generar clave TLS para tls-crypt
if [ ! -f "$PKI_DIR/ta.key" ]; then
    echo "🔒 Generando clave TLS..."
    openvpn --genkey secret "$PKI_DIR/ta.key"
fi

echo "✅ PKI y certificados listos."
