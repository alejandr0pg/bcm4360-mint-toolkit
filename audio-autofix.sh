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
elif ! echo "$TRIED" | grep -q S5; then NEXT="S5"
elif ! echo "$TRIED" | grep -q S6; then NEXT="S6"
elif ! echo "$TRIED" | grep -q S7; then NEXT="S7"
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

# S5: escribir firmware HDA con pin defaults exactos de CS4208 MacBookAir6,2/7,2
# Pin defaults tomados de:
#   https://kernel.googlesource.com/pub/scm/linux/kernel/git/tiwai/hda-emu/+/master/codecs/cs4208-macbook-air-62
write_cs4208_firmware() {
  mkdir -p /lib/firmware
  cat > /lib/firmware/cs4208-mba.fw <<'FWEOF'
[codec]
0x10134208 0x106b7200 0

[pincfg]
0x10 0x002b4020
0x11 0x400000f0
0x12 0x90100110
0x13 0x400000f0
0x14 0x400000f0
0x15 0x400000f0
0x16 0x400000f0
0x17 0x400000f0
0x18 0x00ab9030
0x19 0x400000f0
0x1a 0x400000f0
0x1b 0x400000f0
0x1c 0x90a60100
0x1d 0x400000f0
0x1e 0x400000f0
0x1f 0x400000f0
0x20 0x400000f0
0x21 0x400000f0
0x22 0x400000f0
FWEOF
  echo "    ✓ /lib/firmware/cs4208-mba.fw escrito (pin defaults MacBookAir6,2/7,2)"
}

# S6: seleccionar un kernel != 6.14 instalado y bootearlo por default
pick_older_kernel() {
  # Lista kernels instalados, excluye 6.14, devuelve el mayor de los restantes
  ls /boot/vmlinuz-* 2>/dev/null | sed 's|/boot/vmlinuz-||' | grep -v "^6\.14\." | sort -V | tail -1
}

set_grub_default_kernel() {
  local ver="$1"
  # Buscar la entrada de menú de GRUB que apunta a ese kernel
  local entry
  entry="$(awk -v ver="$ver" '
    /^menuentry / && /Advanced/ {next}
    /^submenu / { sub_id=gensub(/.*\x27([^\x27]+)\x27.*/, "\\1", "g"); next }
    /^\tmenuentry/ && $0 ~ ver {
      mn=gensub(/.*\x27([^\x27]+)\x27.*/, "\\1", "g");
      if (sub_id) print sub_id ">" mn; else print mn;
      exit
    }
  ' /boot/grub/grub.cfg 2>/dev/null)"
  if [[ -n "$entry" ]]; then
    sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"$entry\"|" "$GRUB_FILE"
    update-grub 2>&1 | tail -3 || true
    echo "    ✓ GRUB_DEFAULT → $entry"
  else
    echo "    ⚠ No se pudo encontrar entrada GRUB para $ver"
    return 1
  fi
}

# S7: cambiar de PipeWire a PulseAudio
switch_to_pulseaudio() {
  if command -v pulseaudio >/dev/null 2>&1; then
    if [[ -n "${SUDO_USER:-}" ]]; then
      sudo -u "$SUDO_USER" systemctl --user mask --now pipewire pipewire-pulse wireplumber 2>/dev/null || true
      sudo -u "$SUDO_USER" systemctl --user unmask pulseaudio.socket pulseaudio.service 2>/dev/null || true
      sudo -u "$SUDO_USER" systemctl --user enable --now pulseaudio.socket pulseaudio.service 2>/dev/null || true
    fi
    echo "    ✓ PipeWire enmascarado, PulseAudio habilitado para $SUDO_USER"
    return 0
  fi
  echo "    ⚠ pulseaudio no instalado en el sistema (no se puede cambiar sin internet)"
  return 1
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
    grep -qx "snd-hda-intel" /etc/modules || echo "snd-hda-intel" >> /etc/modules
    ;;
  S5)
    # HDA pin remap via firmware: bypassea detección y fuerza pin defaults exactos
    write_cs4208_firmware
    apply_modprobe "patch=cs4208-mba.fw power_save=0 probe_mask=0xffff dmic_detect=0"
    apply_grub_cmdline "snd_hda_intel.dmic_detect=0 snd_hda_intel.power_save=0"
    c_blu "    → S5 fuerza los pin defaults del kernel emulator (speaker=0x12, hp=0x10)"
    ;;
  S6)
    # Downgrade de kernel: regresión confirmada en 6.11+ HWE
    c_blu "    → S6 intenta bootear un kernel != 6.14 (Mint base ships 6.8)"
    OLDER="$(pick_older_kernel)"
    if [[ -n "$OLDER" ]]; then
      echo "    Kernel alternativo encontrado: $OLDER"
      if set_grub_default_kernel "$OLDER"; then
        c_grn "    ✓ Próximo boot → kernel $OLDER"
        # Mantener modprobe limpio para que el kernel viejo detecte solo
        apply_modprobe "model=auto power_save=0"
      else
        c_red "    ✗ No se pudo cambiar GRUB_DEFAULT"
      fi
    else
      c_red "    ✗ No hay otro kernel instalado. Solo está 6.14."
      c_red "    Necesitas linux-image-6.8.0-*-generic + headers en el USB."
      c_red "    Avisa para descargarlos desde acá."
    fi
    ;;
  S7)
    # Switch PipeWire → PulseAudio
    c_blu "    → S7 cambia el servidor de audio de PipeWire a PulseAudio"
    if switch_to_pulseaudio; then
      apply_modprobe "model=auto power_save=0"
    else
      c_red "    ✗ PulseAudio no disponible offline. Skip."
    fi
    ;;
  EXHAUSTED)
    hr
    c_red "✗ Se agotaron las 7 estrategias. Probadas:"
    echo "  • S1: model=mba6"
    echo "  • S2: model=mbp101 + dmic_detect=0"
    echo "  • S3: model=auto + probe_mask=0xffff"
    echo "  • S4: + index=0 + carga forzada"
    echo "  • S5: HDA pin retask (firmware con pin defaults exactos)"
    echo "  • S6: downgrade a kernel != 6.14"
    echo "  • S7: switch a PulseAudio"
    c_red "Próximo paso: análisis manual del codec dump"
    c_red "  sudo $SCRIPT_DIR/diagnose-audio.sh"
    c_red "Trae el tar.gz y miramos juntos /proc/asound/card*/codec#*"
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
