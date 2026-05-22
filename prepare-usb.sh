#!/usr/bin/env bash
# prepare-usb.sh — Descarga todos los .deb necesarios para instalar el driver
# Broadcom BCM4360 en Linux Mint 22.x (Ubuntu 24.04 noble) con kernel 6.14.x,
# y los copia al USB junto con los scripts del toolkit.
#
# Uso:
#   ./prepare-usb.sh /Volumes/TU_USB         (macOS)
#   ./prepare-usb.sh /media/$USER/TU_USB     (Linux)
#
# Requiere Docker.
set -euo pipefail

DEST="${1:-}"
if [[ -z "$DEST" ]]; then
  echo "Uso: $0 <ruta_montaje_usb>"
  echo "Ej:  $0 /Volumes/BCM4360"
  exit 1
fi

if [[ ! -d "$DEST" ]]; then
  echo "Error: no existe $DEST"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Error: Docker no está instalado o no está en PATH"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "═══ Preparando USB para BCM4360 + Mint 22.x ═══"
echo "Destino: $DEST"
echo "Trabajo: $WORK"
echo

# 1. Descargar paquetes con Docker
echo "[1/3] Descargando .deb (~100 MB, puede tardar)…"
docker run --rm --platform linux/amd64 -v "$WORK:/work" ubuntu:24.04 bash -c '
  set -e
  apt-get update -qq
  apt-get install -y --download-only --no-install-recommends \
    bcmwl-kernel-source dkms build-essential gcc make patch \
    linux-headers-6.14.0-37-generic linux-hwe-6.14-headers-6.14.0-37 \
    linux-libc-dev libc6-dev fakeroot 2>&1 | tail -5
  mkdir -p /work/debs
  cp /var/cache/apt/archives/*.deb /work/debs/
  ls /work/debs/*.deb | wc -l
'

# 2. Extraer del volumen Docker al USB (vía tar pipe, evita problemas de bind mount)
echo "[2/3] Copiando .deb al USB…"
mkdir -p "$DEST/debs"
docker run --rm --platform linux/amd64 -v "$WORK:/src" ubuntu:24.04 \
  tar -cf - -C /src/debs . | tar -xf - -C "$DEST/debs"

# 3. Copiar scripts y README al USB
echo "[3/3] Copiando scripts y README al USB…"
cp "$SCRIPT_DIR/install-driver.sh"   "$DEST/"
cp "$SCRIPT_DIR/optimize-system.sh"  "$DEST/"
cp "$SCRIPT_DIR/README.md"           "$DEST/"
chmod +x "$DEST/install-driver.sh" "$DEST/optimize-system.sh"

echo
echo "✓ USB listo en $DEST"
echo
echo "Contenido:"
ls -la "$DEST" | grep -v "^total\|\.Spot\|\.fseven\|\.Trash\|^d.*\\.$"
echo
echo "En la MacBook Air:"
echo "    cd /media/\$USER/$(basename "$DEST")"
echo "    sudo ./install-driver.sh"
echo "    sudo ./optimize-system.sh"
echo "    sudo reboot"
