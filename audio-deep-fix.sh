#!/usr/bin/env bash
# audio-deep-fix.sh — Aplica los fixes B (dsp_driver=1) + D (PCI rescan).
# Para MacBook Air 2013-2017 con codec CS4208 que no responde a HDA.
#
# Lo que hace, en orden:
#   1. Captura estado actual (aplay -l, dmesg, codecs detectados)
#   2. Escribe /etc/modprobe.d/alsa-dspcfg.conf con dsp_driver=1
#      (el propio kernel sugirió esto en dmesg: dmic_detect deprecado)
#   3. Limpia configs viejas que pueden interferir (alsa-base si hay overrides)
#   4. Regenera initramfs para que aplique en próximos boots
#   5. Intenta despertar el codec via PCI remove + rescan in-vivo
#   6. Reinicia el módulo snd-hda-intel
#   7. Captura estado después y compara
#
# Uso: sudo ./audio-deep-fix.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="$LOG_DIR/audio-deep-fix_$(date +%Y%m%d-%H%M%S).log"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/audio-deep-fix_$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

c_red()  { printf "\033[1;31m%s\033[0m\n" "$*"; }
c_grn()  { printf "\033[1;32m%s\033[0m\n" "$*"; }
c_ylw()  { printf "\033[1;33m%s\033[0m\n" "$*"; }
c_blu()  { printf "\033[1;34m%s\033[0m\n" "$*"; }
hr()     { printf '%.0s─' {1..60}; echo; }

if [[ $EUID -ne 0 ]]; then c_red "Ejecuta con sudo."; exit 1; fi

c_blu "═══ Audio Deep-Fix (B: dsp_driver=1 + D: PCI rescan) ═══"
echo "── Log: $LOG_FILE"
echo "── Fecha: $(date)"
echo "── Kernel: $(uname -r)"
hr

# ─── 1) Estado ANTES ──────────────────────────────────────────────
c_ylw "[1/7] Capturando estado actual…"
echo "── aplay -l (antes) ──"
aplay -l 2>&1 || echo "(aplay no instalado)"
echo "── codecs detectados ──"
ls /proc/asound/card*/codec#* 2>/dev/null || echo "(ninguno)"
echo "── últimas líneas dmesg de audio ──"
dmesg | grep -iE "snd_hda|azx_get_response|codec|cirrus" | tail -15

# ─── 2) Configurar snd-intel-dspcfg.dsp_driver=1 ──────────────────
c_ylw "[2/7] Configurando snd-intel-dspcfg dsp_driver=1…"
cat > /etc/modprobe.d/alsa-dspcfg.conf <<'EOF'
# Sugerido por el propio kernel en dmesg:
#   "dmic_detect option is deprecated, pass snd-intel-dspcfg.dsp_driver=1 option instead"
# Forza driver HDA legacy en vez de SOF/AVS para Broadwell viejo.
options snd-intel-dspcfg dsp_driver=1
EOF
echo "    ✓ /etc/modprobe.d/alsa-dspcfg.conf"
cat /etc/modprobe.d/alsa-dspcfg.conf

# ─── 3) Verificar que no haya configs conflictivas ────────────────
c_ylw "[3/7] Revisando /etc/modprobe.d/ por conflictos…"
ls /etc/modprobe.d/ | head -20
for f in /etc/modprobe.d/*.conf; do
  if grep -lE "snd-?(hda-intel|intel-dspcfg)" "$f" 2>/dev/null | grep -v alsa-dspcfg | grep -v macbook-audio; then
    echo "    Contenido de $f:"
    cat "$f"
  fi
done

# ─── 4) Regenerar initramfs (para próximos boots) ─────────────────
c_ylw "[4/7] Regenerando initramfs…"
update-initramfs -u 2>&1 | tail -3 || c_red "  ⚠ update-initramfs falló"

# ─── 5) PCI remove + rescan para despertar el codec ───────────────
c_ylw "[5/7] Despertando codec via PCI remove + rescan…"
# Buscar dispositivos de audio en PCI
PCI_AUDIO_DEVS=$(lspci -D | grep -iE "audio|multimedia" | awk '{print $1}')
echo "    Dispositivos audio PCI:"
echo "$PCI_AUDIO_DEVS" | sed 's/^/      /'

# Parar PipeWire/Pulse antes de tocar PCI
if [[ -n "${SUDO_USER:-}" ]]; then
  sudo -u "$SUDO_USER" systemctl --user stop pipewire pipewire-pulse wireplumber 2>/dev/null || true
fi
fuser -k /dev/snd/* 2>/dev/null || true
sleep 1

# Descargar módulo de audio
modprobe -r snd_hda_codec_hdmi snd_hda_codec_cirrus snd_hda_codec_generic snd_hda_intel 2>&1 || true
sleep 1

# Remover y rescanear cada device de audio
for dev in $PCI_AUDIO_DEVS; do
  echo "    Removiendo $dev…"
  echo 1 > "/sys/bus/pci/devices/$dev/remove" 2>&1 || c_red "      ⚠ no se pudo remover $dev"
  sleep 1
done

echo "    Esperando 3 segundos para drain de energía del bus PCI…"
sleep 3

echo "    Rescaneando bus PCI…"
echo 1 > /sys/bus/pci/rescan
sleep 3

# Recargar módulos
modprobe snd_hda_intel 2>&1 || c_red "  ⚠ modprobe snd_hda_intel falló"
sleep 2

# Reiniciar PipeWire/Pulse
if [[ -n "${SUDO_USER:-}" ]]; then
  sudo -u "$SUDO_USER" systemctl --user start pipewire pipewire-pulse wireplumber 2>/dev/null || true
fi
sleep 2

# ─── 6) Estado DESPUÉS ────────────────────────────────────────────
c_ylw "[6/7] Capturando estado DESPUÉS del fix…"
echo "── aplay -l (después) ──"
aplay -l 2>&1 || echo "(aplay no instalado)"
echo "── codecs detectados ──"
ls /proc/asound/card*/codec#* 2>/dev/null || echo "(ninguno)"
echo "── /proc/asound/cards ──"
cat /proc/asound/cards 2>&1
echo "── dmesg últimas líneas (audio) ──"
dmesg | grep -iE "snd_hda|azx_get_response|codec|cirrus" | tail -20

# ─── 7) Conclusión + próximos pasos ───────────────────────────────
c_ylw "[7/7] Evaluación final…"
hr
if aplay -l 2>/dev/null | grep -qiE "card .*device .*\[(Analog|Speaker|Headphone|PCM)"; then
  c_grn "✓✓✓ ¡DISPOSITIVO ANALOG DETECTADO! ✓✓✓"
  c_grn "    Prueba: speaker-test -c2 -t wav -l1"
  echo
  c_grn "Para persistir en próximos boots ya está (modprobe.d + initramfs OK)."
elif aplay -l 2>/dev/null | grep -qiE "HDA Intel PCH"; then
  c_ylw "⚠ Card HDA PCH detectada pero sin device analog claro."
  c_ylw "  Revisa amixer si hay controles Master/Speaker:"
  amixer 2>&1 | head -30
else
  c_red "✗ Codec sigue sin responder. Pasos restantes:"
  echo
  c_blu "  PASO C — Cold boot completo (último intento en kernel 6.14):"
  echo "    1. sudo shutdown -h now"
  echo "    2. Desconecta el cargador"
  echo "    3. Espera 30 segundos completos"
  echo "    4. Mantén presionado el botón de power 10 segundos (drena cap.)"
  echo "    5. Conecta cargador, enciende"
  echo "    6. aplay -l"
  echo
  c_blu "  PASO A — Boot a kernel 6.8 (la única config históricamente estable):"
  echo "    1. ENTRY=\$(awk -F\\\\' '/^submenu/{s=\$2}/^[[:space:]]+menuentry/&&/6\\.8\\.0-90/&&s{print s\">\"\$2;exit}' /boot/grub/grub.cfg)"
  echo "    2. sudo grub-reboot \"\$ENTRY\""
  echo "    3. sudo reboot"
  echo "    Nota: en 6.8 NO tendrás WiFi hasta arreglar bcmwl-en-6.8."
fi
hr
sync 2>/dev/null || true
