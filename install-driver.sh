#!/usr/bin/env bash
# install-driver.sh — Instala el driver propietario Broadcom BCM4360
# en Linux Mint 22.x (Ubuntu 24.04 noble) con kernel 6.14.x, sin conexión a Internet.
#
# Uso:
#   sudo ./install-driver.sh           # busca .deb en ./debs/ junto al script
#   sudo ./install-driver.sh /ruta/debs # ruta personalizada
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEBS_DIR="${1:-$SCRIPT_DIR/debs}"

c_red()   { printf "\033[1;31m%s\033[0m\n" "$*"; }
c_grn()   { printf "\033[1;32m%s\033[0m\n" "$*"; }
c_ylw()   { printf "\033[1;33m%s\033[0m\n" "$*"; }
c_blu()   { printf "\033[1;34m%s\033[0m\n" "$*"; }
hr()      { printf '%.0s─' {1..60}; echo; }

if [[ $EUID -ne 0 ]]; then
  c_red "Este script debe ejecutarse con sudo."
  exit 1
fi

c_blu "═══ Instalador driver Broadcom BCM4360 (offline) ═══"
hr
echo "Carpeta de paquetes: $DEBS_DIR"
KERNEL="$(uname -r)"
echo "Kernel actual:       $KERNEL"
hr

if [[ ! -d "$DEBS_DIR" ]]; then
  c_red "No existe la carpeta $DEBS_DIR"
  exit 1
fi

DEB_COUNT=$(find "$DEBS_DIR" -maxdepth 1 -name "*.deb" | wc -l)
if [[ "$DEB_COUNT" -lt 30 ]]; then
  c_red "Solo se encontraron $DEB_COUNT .deb (esperado ~68). ¿Carpeta correcta?"
  exit 1
fi
c_grn "Encontrados $DEB_COUNT paquetes .deb"

# 1) Detectar y purgar drivers Broadcom previos que puedan interferir
c_ylw "[1/5] Limpiando drivers Broadcom previos…"
apt purge -y bcmwl-kernel-source broadcom-sta-dkms 2>/dev/null || true
modprobe -r wl 2>/dev/null || true

# 2) Verificar Secure Boot — si está activo, advertir
c_ylw "[2/5] Comprobando Secure Boot…"
if command -v mokutil >/dev/null 2>&1; then
  SB_STATE="$(mokutil --sb-state 2>/dev/null || echo unknown)"
  echo "    $SB_STATE"
  if echo "$SB_STATE" | grep -qi "enabled"; then
    c_red "⚠ Secure Boot está habilitado. El módulo 'wl' no firmado NO cargará."
    c_red "  Desactívalo desde la BIOS/EFI antes de continuar, o firma el módulo manualmente."
    read -rp "¿Continuar de todas formas? [y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]] || exit 1
  fi
else
  echo "    mokutil no disponible — saltando comprobación"
fi

# 3) Instalar todos los .deb (orden no importa, dpkg resuelve)
c_ylw "[3/5] Instalando paquetes…"
cd "$DEBS_DIR"
dpkg -i ./*.deb 2>&1 | tail -20 || true
apt --fix-broken install -y --no-download 2>&1 | tail -10 || true

# 4) Forzar recompilación DKMS contra kernel actual si hace falta
c_ylw "[4/5] Verificando DKMS contra kernel $KERNEL…"
if ! dkms status 2>/dev/null | grep -q "bcmwl.*$KERNEL.*installed"; then
  echo "    Recompilando módulo wl…"
  dkms autoinstall -k "$KERNEL" || {
    c_red "DKMS falló. Revisa /var/lib/dkms/bcmwl/*/build/make.log"
    exit 1
  }
fi

# 5) Cargar el módulo y verificar
c_ylw "[5/5] Cargando módulo wl…"
modprobe -r b43 ssb brcmfmac brcmsmac bcma 2>/dev/null || true
if modprobe wl; then
  c_grn "✓ Módulo wl cargado"
else
  c_red "✗ No se pudo cargar wl"
  exit 1
fi

hr
sleep 2
if ip link | grep -qE "wl(p|an)"; then
  c_grn "✓ Interfaz WiFi detectada:"
  ip -br link | grep -E "wl(p|an)" || true
  echo
  c_grn "Ya puedes conectarte a una red desde el panel de red."
else
  c_red "✗ No se detectó interfaz wl*. Revisa: dmesg | grep -i wl"
fi
hr
