#!/usr/bin/env bash
# diagnose-audio.sh — Captura estado completo de audio para diagnóstico offline.
# Uso: sudo ./diagnose-audio.sh
# Genera un dump en BCM4360/logs/audio-diag_*/ que se puede llevar de vuelta.
set -uo pipefail   # sin -e: queremos correr todo aunque algo falle

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DST="$SCRIPT_DIR/logs/audio-diag_$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DST" 2>/dev/null
if ! touch "$DST/.write-test" 2>/dev/null; then
  DST="/tmp/audio-diag_$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$DST"
  echo "⚠ USB no escribible, usando $DST"
fi
rm -f "$DST/.write-test"

echo "── Volcando diagnóstico de audio a: $DST"

# Datos de hardware
cat /sys/class/dmi/id/product_name > "$DST/01-model.txt" 2>&1
uname -a > "$DST/02-uname.txt" 2>&1
lsb_release -a > "$DST/03-distro.txt" 2>&1

# Estado del módulo de sonido
lsmod | grep -iE "snd|sof" > "$DST/04-lsmod-snd.txt" 2>&1
modinfo snd_hda_intel > "$DST/05-modinfo-snd-hda-intel.txt" 2>&1
cat /etc/modprobe.d/macbook-audio.conf > "$DST/06-modprobe-config.txt" 2>&1
ls -la /etc/modprobe.d/ > "$DST/07-modprobe-dir.txt" 2>&1

# ALSA: lo más importante
aplay -l > "$DST/10-aplay-l.txt" 2>&1
aplay -L > "$DST/11-aplay-L.txt" 2>&1
arecord -l > "$DST/12-arecord-l.txt" 2>&1
cat /proc/asound/cards > "$DST/13-asound-cards.txt" 2>&1
cat /proc/asound/modules > "$DST/14-asound-modules.txt" 2>&1
# Dump del codec (clave para identificar el chip y outputs)
for c in /proc/asound/card*/codec#*; do
  [[ -f "$c" ]] && cp "$c" "$DST/15-codec-$(basename $(dirname $c))-$(basename $c).txt"
done

# Estado de PipeWire/PulseAudio
pactl info > "$DST/20-pactl-info.txt" 2>&1
pactl list short sinks > "$DST/21-pactl-sinks.txt" 2>&1
pactl list short sources > "$DST/22-pactl-sources.txt" 2>&1
pw-cli info all > "$DST/23-pw-info.txt" 2>&1 || true
systemctl --user status pipewire pipewire-pulse wireplumber > "$DST/24-pw-services.txt" 2>&1 || true
# Intentar también como usuario real
if [[ -n "${SUDO_USER:-}" ]]; then
  sudo -u "$SUDO_USER" pactl info > "$DST/25-pactl-info-user.txt" 2>&1
  sudo -u "$SUDO_USER" pactl list short sinks > "$DST/26-pactl-sinks-user.txt" 2>&1
fi

# Niveles ALSA
amixer > "$DST/30-amixer-all.txt" 2>&1
for card in $(seq 0 5); do
  amixer -c $card > "$DST/31-amixer-card$card.txt" 2>&1
done

# dmesg filtrado a sonido
dmesg | grep -iE "snd|hda|cirrus|cs4|cs8|codec|audio|alsa" > "$DST/40-dmesg-audio.txt" 2>&1
journalctl -b 0 -p warning -t kernel | grep -iE "snd|hda|audio" > "$DST/41-journal-audio.txt" 2>&1
journalctl --user -b 0 -u pipewire -u pipewire-pulse -u wireplumber 2>/dev/null | tail -100 > "$DST/42-journal-pw.txt"
if [[ -n "${SUDO_USER:-}" ]]; then
  sudo -u "$SUDO_USER" journalctl --user -b 0 -u pipewire -u pipewire-pulse -u wireplumber 2>/dev/null | tail -100 > "$DST/43-journal-pw-user.txt"
fi

# Hardware PCI del audio
lspci -nnk | grep -A3 -iE "audio|multimedia" > "$DST/50-lspci-audio.txt" 2>&1

# Test rápido de speaker
( timeout 3 speaker-test -c2 -t wav -l1 2>&1 | head -30 ) > "$DST/60-speaker-test.txt"

echo "── Listo. Comprime y envía:"
echo "   tar czf $DST.tar.gz -C $(dirname $DST) $(basename $DST)"
( cd "$(dirname "$DST")" && tar czf "${DST}.tar.gz" "$(basename "$DST")" 2>/dev/null ) && \
  echo "   ✓ tar generado: ${DST}.tar.gz"
sync 2>/dev/null || true
