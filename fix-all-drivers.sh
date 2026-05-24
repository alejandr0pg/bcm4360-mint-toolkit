#!/usr/bin/env bash
# fix-all-drivers.sh — Solución comprehensive para MacBook Air 2013-2017 (BCM4360).
# Corre desde kernel 6.14 estable. Repara/configura TODO el hardware Apple
# en un solo paso. NO depende de bootear a 6.8.
#
# Lo que arregla / configura:
#   1. linux-firmware (incluye Cirrus + Broadcom + Intel actualizado)
#   2. Bluetooth + bluetoothctl + módulo audio Bluetooth (audio fallback)
#   3. Audio interno: TODOS los quirks juntos (dsp_driver=1, single_cmd=1,
#      model=mba6, pin retask cs4208-mba.fw, snd-intel-dspcfg)
#   4. mbpfan (control de ventilador apropiado, sin overheat)
#   5. applesmc (sensores de temperatura/luz/movimiento)
#   6. Brightness keys + function keys (hid_apple)
#   7. Touchpad bcm5974 (clic, gestos multitouch)
#   8. PCI rescan in-vivo del codec de audio
#   9. PipeWire reset + reconfig
#
# Uso: sudo ./fix-all-drivers.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="$LOG_DIR/fix-all-drivers_$(date +%Y%m%d-%H%M%S).log"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/fix-all-drivers_$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

c_red() { printf "\033[1;31m%s\033[0m\n" "$*"; }
c_grn() { printf "\033[1;32m%s\033[0m\n" "$*"; }
c_ylw() { printf "\033[1;33m%s\033[0m\n" "$*"; }
c_blu() { printf "\033[1;34m%s\033[0m\n" "$*"; }
hr()    { printf '%.0s─' {1..60}; echo; }

if [[ $EUID -ne 0 ]]; then c_red "Ejecuta con sudo."; exit 1; fi

KERNEL="$(uname -r)"
MODEL="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
c_blu "═══ FIX-ALL-DRIVERS para $MODEL en kernel $KERNEL ═══"
echo "── Log: $LOG_FILE"
hr

has_internet() { ping -c1 -W 2 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W 2 8.8.8.8 >/dev/null 2>&1; }
INTERNET=0
has_internet && INTERNET=1
if [[ $INTERNET -eq 1 ]]; then
  c_grn "✓ Internet detectado"
else
  c_ylw "⚠ Sin internet. Algunos paquetes no se podrán instalar."
fi

# ════════════════════════════════════════════════════════════════════
# 1) Actualizar firmware (Cirrus + Broadcom + Intel)
# ════════════════════════════════════════════════════════════════════
c_ylw "[1/9] Actualizando linux-firmware…"
if [[ $INTERNET -eq 1 ]]; then
  apt update 2>&1 | tail -3
  apt install -y linux-firmware 2>&1 | tail -5
else
  echo "    (sin internet, saltando)"
fi

# ════════════════════════════════════════════════════════════════════
# 2) Bluetooth (BCM4360 incluye chip BT, viable como audio fallback)
# ════════════════════════════════════════════════════════════════════
c_ylw "[2/9] Configurando Bluetooth + soporte audio BT…"
if [[ $INTERNET -eq 1 ]]; then
  apt install -y bluez bluez-tools bluez-cups \
    pipewire-pulse libspa-0.2-bluetooth pulseaudio-module-bluetooth \
    blueman 2>&1 | tail -5 || true
fi
# Habilitar y arrancar bluetooth
systemctl enable --now bluetooth 2>&1 | tail -3 || true
# Asegurar que el módulo cargue
modprobe btusb 2>/dev/null || true
modprobe btbcm 2>/dev/null || true
echo "    Estado bluetooth: $(systemctl is-active bluetooth)"
echo "    Dispositivos BT controllers:"
bluetoothctl list 2>&1 | head -5 || echo "    (bluetoothctl no responde aún)"

# ════════════════════════════════════════════════════════════════════
# 3) Audio: TODOS los quirks juntos (último intento sin reboot)
# ════════════════════════════════════════════════════════════════════
c_ylw "[3/9] Aplicando configuración integral de audio (todos los quirks)…"

# 3a. Pin retask CS4208 (firmware)
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
echo "    ✓ /lib/firmware/cs4208-mba.fw"

# 3b. Una sola config maestra para snd-hda-intel + snd-intel-dspcfg
rm -f /etc/modprobe.d/macbook-audio.conf /etc/modprobe.d/alsa-dspcfg.conf
cat > /etc/modprobe.d/macbook-audio.conf <<'EOF'
# Config audio MacBook (todos los quirks combinados)
# dsp_driver=1: el propio kernel lo sugiere para Broadwell
options snd-intel-dspcfg dsp_driver=1
# CS4208 pin retask + power save off + single_cmd para codec que no responde via DMA
options snd-hda-intel patch=cs4208-mba.fw model=mba6 power_save=0 power_save_controller=N single_cmd=1 probe_mask=1 enable_msi=0
EOF
echo "    ✓ /etc/modprobe.d/macbook-audio.conf (config maestra)"

# 3c. ALSA UCM: forzar uso de PCH como default si aparece
mkdir -p /etc/asound.conf.d 2>/dev/null || true
# (No tocamos /etc/asound.conf — dejamos que PipeWire decida)

# 3d. Regenerar initramfs
update-initramfs -u 2>&1 | tail -3 || true

# ════════════════════════════════════════════════════════════════════
# 4) mbpfan — control de ventilador para Mac (sin esto Mac sobrecalienta)
# ════════════════════════════════════════════════════════════════════
c_ylw "[4/9] Instalando mbpfan (control de fans Mac)…"
if [[ $INTERNET -eq 1 ]]; then
  apt install -y mbpfan 2>&1 | tail -3 || true
fi
if command -v mbpfan >/dev/null 2>&1; then
  systemctl enable --now mbpfan 2>&1 | tail -3 || true
  echo "    Estado mbpfan: $(systemctl is-active mbpfan)"
else
  echo "    (mbpfan no disponible)"
fi

# ════════════════════════════════════════════════════════════════════
# 5) applesmc — sensores (temp, lid, accel)
# ════════════════════════════════════════════════════════════════════
c_ylw "[5/9] Cargando applesmc (sensores)…"
modprobe applesmc 2>&1 || true
if lsmod | grep -q applesmc; then
  c_grn "    ✓ applesmc cargado"
  # Asegurar carga al boot
  grep -qx "applesmc" /etc/modules || echo "applesmc" >> /etc/modules
else
  c_red "    ⚠ applesmc no cargó (puede ser normal si el chip no expone via DMI)"
fi

# ════════════════════════════════════════════════════════════════════
# 6) hid_apple — teclas Fn como F1-F12 directo + brightness
# ════════════════════════════════════════════════════════════════════
c_ylw "[6/9] Configurando hid_apple (Fn keys, brightness)…"
cat > /etc/modprobe.d/hid_apple.conf <<'EOF'
# fnmode=2: F-keys directas, Fn cambia a funciones especiales (más común en Linux)
# iso_layout=0: layout US (cambia a 1 si tu teclado es ISO/UK/ES)
options hid_apple fnmode=2 iso_layout=0
EOF
echo "    ✓ /etc/modprobe.d/hid_apple.conf"
# Aplicar in-vivo
echo 2 > /sys/module/hid_apple/parameters/fnmode 2>/dev/null && echo "    Fn mode: 2 (in-vivo)" || true

# ════════════════════════════════════════════════════════════════════
# 7) Touchpad bcm5974 — usualmente carga solo, pero confirmamos
# ════════════════════════════════════════════════════════════════════
c_ylw "[7/9] Verificando touchpad bcm5974…"
if lsmod | grep -q bcm5974; then
  c_grn "    ✓ bcm5974 cargado (touchpad multitouch activo)"
else
  modprobe bcm5974 2>/dev/null || true
  lsmod | grep -q bcm5974 && c_grn "    ✓ bcm5974 cargado ahora" || echo "    (módulo no disponible — touchpad usa hid genérico)"
fi

# ════════════════════════════════════════════════════════════════════
# 8) PCI remove + rescan del codec (último intento de despertar audio)
# ════════════════════════════════════════════════════════════════════
c_ylw "[8/9] PCI remove + rescan del codec de audio…"
if [[ -n "${SUDO_USER:-}" ]]; then
  sudo -u "$SUDO_USER" systemctl --user stop pipewire pipewire-pulse wireplumber 2>/dev/null || true
fi
fuser -k /dev/snd/* 2>/dev/null || true
sleep 1
modprobe -r snd_hda_codec_hdmi snd_hda_codec_cirrus snd_hda_codec_generic snd_hda_intel snd-intel-dspcfg 2>/dev/null || true
sleep 1

for dev in $(lspci -D | grep -iE "audio|multimedia" | awk '{print $1}'); do
  echo "    Remove $dev…"
  echo 1 > "/sys/bus/pci/devices/$dev/remove" 2>&1 || true
done
echo "    Esperando 4 segundos para drain…"
sleep 4
echo 1 > /sys/bus/pci/rescan
sleep 4

modprobe snd_hda_intel 2>&1 || c_red "    ⚠ modprobe snd_hda_intel falló"
sleep 2

if [[ -n "${SUDO_USER:-}" ]]; then
  sudo -u "$SUDO_USER" systemctl --user start pipewire pipewire-pulse wireplumber 2>/dev/null || true
fi
sleep 2

# ════════════════════════════════════════════════════════════════════
# 9) Verificación final y reporte
# ════════════════════════════════════════════════════════════════════
c_ylw "[9/9] Verificación final…"
hr
echo "── Audio devices (aplay -l) ──"
aplay -l 2>&1 || echo "(aplay no instalado, instalando)" && apt install -y alsa-utils 2>&1 | tail -3
echo "── Bluetooth controllers ──"
bluetoothctl list 2>&1 | head -3 || true
echo "── WiFi interfaz ──"
ip -br link | grep -E "wl(p|an)" || echo "(sin interfaz WiFi)"
echo "── Sensores temp ──"
sensors 2>/dev/null | grep -E "Core|Package" | head -5 || echo "(lm-sensors no instalado)"
echo "── Fans ──"
sensors 2>/dev/null | grep -i fan | head -3 || true
echo "── dmesg audio (últimas líneas) ──"
dmesg | grep -iE "snd_hda|codec|cirrus|azx" | tail -10

hr
AUDIO_OK=0
aplay -l 2>/dev/null | grep -qiE "card .*device .*\[(Analog|Speaker|Headphone|PCM)" && AUDIO_OK=1

if [[ $AUDIO_OK -eq 1 ]]; then
  c_grn "✓✓✓ AUDIO INTERNO FUNCIONA ✓✓✓"
  c_grn "    Prueba: speaker-test -c2 -t wav -l1"
else
  c_red "✗ Audio interno aún no responde (codec timeout es hardware-level)."
  echo
  c_blu "RESPALDOS POSIBLES YA CONFIGURADOS:"
  echo "  • Bluetooth: empareja unos audífonos/parlante BT — funciona como sink"
  echo "    Comandos: bluetoothctl → power on → scan on → pair XX:XX → connect XX:XX"
  echo "  • USB audio: conecta cualquier DAC USB o headset USB — plug & play"
  echo "  • HDMI: conecta a monitor/TV con HDMI, audio sale por ahí"
  echo
  c_blu "ÚLTIMO INTENTO SOFTWARE — Cold boot completo (drena SMC):"
  echo "  1. sudo shutdown -h now"
  echo "  2. Desconecta el cargador físicamente"
  echo "  3. Espera 30 segundos completos"
  echo "  4. Mantén power 10 segundos (drain de capacitores)"
  echo "  5. Conecta cargador y enciende"
  echo "  6. aplay -l (verifica si el codec ahora responde)"
fi

hr
c_grn "Estado general del hardware:"
echo "  WiFi:      $(ip link | grep -qE 'wl(p|an)' && echo 'OK' || echo 'NO')"
echo "  Audio:     $([[ $AUDIO_OK -eq 1 ]] && echo 'OK interno' || echo 'pendiente (usar BT/USB/HDMI)')"
echo "  Bluetooth: $(systemctl is-active bluetooth)"
echo "  Fans:      $(systemctl is-active mbpfan 2>/dev/null || echo 'manual')"
echo "  Sensores:  $(lsmod | grep -q applesmc && echo 'OK' || echo 'parcial')"
echo "  Touchpad:  $(lsmod | grep -q bcm5974 && echo 'OK multitouch' || echo 'OK básico')"
echo "  Fn keys:   $(cat /sys/module/hid_apple/parameters/fnmode 2>/dev/null) (2=F-keys directas)"

sync 2>/dev/null || true
hr
c_grn "Log completo: $LOG_FILE"
