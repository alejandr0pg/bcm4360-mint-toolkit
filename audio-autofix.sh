#!/usr/bin/env bash
# audio-autofix.sh — Fix iterativo automático para "Dummy Output" en MacBook
# en Linux Mint 22 / Ubuntu 24.04 con kernel 6.14.x.
#
# Cómo funciona:
#   1. Detecta si el audio YA funciona (aplay -l muestra un device no-HDMI). Si sí, sale.
#   2. Si no, lee el archivo de estado en USB para saber qué se probó.
#   3. Aplica la siguiente estrategia (quirk + GRUB params), actualiza initramfs/grub.
#   4. Te dice que reinicies. Vuelves a correr el script.
#   5. Se repite hasta que el audio funcione o se agoten estrategias.
#
# Uso: sudo ./audio-autofix.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="$LOG_DIR/audio-autofix_$(date +%Y%m%d-%H%M%S).log"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/audio-autofix_$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

c_red()  { printf "\033[1;31m%s\033[0m\n" "$*"; }
c_grn()  { printf "\033[1;32m%s\033[0m\n" "$*"; }
c_ylw()  { printf "\033[1;33m%s\033[0m\n" "$*"; }
c_blu()  { printf "\033[1;34m%s\033[0m\n" "$*"; }
hr()     { printf '%.0s─' {1..60}; echo; }

if [[ $EUID -ne 0 ]]; then c_red "Ejecuta con sudo."; exit 1; fi

STATE_FILE="$SCRIPT_DIR/.audio-autofix-state"
MODPROBE_CONF="/etc/modprobe.d/macbook-audio.conf"
GRUB_FILE="/etc/default/grub"

c_blu "═══ Audio Auto-fix iterativo ═══"
echo "── Log: $LOG_FILE"
echo "── Fecha: $(date)"
hr

# ─── 1) ¿El audio ya funciona? ─────────────────────────────────────
check_audio_works() {
  # Busca al menos UN dispositivo de playback no-HDMI
  if aplay -l 2>/dev/null | grep -qiE "card .*device .*\[(Analog|Speaker|Headphone|PCM)"; then
    return 0
  fi
  # Otro check: hay sink no-dummy en PipeWire/Pulse
  if [[ -n "${SUDO_USER:-}" ]]; then
    if sudo -u "$SUDO_USER" pactl list short sinks 2>/dev/null | grep -vqi "auto_null\|dummy"; then
      sudo -u "$SUDO_USER" pactl list short sinks 2>/dev/null | grep -vi "auto_null\|dummy" | grep -q . && return 0
    fi
  fi
  return 1
}

c_ylw "[1/5] Verificando estado actual del audio…"
echo "── aplay -l ──"
aplay -l 2>&1 || true
echo "── /proc/asound/cards ──"
cat /proc/asound/cards 2>&1 || true
if [[ -n "${SUDO_USER:-}" ]]; then
  echo "── pactl list short sinks (usuario $SUDO_USER) ──"
  sudo -u "$SUDO_USER" pactl list short sinks 2>&1 || true
fi

if check_audio_works; then
  hr
  c_grn "✓ El audio YA funciona (hay un sink/device no-dummy)."
  c_grn "  Si igual no escuchas: prueba 'speaker-test -c2 -t wav' o sube volumen en alsamixer."
  exit 0
fi

c_red "✗ Audio aún en estado Dummy Output. Aplicando siguiente estrategia…"

# ─── 2) Leer estado para saber qué se probó ────────────────────────
TRIED=""
[[ -f "$STATE_FILE" ]] && TRIED="$(cat "$STATE_FILE")"
echo "── Estrategias probadas hasta ahora: ${TRIED:-(ninguna registrada)}"

# Si NO hay state file pero ya existe /etc/modprobe.d/macbook-audio.conf con mba6,
# eso lo creó setup-audio-browser.sh → contar como S1 ya probado.
if [[ -z "$TRIED" ]] && [[ -f "$MODPROBE_CONF" ]] && grep -q "model=mba6" "$MODPROBE_CONF"; then
  TRIED="S1"
  echo "── Detectado mba6 previo (setup-audio-browser.sh). Marcando S1 como probado."
fi

# ─── 3) Elegir próxima estrategia ─────────────────────────────────
NEXT=""
case "$TRIED" in
  "")    NEXT="S1" ;;
  *S1*)  echo "$TRIED" | grep -q S2 || NEXT="S2"
         echo "$TRIED" | grep -q S2 && echo "$TRIED" | grep -q S3 || NEXT="S3"
         echo "$TRIED" | grep -q S3 && echo "$TRIED" | grep -q S4 || NEXT="S4"
         echo "$TRIED" | grep -q S4 && NEXT="EXHAUSTED" ;;
esac

# Lógica más simple:
if   ! echo "$TRIED" | grep -q S1; then NEXT="S1"
elif ! echo "$TRIED" | grep -q S2; then NEXT="S2"
elif ! echo "$TRIED" | grep -q S3; then NEXT="S3"
elif ! echo "$TRIED" | grep -q S4; then NEXT="S4"
else NEXT="EXHAUSTED"; fi

c_blu "── Próxima estrategia: $NEXT"

apply_modprobe() {
  local opts="$1"
  cat > "$MODPROBE_CONF" <<EOF
# Generado por audio-autofix.sh ($(date))
options snd-hda-intel $opts
EOF
  echo "    ✓ Escrito $MODPROBE_CONF: $opts"
}

apply_grub_cmdline() {
  local extra="$1"
  cp "$GRUB_FILE" "${GRUB_FILE}.bak.$(date +%s)"
  local current
  current="$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" "$GRUB_FILE" | head -1 | sed -E 's/^[^"]*"(.*)"$/\1/')"
  # Quitar params previos snd_hda_intel.* si existen
  current="$(echo "$current" | sed -E 's/snd_hda_intel\.[a-z_]+=[^ ]+//g; s/  +/ /g; s/^ //; s/ $//')"
  local newline="GRUB_CMDLINE_LINUX_DEFAULT=\"$current $extra\""
  newline="$(echo "$newline" | sed -E 's/  +/ /g')"
  sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|$newline|" "$GRUB_FILE"
  echo "    ✓ GRUB cmdline → $newline"
  update-grub 2>&1 | tail -3 || true
}

clear_grub_cmdline() {
  cp "$GRUB_FILE" "${GRUB_FILE}.bak.$(date +%s)"
  local current
  current="$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" "$GRUB_FILE" | head -1 | sed -E 's/^[^"]*"(.*)"$/\1/')"
  current="$(echo "$current" | sed -E 's/snd_hda_intel\.[a-z_]+=[^ ]+//g; s/  +/ /g; s/^ //; s/ $//')"
  sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$current\"|" "$GRUB_FILE"
  update-grub 2>&1 | tail -3 || true
}

c_ylw "[2/5] Aplicando estrategia $NEXT…"
case "$NEXT" in
  S1)
    # Quirk mba6 simple (lo que ya intentamos en setup-audio-browser.sh)
    apply_modprobe "model=mba6 power_save=0 power_save_controller=N"
    clear_grub_cmdline
    ;;
  S2)
    # Quirk mbp101 + GRUB params dmic_detect=0
    apply_modprobe "model=mbp101 power_save=0 power_save_controller=N dmic_detect=0"
    apply_grub_cmdline "snd_hda_intel.dmic_detect=0 snd_hda_intel.power_save=0"
    ;;
  S3)
    # Sin quirk + probe_mask + dmic_detect (más agresivo, deja al kernel detectar)
    apply_modprobe "model=auto probe_mask=0xffff dmic_detect=0 power_save=0"
    apply_grub_cmdline "snd_hda_intel.dmic_detect=0 snd_hda_intel.power_save=0 snd_hda_intel.probe_mask=0xffff"
    ;;
  S4)
    # Forzar reload de codec Cirrus + index=0 para tomar prioridad sobre HDMI
    apply_modprobe "model=auto index=0 power_save=0 probe_mask=0xffff dmic_detect=0"
    apply_grub_cmdline "snd_hda_intel.dmic_detect=0 snd_hda_intel.power_save=0 snd_hda_intel.probe_mask=0xffff snd_hda_intel.index=0"
    # Forzar carga al inicio
    grep -qx "snd-hda-intel" /etc/modules || echo "snd-hda-intel" >> /etc/modules
    ;;
  EXHAUSTED)
    hr
    c_red "✗ Se agotaron las 4 estrategias. Quirks probados:"
    echo "  • S1: model=mba6"
    echo "  • S2: model=mbp101 + dmic_detect=0"
    echo "  • S3: model=auto + probe_mask=0xffff + dmic_detect=0"
    echo "  • S4: + index=0 + carga forzada al boot"
    c_red "Próximo paso requiere análisis manual del dump:"
    c_red "  sudo $SCRIPT_DIR/diagnose-audio.sh"
    c_red "Trae el tar.gz para investigar (codec dumps, dmesg completo)."
    echo
    echo "Para resetear y empezar de cero: rm $STATE_FILE"
    exit 2
    ;;
esac

# ─── 4) Reset PipeWire y forzar recarga de módulos ────────────────
c_ylw "[3/5] Regenerando initramfs (necesario para que modprobe.d aplique en boot)…"
update-initramfs -u 2>&1 | tail -3 || true

c_ylw "[4/5] Intentando recarga in-vivo de snd-hda-intel (puede fallar si está ocupado)…"
if [[ -n "${SUDO_USER:-}" ]]; then
  sudo -u "$SUDO_USER" systemctl --user stop pipewire pipewire-pulse wireplumber 2>/dev/null || true
fi
fuser -k /dev/snd/* 2>/dev/null || true
sleep 1
modprobe -r snd_hda_codec_cirrus snd_hda_codec_generic snd_hda_intel 2>&1 || true
sleep 1
modprobe snd_hda_intel 2>&1 || c_red "    ⚠ modprobe falló — necesitarás reboot para aplicar"
if [[ -n "${SUDO_USER:-}" ]]; then
  sudo -u "$SUDO_USER" systemctl --user start pipewire pipewire-pulse wireplumber 2>/dev/null || true
fi

# ─── 5) Marcar estrategia como probada ────────────────────────────
c_ylw "[5/5] Actualizando estado…"
echo "${TRIED}${NEXT} " > "$STATE_FILE"
echo "    Estado: $(cat $STATE_FILE)"
hr
sleep 2
echo "── aplay -l después de aplicar ──"
aplay -l 2>&1 || true

hr
if check_audio_works; then
  c_grn "✓ ¡Audio detectado in-vivo! Prueba con: speaker-test -c2 -t wav"
  c_grn "  Si igual no escuchas, abre alsamixer y revisa Master/Speaker."
else
  c_ylw "⚠ Aún no se detecta playback in-vivo. AHORA REINICIA y vuelve a correr:"
  c_ylw "    sudo $0"
  c_ylw "  Si tras reboot sigue fallando, el script probará la siguiente estrategia."
fi
sync 2>/dev/null || true
