#!/usr/bin/env bash
set -euo pipefail

# ===== Config =====
CONTAINER="${CONTAINER:-ubuntu-openvpn}"   # nombre del contenedor si se ejecuta en el host
OVPN_DIR="/data/ovpn"
META_DIR="$OVPN_DIR/metadatos"

# ===== Ayuda =====
usage() {
  cat <<USO
Uso:
  $(basename "$0") [opciones] <CN|archivo.ovpn>

Opciones:
  -o, --out RUTA     Guardar el .ovpn en RUTA (descarga/copia)
  -b, --base64       Imprimir el .ovpn en base64 a stdout
  -m, --meta         Mostrar metadata JSON si existe (a stdout)
  -n, --name         Mostrar solo la ruta resuelta del .ovpn dentro del contenedor
  -h, --help         Ayuda

Ejemplos:
  # Mostrar en pantalla
  $(basename "$0") ESTADOS-...-laptop-XXXX

  # Guardar a archivo (desde host o dentro del contenedor)
  $(basename "$0") -o ./perfil.ovpn ESTADOS-...-laptop-XXXX

  # En base64 (ideal para APIs)
  $(basename "$0") --base64 ESTADOS-...-laptop-XXXX

  # Mostrar metadatos
  $(basename "$0") --meta ESTADOS-...-laptop-XXXX
USO
}

# ===== Parseo simple de flags =====
OUT=""
DO_B64=0
DO_META=0
NAME_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--out) OUT="${2:-}"; shift 2 ;;
    -b|--base64) DO_B64=1; shift ;;
    -m|--meta) DO_META=1; shift ;;
    -n|--name) NAME_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*)
      echo "Opción desconocida: $1" >&2
      usage; exit 1 ;;
    *)
      ARG="${1:-}"; shift ;;
  esac
done

[ "${ARG:-}" ] || { echo "❌ Falta <CN|archivo.ovpn>"; usage; exit 1; }

# ===== Detección: ¿estamos dentro del contenedor? =====
in_container=0
if [ -d "$OVPN_DIR" ] && [ -d "$META_DIR" ]; then
  in_container=1
fi

# ===== Función de resolución (modo contenedor) =====
resolve_inside() {
  local arg="$1"
  local f="" j="" base=""

  if [[ "$arg" == *.ovpn ]]; then
    f="$OVPN_DIR/$(basename "$arg")"
    if [ -f "$f" ]; then
      echo "$f"
      return 0
    fi
    echo "❌ No existe: $f" >&2
    return 1
  fi

  # Buscar por metadata (campo "cn")
  j="$(grep -sl "\"cn\"[[:space:]]*:[[:space:]]*\"$arg\"" "$META_DIR"/*.json 2>/dev/null | head -1 || true)"
  if [ -n "$j" ]; then
    f="$(awk -F\" '/"ovpn_file"[[:space:]]*:/ {print $4; exit}' "$j")"
    if [ -n "$f" ] && [ -f "$f" ]; then
      echo "$f"
      return 0
    fi
  fi

  # Fallback: CN saneado -> nombre de archivo
  base="$(printf '%s' "$arg" | sed 's/[^A-Za-z0-9._-]/_/g').ovpn"
  f="$OVPN_DIR/$base"
  if [ -f "$f" ]; then
    echo "$f"
    return 0
  fi

  echo "❌ No se pudo resolver .ovpn para: $arg" >&2
  return 1
}

# ===== Mostrar metadata (modo contenedor) =====
show_meta_inside() {
  local arg="$1"
  local j=""
  if [[ "$arg" == *.ovpn ]]; then
    # buscar metadata por nombre de archivo
    local base="$(basename "$arg" .ovpn)"
    j="$META_DIR/${base}.json"
    [ -f "$j" ] && { cat "$j"; return 0; }
  fi
  # buscar por CN
  j="$(grep -sl "\"cn\"[[:space:]]*:[[:space:]]*\"$arg\"" "$META_DIR"/*.json 2>/dev/null | head -1 || true)"
  [ -n "$j" ] && [ -f "$j" ] && { cat "$j"; return 0; }
  return 1
}

# ===== Lógica según contexto =====
if [ $in_container -eq 1 ]; then
  # ---- MODO CONTENEDOR ----
  OVPN_PATH="$(resolve_inside "$ARG")" || exit 1
  [ $NAME_ONLY -eq 1 ] && { echo "$OVPN_PATH"; exit 0; }

  # Metadata (si pidieron)
  if [ $DO_META -eq 1 ]; then
    if ! show_meta_inside "$ARG"; then
      echo "⚠️ Sin metadata para $ARG" >&2
    fi
  fi

  if [ $DO_B64 -eq 1 ]; then
    base64 -w0 "$OVPN_PATH"
    echo
    exit 0
  fi

  if [ -n "$OUT" ]; then
    mkdir -p "$(dirname "$OUT")"
    cp -f "$OVPN_PATH" "$OUT"
    echo "✅ Guardado en: $OUT"
    exit 0
  fi

  # Por defecto: mostrar en stdout
  cat "$OVPN_PATH"
  exit 0

else
  # ---- MODO HOST ----
  # 1) resolver ruta real dentro del contenedor
  RESOLVER=$'set -euo pipefail\n'"$(declare -f resolve_inside)"$'\nresolve_inside "$1"\n'
  OVPN_PATH="$(docker exec -i "$CONTAINER" bash -lc "$RESOLVER" _ "$ARG" 2>/dev/null | tail -n1 || true)"
  [ -n "$OVPN_PATH" ] || { echo "❌ No se pudo resolver el .ovpn en el contenedor $CONTAINER" >&2; exit 1; }

  [ $NAME_ONLY -eq 1 ] && { echo "$OVPN_PATH"; exit 0; }

  # Metadata si piden
  if [ $DO_META -eq 1 ]; then
    docker exec -i "$CONTAINER" bash -lc '
      OVPN_DIR="/data/ovpn"; META_DIR="/data/ovpn/metadatos"; ARG='"'"$ARG"'"';
      if [[ "$ARG" == *.ovpn ]]; then
        base="$(basename "$ARG" .ovpn)"; j="$META_DIR/${base}.json";
        [ -f "$j" ] && { cat "$j"; exit 0; }
      fi
      j="$(grep -sl "\"cn\"[[:space:]]*:[[:space:]]*\"$ARG\"" "$META_DIR"/*.json 2>/dev/null | head -1 || true)"
      [ -n "$j" ] && [ -f "$j" ] && { cat "$j"; exit 0; }
      exit 0
    ' || true
  fi

  if [ $DO_B64 -eq 1 ]; then
    docker exec -i "$CONTAINER" bash -lc "base64 -w0 '$OVPN_PATH'"
    echo
    exit 0
  fi

  if [ -n "$OUT" ]; then
    mkdir -p "$(dirname "$OUT")"
    docker cp "${CONTAINER}:${OVPN_PATH}" "$OUT"
    echo "✅ Copiado a: $OUT"
    exit 0
  fi

  # Por defecto: mostrar en stdout
  docker exec -i "$CONTAINER" bash -lc "cat '$OVPN_PATH'"
  exit 0
fi


# Ejemplos rápidos
# 1) Ver el .ovpn por pantalla
# # Usando CN
# ./mostrar_ovpn.sh estados-unidos-lenovo-laptop-YYYYMMDDHHMMSS

# # Usando el nombre de archivo
# ./mostrar_ovpn.sh ESTADOS-UNIDOS-lenovo-laptop-YYYY.ovpn

# 2) Guardarlo en un archivo local (descargar)
# # Desde el host (hace docker cp por ti)
# ./mostrar_ovpn.sh -o ./perfil.ovpn estados-unidos-lenovo-laptop-YYYY

# # Dentro del contenedor (copia directa)
# ./mostrar_ovpn.sh -o /root/perfil.ovpn ESTADOS-...-YYYY.ovpn

# 3) Obtenerlo en base64 (para APIs)
# ./mostrar_ovpn.sh --base64 estados-unidos-lenovo-laptop-YYYY > perfil.ovpn.b64

# 4) Ver metadatos JSON
# ./mostrar_ovpn.sh --meta estados-unidos-lenovo-laptop-YYYY

# 5) Solo la ruta real en el contenedor
# ./mostrar_ovpn.sh --name estados-unidos-lenovo-laptop-YYYY
# # -> /data/ovpn/ESTADOS-UNIDOS-lenovo-laptop-YYYY.ovpn

# 6) Cambiar el nombre del contenedor (desde el host)
# CONTAINER=mi-openvpn ./mostrar_ovpn.sh -o ./perfil.ovpn estados-unidos-...
