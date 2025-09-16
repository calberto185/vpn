# 🔐 Servidor OpenVPN con Gestión Automatizada vía Scripts

Este proyecto monta un servidor OpenVPN basado en Ubuntu y facilita la gestión completa de certificados y usuarios desde un sistema externo (como backend en Node.js) mediante scripts Bash accesibles en el contenedor.

---

## 📦 Estructura del Proyecto

```
.
├── Dockerfile
├── docker-compose.yml
├── scripts/                  # Scripts de gestión
├── data/                     # Contiene certificados, archivos .ovpn y .zip
│   └── ovpn/                 # Archivos generados para clientes
├── logs/openvpn/            # Logs del servicio OpenVPN
```

---

## 🚀 Cómo levantar el servicio

1. Construir e iniciar:

```bash
docker-compose up -d --build
```

2. Ver logs del contenedor:

```bash
docker logs -f ubuntu-openvpn
```

---

## ⚙️ Scripts disponibles (`/scripts/*.sh`)

Todos los scripts pueden ejecutarse desde el backend con:

```bash
docker exec ubuntu-openvpn /scripts/<script>.sh [argumento]
```

---

## 📄 Detalle de cada script

| Script | Descripción |
|--------|-------------|

### Certificados y usuarios

#### `crear_usuario.sh <usuario>`
Crea un nuevo certificado de cliente y su archivo `.ovpn`. Guarda el archivo en `/data/ovpn`.

#### `descargar_ovpn.sh <usuario>`
Devuelve el contenido del archivo `.ovpn` generado para ese usuario (usado para descargarlo desde el backend).

#### `generar_zip_usuario.sh <usuario>`
Empaqueta el archivo `.ovpn` y un archivo README.txt en un `.zip`, ideal para entrega a usuarios finales.

#### `listar_certificados.sh`
Lista todos los certificados emitidos por Easy-RSA.

#### `ver_estado_usuario.sh <usuario>`
Muestra si un usuario está **ACTIVO**, **SUSPENDIDO** o **REVOCADO**, basado en la CRL y la lista de suspensión.

#### `ver_detalle_certificado.sh <usuario>`
Muestra el contenido completo (x509) del certificado emitido.

#### `revocar_usuario.sh <usuario>`
Revoca el certificado de un usuario y actualiza la CRL.

#### `eliminar_usuario.sh <usuario>`
Borra archivos relacionados a un usuario ya revocado (certificados, claves, .ovpn y .zip).

#### `obtener_crl.sh`
Devuelve el archivo CRL actual (`crl.pem`) para verificar revocaciones manualmente.

---

### Conexiones y monitoreo

#### `listar_conectados.sh`
Lista todos los usuarios conectados actualmente usando la Management Interface de OpenVPN.

#### `desconectar_usuario.sh <usuario>`
Desconecta a un cliente específico del servidor si está conectado.

#### `monitorear_conexiones.sh [segundos]`
Muestra las conexiones activas en tiempo real cada X segundos. Por defecto cada 5 segundos.

#### `leer_logs.sh`
Imprime las últimas 50 líneas del log del servidor OpenVPN (`/var/log/openvpn/openvpn.log`).

#### `suspender_usuario.sh <usuario>`
Agrega al usuario a una lista de "suspendidos". No revoca su certificado.

#### `reactivar_usuario.sh <usuario>`
Elimina al usuario de la lista de suspendidos.

#### `buscar_usuario.sh <usuario>`
Busca al usuario y muestra si está emitido, revocado, suspendido o conectado actualmente.

---

## 🧩 Integración desde backend (Node.js)

Ejemplo con `child_process` para crear un usuario:

```js
const { exec } = require("child_process");

exec("docker exec ubuntu-openvpn /scripts/crear_usuario.sh juanito", (err, stdout, stderr) => {
  if (err) return console.error("Error:", stderr);
  console.log(stdout);
});
```

Para descargar el `.ovpn`:

```js
exec("docker exec ubuntu-openvpn /scripts/descargar_ovpn.sh juanito", (err, stdout) => {
  fs.writeFileSync("juanito.ovpn", stdout);
});
```

---

## ✅ Requisitos

- Docker y Docker Compose
- Linux con acceso a puertos UDP
- Cliente OpenVPN para probar conexiones

---

## 📌 Notas

- Todos los certificados se generan con `nopass` por simplicidad.
- Asegúrate de que el servidor OpenVPN tenga habilitado `management localhost 7505`.
- Puedes montar volúmenes persistentes para respaldo externo si lo deseas.

---

## 🧑‍💻 Autor

Carlos — Proyecto personalizado para gestión segura de VPNs desde interfaz web.

docker logs mongo1 --tail=50