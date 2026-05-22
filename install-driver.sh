#!/usr/bin/env bash
# install-driver.sh — Instala el driver propietario Broadcom BCM4360
# en Linux Mint 22.x (Ubuntu 24.04 noble) con kernel 6.14.x, sin conexión a Internet.
#
# Uso:
#   sudo ./install-driver.sh                # corre todos los pasos (1→6)
#   sudo ./install-driver.sh -s             # SALTA 1-3 (purga+SB+dpkg), arranca en parches
#   sudo ./install-driver.sh /ruta/debs     # ruta personalizada de .deb
#   sudo ./install-driver.sh -s /ruta/debs  # combina ambos
set -euo pipefail

SKIP_INSTALL=0
ARGS=()
for a in "$@"; do
  case "$a" in
    -s|--skip-install) SKIP_INSTALL=1 ;;
    *) ARGS+=("$a") ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEBS_DIR="${ARGS[0]:-$SCRIPT_DIR/debs}"

# ── Logging: guardar TODO (stdout+stderr) en el USB junto al script ──
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="$LOG_DIR/install-driver_$(date +%Y%m%d-%H%M%S).log"
if ! touch "$LOG_FILE" 2>/dev/null; then
  # USB montado read-only o sin permisos → fallback a /tmp
  LOG_FILE="/tmp/install-driver_$(date +%Y%m%d-%H%M%S).log"
  echo "⚠ No se pudo escribir en USB, log en: $LOG_FILE"
fi
exec > >(tee -a "$LOG_FILE") 2>&1
echo "── Log: $LOG_FILE"
echo "── Fecha: $(date)"
echo "── Host: $(hostname) / $(uname -a)"
echo "── Bash:  $BASH_VERSION"

c_red()   { printf "\033[1;31m%s\033[0m\n" "$*"; }
c_grn()   { printf "\033[1;32m%s\033[0m\n" "$*"; }
c_ylw()   { printf "\033[1;33m%s\033[0m\n" "$*"; }
c_blu()   { printf "\033[1;34m%s\033[0m\n" "$*"; }
hr()      { printf '%.0s─' {1..60}; echo; }

# ── ERR trap: si un comando falla con set -e, DEJAR CONSTANCIA en el log ──
on_error() {
  local rc=$?
  local line=$1
  c_red "════════════════════════════════════════════════════════"
  c_red "✗ ERROR en línea $line — exit code: $rc"
  c_red "  Comando: ${BASH_COMMAND}"
  c_red "════════════════════════════════════════════════════════"
}
trap 'on_error $LINENO' ERR

# Copia logs de DKMS al USB al salir (éxito o error)
copy_dkms_logs() {
  local dst="$LOG_DIR/dkms_$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$dst" 2>/dev/null || return 0
  find /var/lib/dkms -name "make.log" 2>/dev/null | while read -r f; do
    cp "$f" "$dst/$(echo "$f" | tr '/' '_').log" 2>/dev/null || true
  done
  dmesg 2>/dev/null | tail -300 > "$dst/dmesg-tail.log" 2>/dev/null || true
  dkms status > "$dst/dkms-status.log" 2>/dev/null || true
  uname -a > "$dst/uname.log" 2>/dev/null || true
  ls -la /usr/src/ > "$dst/usr-src.log" 2>/dev/null || true
  echo "── Logs DKMS copiados a: $dst"
  sync 2>/dev/null || true   # flush al USB antes de salir
}
trap copy_dkms_logs EXIT

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

if [[ "$SKIP_INSTALL" -eq 1 ]]; then
  c_blu "── Modo --skip-install: saltando pasos 1-3 (purga, secure boot, dpkg) ──"
else
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
  c_ylw "[1/6] Limpiando drivers Broadcom previos…"
  apt purge -y bcmwl-kernel-source broadcom-sta-dkms 2>/dev/null || true
  modprobe -r wl 2>/dev/null || true

  # 2) Verificar Secure Boot — si está activo, advertir
  c_ylw "[2/6] Comprobando Secure Boot…"
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
  c_ylw "[3/6] Instalando paquetes…"
  cd "$DEBS_DIR"
  echo "── dpkg -i ./*.deb (salida completa al log) ──"
  dpkg -i ./*.deb 2>&1 || c_red "  ⚠ dpkg devolvió errores (continúa, apt --fix-broken intentará resolverlos)"
  echo "── apt --fix-broken install (salida completa al log) ──"
  apt --fix-broken install -y --no-download 2>&1 || c_red "  ⚠ apt --fix-broken falló"
fi

# 4) Parchar bcmwl para kernel 6.12+/6.13+/6.14+ (lib80211.h, unaligned, get_tx_power)
PATCH_DIR="$SCRIPT_DIR/patches"
KMAJ="$(echo "$KERNEL" | cut -d. -f1)"
KMIN="$(echo "$KERNEL" | cut -d. -f2)"
needs_patch=0
[[ "$KMAJ" -gt 6 ]] && needs_patch=1
[[ "$KMAJ" -eq 6 && "$KMIN" -ge 12 ]] && needs_patch=1

if [[ "$needs_patch" -eq 1 && -d "$PATCH_DIR" ]]; then
  c_ylw "[4/6] Aplicando parches para kernel $KERNEL…"
  echo "    /usr/src actual:"
  ls -la /usr/src/ 2>&1 || true
  # Buscar fuente bcmwl o broadcom-sta (Ubuntu/Debian usan nombres distintos)
  BCMWL_SRC=""
  shopt -s nullglob
  for d in /usr/src/bcmwl-*/ /usr/src/broadcom-sta-*/; do
    [[ -d "$d" ]] && BCMWL_SRC="${d%/}" && break
  done
  shopt -u nullglob
  if [[ -z "$BCMWL_SRC" ]]; then
    c_red "✗ No se encontró /usr/src/bcmwl-* ni /usr/src/broadcom-sta-*"
    c_red "  bcmwl-kernel-source / broadcom-sta-dkms NO se instaló en paso [3/6]."
    c_red "  Revisa más arriba en este log los errores de dpkg/apt."
    exit 1
  fi
  echo "    Fuente: $BCMWL_SRC"
  pushd "$BCMWL_SRC" >/dev/null
  for p in 30-unalign.patch 31-lib80211.patch 32-prep614.patch; do
    if [[ ! -f "$PATCH_DIR/$p" ]]; then
      echo "    (saltando $p, no existe en USB)"
      continue
    fi
    # Bloque sin set -e para que un parche que no aplica no mate el script
    set +e
    patch -p2 --dry-run --silent < "$PATCH_DIR/$p" >/dev/null 2>&1
    dry_rc=$?
    set -e
    if [[ $dry_rc -eq 0 ]]; then
      set +e
      patch -p2 --silent < "$PATCH_DIR/$p" >/dev/null 2>&1
      rc=$?
      set -e
      if [[ $rc -eq 0 ]]; then
        echo "    ✓ $p"
      else
        c_red "    ✗ $p (dry-run pasó pero aplicación real falló)"
      fi
    else
      echo "    ⏭ $p (ya aplicado o no aplica al árbol actual)"
    fi
  done
  popd >/dev/null
else
  c_ylw "[4/6] Parches: no necesarios para kernel $KERNEL (o sin /patches en USB)"
fi

# 5) Forzar recompilación DKMS contra kernel actual si hace falta
c_ylw "[5/6] Verificando DKMS contra kernel $KERNEL…"
if ! dkms status 2>/dev/null | grep -q "bcmwl.*$KERNEL.*installed"; then
  echo "    Recompilando módulo wl contra kernel $KERNEL…"
  if ! dkms autoinstall -k "$KERNEL"; then
    c_red "✗ DKMS falló al compilar bcmwl contra $KERNEL"
    echo
    echo "── Últimas 40 líneas del make.log más reciente ──"
    LATEST_MAKELOG="$(find /var/lib/dkms/bcmwl -name make.log 2>/dev/null \
      | xargs ls -t 2>/dev/null | head -1)"
    if [[ -n "$LATEST_MAKELOG" ]]; then
      echo "  $LATEST_MAKELOG"
      tail -40 "$LATEST_MAKELOG"
    else
      echo "  (no se encontró make.log)"
    fi
    echo
    c_ylw "Causa típica con kernel 6.14: bcmwl 6.30.223.x necesita parches."
    c_ylw "Verifica que ./debs/ incluya bcmwl con parches para kernel ≥6.14."
    exit 1
  fi
fi

# 6) Cargar el módulo y verificar
c_ylw "[6/6] Cargando módulo wl…"
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
