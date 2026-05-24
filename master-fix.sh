#!/usr/bin/env bash
# master-fix.sh — Lleva el audio a funcionar fin-a-fin SIN intervención manual.
#
# Detecta en qué kernel estás y ejecuta la fase correspondiente:
#   FASE A (kernel 6.14): fuerza boot a kernel 6.8 via grub-reboot + reboot.
#   FASE B (kernel 6.8 ): repara bcmwl, conecta a internet si hace falta,
#                          reinstala lo que falte, deja 6.8 permanente,
#                          verifica audio + WiFi.
#
# Uso: sudo ./master-fix.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="$LOG_DIR/master-fix_$(date +%Y%m%d-%H%M%S).log"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/master-fix_$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

c_red()  { printf "\033[1;31m%s\033[0m\n" "$*"; }
c_grn()  { printf "\033[1;32m%s\033[0m\n" "$*"; }
c_ylw()  { printf "\033[1;33m%s\033[0m\n" "$*"; }
c_blu()  { printf "\033[1;34m%s\033[0m\n" "$*"; }
hr()     { printf '%.0s─' {1..60}; echo; }

if [[ $EUID -ne 0 ]]; then c_red "Ejecuta con sudo."; exit 1; fi

KERNEL="$(uname -r)"
GRUB_FILE="/etc/default/grub"

c_blu "═══ MASTER FIX (audio + WiFi end-to-end) ═══"
echo "── Log: $LOG_FILE"
echo "── Kernel actual: $KERNEL"
hr

has_internet() {
  ping -c1 -W 2 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W 2 8.8.8.8 >/dev/null 2>&1
}

wait_for_internet() {
  local max_wait=600  # 10 minutos
  local elapsed=0
  while ! has_internet; do
    if (( elapsed % 30 == 0 )); then
      c_ylw "    Esperando internet… conecta cable ethernet o USB tether"
      c_ylw "    (probaré cada 5 seg, máximo 10 minutos)"
    fi
    sleep 5
    elapsed=$((elapsed + 5))
    [[ $elapsed -ge $max_wait ]] && return 1
  done
  c_grn "    ✓ Internet conectado"
}

find_grub_entry_for_kernel() {
  local kver_pattern="$1"
  awk -v pat="$kver_pattern" -F"'" '
    /^submenu/ { sub_id=$2 }
    /^[[:space:]]+menuentry/ && $0 ~ pat && sub_id { print sub_id ">" $2; exit }
    /^menuentry/ && $0 ~ pat && !sub_id { print $2; exit }
  ' /boot/grub/grub.cfg
}

# ════════════════════════════════════════════════════════════════════
# FASE A: estás en 6.14 → forzar boot a 6.8
# ════════════════════════════════════════════════════════════════════
if [[ "$KERNEL" == 6.14.* ]]; then
  c_ylw "FASE A: en kernel 6.14, voy a forzar boot a kernel 6.8"

  # 1. ¿Está instalado el kernel 6.8?
  K68="$(ls /boot/vmlinuz-6.8.* 2>/dev/null | sed 's|/boot/vmlinuz-||' | sort -V | tail -1)"
  if [[ -z "$K68" ]]; then
    c_red "  ✗ No hay kernel 6.8 instalado en /boot."
    c_red "    Corre: sudo $SCRIPT_DIR/audio-autofix.sh --strategy=S6"
    c_red "    para instalarlo desde $SCRIPT_DIR/kernel-6.8/"
    exit 1
  fi
  c_grn "  ✓ Kernel 6.8 encontrado: $K68"

  # 2. Buscar la entrada de menú GRUB
  ENTRY="$(find_grub_entry_for_kernel "$K68")"
  if [[ -z "$ENTRY" ]]; then
    c_red "  ✗ No se encontró entrada GRUB para $K68"
    c_red "    Genera el menu con: sudo update-grub"
    c_red "    Luego revisa: grep menuentry /boot/grub/grub.cfg"
    exit 1
  fi
  echo "  Entrada GRUB detectada: $ENTRY"

  # 3. Limpiar GRUB cmdline de params 6.14-específicos
  cp "$GRUB_FILE" "${GRUB_FILE}.bak.$(date +%s)"
  current="$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" "$GRUB_FILE" | head -1 | sed -E 's/^[^"]*"(.*)"$/\1/')"
  cleaned="$(echo "$current" | sed -E 's/snd_hda_intel\.[a-z_]+=[^ ]+//g; s/snd-intel-dspcfg\.[a-z_]+=[^ ]+//g; s/  +/ /g; s/^ //; s/ $//')"
  sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$cleaned\"|" "$GRUB_FILE"
  update-grub 2>&1 | tail -3 || true

  # 4. grub-reboot: boot 6.8 SOLO la próxima vez (no cambia default permanente todavía)
  c_ylw "  Configurando grub-reboot para que próximo boot use kernel 6.8…"
  if grub-reboot "$ENTRY" 2>&1; then
    c_grn "  ✓ grub-reboot OK"
  else
    c_red "  ✗ grub-reboot falló. Intentando set permanente."
    sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"$ENTRY\"|" "$GRUB_FILE"
    update-grub 2>&1 | tail -3 || true
  fi

  hr
  c_grn "✓ Listo para reiniciar a kernel 6.8"
  c_ylw "  El audio DEBERÍA funcionar en 6.8 (regresión confirmada en 6.11+)."
  c_ylw "  El WiFi probablemente NO al toque (bcmwl falló al compilar para 6.8)."
  c_ylw "  Si necesitas WiFi: conecta cable Ethernet o USB tether ANTES de bootear."
  c_ylw "  Tras el reboot, vuelve a correr este script para que la FASE B repare WiFi."
  echo
  c_blu "  Reiniciando en 5 segundos… (Ctrl+C para cancelar)"
  sleep 5
  reboot
fi

# ════════════════════════════════════════════════════════════════════
# FASE B: estás en 6.8 → reparar bcmwl + WiFi, verificar audio
# ════════════════════════════════════════════════════════════════════
if [[ "$KERNEL" == 6.8.* ]]; then
  c_ylw "FASE B: en kernel $KERNEL — reparando bcmwl y verificando audio"

  # 1. Hacer permanente el default a 6.8 (ya estamos acá, fijémoslo)
  ENTRY="$(find_grub_entry_for_kernel "$KERNEL")"
  if [[ -n "$ENTRY" ]]; then
    sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"$ENTRY\"|" "$GRUB_FILE"
    update-grub 2>&1 | tail -3 || true
    c_grn "  ✓ GRUB_DEFAULT permanente = $ENTRY"
  fi

  # 2. ¿WiFi funciona?
  if ip link | grep -qE "wl(p|an)"; then
    c_grn "  ✓ Interfaz WiFi ya presente (bcmwl OK en este kernel)"
  else
    c_ylw "  ⚠ No hay interfaz WiFi. Intentando reparar bcmwl…"

    # Forzar recompilación DKMS para este kernel
    c_ylw "  Recompilando bcmwl via DKMS para $KERNEL…"
    dkms autoinstall -k "$KERNEL" 2>&1 | tail -10 || true

    # Si DKMS falla y tenemos los .deb en USB, reinstalar bcmwl-kernel-source
    if ! ip link | grep -qE "wl(p|an)"; then
      c_ylw "  DKMS no levantó interfaz. Intentando reinstalar paquetes…"
      if [[ -d "$SCRIPT_DIR/debs" ]]; then
        cd "$SCRIPT_DIR/debs"
        dpkg -i bcmwl-kernel-source*.deb broadcom-sta-dkms*.deb 2>&1 | tail -10 || true
        apt --fix-broken install -y --no-download 2>&1 | tail -10 || true
        dkms autoinstall -k "$KERNEL" 2>&1 | tail -10 || true
        cd - >/dev/null
      fi
    fi

    # Cargar módulo wl
    modprobe -r b43 brcmfmac brcmsmac bcma ssb 2>/dev/null || true
    modprobe wl 2>&1 || c_red "  ⚠ modprobe wl falló"
    sleep 2

    if ip link | grep -qE "wl(p|an)"; then
      c_grn "  ✓ WiFi reparado tras reinstalar bcmwl"
    else
      c_red "  ✗ WiFi no levantó. Necesitas internet por cable/tether."
      c_ylw "  Esperando conexión a internet por otra interfaz…"
      if wait_for_internet; then
        c_grn "  ✓ Internet activo (probablemente ethernet o tether)"
        # Con internet, instalar build deps y forzar dkms rebuild
        apt update 2>&1 | tail -3 || true
        apt install -y --no-install-recommends linux-headers-"$KERNEL" \
                    dkms build-essential bcmwl-kernel-source 2>&1 | tail -10 || true
        dkms autoinstall -k "$KERNEL" 2>&1 | tail -10 || true
        modprobe wl 2>&1 || true
      else
        c_red "  ✗ Sin internet después de 10 min. Saltando reparación de WiFi."
      fi
    fi
  fi

  # 3. ¿Audio funciona?
  hr
  c_ylw "  Verificando audio en kernel 6.8…"
  echo "── aplay -l ──"
  aplay -l 2>&1 || echo "(aplay no instalado)"
  echo "── /proc/asound/cards ──"
  cat /proc/asound/cards 2>&1
  echo "── dmesg audio ──"
  dmesg | grep -iE "snd_hda|codec|cirrus" | tail -15

  if aplay -l 2>/dev/null | grep -qiE "card .*device .*\[(Analog|Speaker|Headphone|PCM)"; then
    hr
    c_grn "✓✓✓ AUDIO FUNCIONA EN KERNEL 6.8 ✓✓✓"
    c_grn "    Prueba: speaker-test -c2 -t wav -l1"
    c_grn "    El GRUB_DEFAULT ya quedó en 6.8 permanente."
  elif dmesg | grep -q "azx_get_response timeout"; then
    c_red "✗ Codec sigue sin responder EN KERNEL 6.8."
    c_red "  Esto descarta la teoría de regresión de kernel."
    c_red "  Único camino restante: COLD BOOT COMPLETO."
    echo
    c_blu "  Procedimiento exacto:"
    echo "    1. sudo shutdown -h now"
    echo "    2. Desconecta el cargador"
    echo "    3. Espera 30 segundos completos"
    echo "    4. Mantén power 10 segundos para drenar capacitores"
    echo "    5. Conecta cargador + enciende"
    echo "    6. Vuelve a correr: sudo $0"
  else
    c_ylw "⚠ Audio no detecta dispositivos pero tampoco hay timeout."
    c_ylw "  Puede ser config de PipeWire/Pulse o quirk de modelo."
    c_ylw "  Revisa: amixer y pavucontrol"
  fi
  hr
  sync 2>/dev/null || true
  exit 0
fi

c_red "Kernel inesperado: $KERNEL"
c_red "Este script soporta solo 6.14.x o 6.8.x"
exit 1
