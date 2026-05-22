#!/usr/bin/env bash
# setup-audio-browser.sh — Arregla audio Cirrus CS4208 (MacBook Air/Pro 2013-2017)
# y optimiza Firefox para Intel HD Graphics (Haswell/Broadwell/Skylake).
#
# Uso:
#   sudo ./setup-audio-browser.sh
#
# Cambios:
#   1. Detecta modelo MacBook via DMI
#   2. Aplica quirk snd-hda-intel correcto (mba6/mbp11/imac/macmini)
#   3. Recarga módulo de sonido y desmutea ALSA
#   4. Escribe user.js de Firefox con WebRender + VAAPI + dmabuf
#   5. Añade MOZ_X11_EGL=1 a /etc/environment para activar EGL
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Logging al USB ──
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="$LOG_DIR/setup-audio-browser_$(date +%Y%m%d-%H%M%S).log"
if ! touch "$LOG_FILE" 2>/dev/null; then
  LOG_FILE="/tmp/setup-audio-browser_$(date +%Y%m%d-%H%M%S).log"
  echo "⚠ No se pudo escribir en USB, log en: $LOG_FILE"
fi
exec > >(tee -a "$LOG_FILE") 2>&1
echo "── Log: $LOG_FILE"
echo "── Fecha: $(date)"

c_red()  { printf "\033[1;31m%s\033[0m\n" "$*"; }
c_grn()  { printf "\033[1;32m%s\033[0m\n" "$*"; }
c_ylw()  { printf "\033[1;33m%s\033[0m\n" "$*"; }
c_blu()  { printf "\033[1;34m%s\033[0m\n" "$*"; }
hr()     { printf '%.0s─' {1..60}; echo; }

on_error() {
  local rc=$?
  c_red "════════════════════════════════════════════════════════"
  c_red "✗ ERROR en línea $1 — exit $rc"
  c_red "  Comando: ${BASH_COMMAND}"
  c_red "════════════════════════════════════════════════════════"
}
trap 'on_error $LINENO' ERR

if [[ $EUID -ne 0 ]]; then
  c_red "Ejecuta con sudo."
  exit 1
fi

c_blu "═══ Audio + Firefox setup para MacBook ═══"
hr

# ─── 1) Detectar modelo MacBook ──────────────────────────────────
MODEL="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
echo "Modelo DMI: $MODEL"

case "$MODEL" in
  MacBookAir6,*|MacBookAir7,*) QUIRK="mba6" ;;          # Air 2013-2015
  MacBookAir8,*|MacBookAir9,*) QUIRK="auto" ;;          # Air 2018+ (CS8409, requiere otro driver)
  MacBookPro11,*|MacBookPro12,*) QUIRK="mbp11" ;;       # Pro 2013-2015
  Macmini7,*) QUIRK="macmini" ;;
  iMac14,*|iMac15,*) QUIRK="imac27_122" ;;
  *) QUIRK="auto" ;;
esac
echo "Quirk snd-hda-intel: $QUIRK"

# ─── 2) Audio: configurar snd-hda-intel ──────────────────────────
c_ylw "[1/5] Configurando módulo snd-hda-intel con model=$QUIRK…"
cat > /etc/modprobe.d/macbook-audio.conf <<EOF
# Generado por setup-audio-browser.sh
# Quirk para audio Cirrus en $MODEL
options snd-hda-intel model=$QUIRK
options snd-hda-intel power_save=0 power_save_controller=N
EOF
echo "    ✓ /etc/modprobe.d/macbook-audio.conf"

# ─── 3) Recargar módulo + actualizar initramfs ───────────────────
c_ylw "[2/5] Recargando snd-hda-intel…"
modprobe -r snd_hda_intel 2>/dev/null || true
sleep 1
modprobe snd_hda_intel || c_red "    ⚠ No se pudo cargar snd_hda_intel"
update-initramfs -u 2>&1 | tail -3 || true

# ─── 4) Desmutear ALSA ───────────────────────────────────────────
c_ylw "[3/5] Desmuteando ALSA (Master + Speaker + Headphone)…"
for ctrl in Master Speaker Headphone PCM "Auto-Mute Mode"; do
  amixer -q sset "$ctrl" unmute 2>/dev/null || true
  amixer -q sset "$ctrl" 80% 2>/dev/null || true
done
alsactl store 2>/dev/null || true
echo "    ✓ Niveles guardados"

# ─── 5) VAAPI: hardware video decode (Intel HD 5000/6000) ────────
c_ylw "[4/6] Instalando VAAPI (i965-va-driver + libva)…"
VAAPI_DEBS=(
  "$SCRIPT_DIR/debs/libva2_"*"_amd64.deb"
  "$SCRIPT_DIR/debs/libva-drm2_"*"_amd64.deb"
  "$SCRIPT_DIR/debs/libva-x11-2_"*"_amd64.deb"
  "$SCRIPT_DIR/debs/libva-glx2_"*"_amd64.deb"
  "$SCRIPT_DIR/debs/i965-va-driver_"*"_amd64.deb"
  "$SCRIPT_DIR/debs/vainfo_"*"_amd64.deb"
)
shopt -s nullglob
FOUND_DEBS=()
for pat in "${VAAPI_DEBS[@]}"; do
  for f in $pat; do [[ -f "$f" ]] && FOUND_DEBS+=("$f"); done
done
shopt -u nullglob
if [[ ${#FOUND_DEBS[@]} -ge 5 ]]; then
  dpkg -i "${FOUND_DEBS[@]}" 2>&1 || c_red "  ⚠ dpkg devolvió errores VAAPI"
  echo "    Verificando VAAPI con vainfo:"
  vainfo 2>&1 | head -15 || true
else
  c_ylw "    ⏭ .deb de VAAPI no encontrados en $SCRIPT_DIR/debs/"
fi

# ─── 6) Firefox: user.js con aceleración GPU ─────────────────────
c_ylw "[5/6] Optimizando Firefox para el usuario real…"
REAL_USER="${SUDO_USER:-$USER}"
USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

# Buscar cualquier perfil de Firefox (Mint usa snap, deb o flatpak)
FF_DIRS=()
[[ -d "$USER_HOME/.mozilla/firefox" ]] && FF_DIRS+=("$USER_HOME/.mozilla/firefox")
[[ -d "$USER_HOME/snap/firefox/common/.mozilla/firefox" ]] && FF_DIRS+=("$USER_HOME/snap/firefox/common/.mozilla/firefox")
[[ -d "$USER_HOME/.var/app/org.mozilla.firefox/.mozilla/firefox" ]] && FF_DIRS+=("$USER_HOME/.var/app/org.mozilla.firefox/.mozilla/firefox")

if [[ ${#FF_DIRS[@]} -eq 0 ]]; then
  c_ylw "    ⚠ No se encontró perfil de Firefox. Abre Firefox una vez y re-ejecuta."
else
  for FF_DIR in "${FF_DIRS[@]}"; do
    echo "    Buscando perfiles en: $FF_DIR"
    for PROFILE in "$FF_DIR"/*.default*/; do
      [[ -d "$PROFILE" ]] || continue
      USER_JS="$PROFILE/user.js"
      [[ -f "$USER_JS" ]] && cp "$USER_JS" "$USER_JS.bak.$(date +%s)"
      cat > "$USER_JS" <<'JSEOF'
// Generado por setup-audio-browser.sh — aceleración GPU para Intel HD
// WebRender (compositor GPU)
user_pref("gfx.webrender.all", true);
user_pref("gfx.webrender.compositor", true);
user_pref("gfx.webrender.compositor.force-enabled", true);
// Aceleración general
user_pref("layers.acceleration.force-enabled", true);
user_pref("layers.gpu-process.enabled", true);
// VAAPI: decodificación de video por GPU
user_pref("media.ffmpeg.vaapi.enabled", true);
user_pref("media.ffvpx.enabled", false);
user_pref("media.rdd-vpx.enabled", true);
user_pref("media.navigator.mediadatadecoder_vpx_enabled", true);
// dmabuf (necesario para VAAPI en X11/Wayland)
user_pref("widget.dmabuf.force-enabled", true);
// Menos procesos para MacBook Air con 4-8GB RAM
user_pref("dom.ipc.processCount", 4);
user_pref("dom.ipc.processCount.webIsolated", 2);
// Reducir telemetría y studies (consumen CPU/red)
user_pref("toolkit.telemetry.enabled", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("app.shield.optoutstudies.enabled", false);
// Cache en RAM agresivo
user_pref("browser.cache.memory.enable", true);
user_pref("browser.cache.memory.capacity", 524288);
// Smooth scrolling adaptativo
user_pref("general.smoothScroll", true);
user_pref("mousewheel.min_line_scroll_amount", 30);
JSEOF
      chown "$REAL_USER:$REAL_USER" "$USER_JS"
      echo "    ✓ user.js → $PROFILE"
    done
  done
fi

# Variable de entorno EGL (necesaria para WebRender/VAAPI en X11)
c_ylw "[6/6] Configurando MOZ_X11_EGL en /etc/environment…"
if ! grep -q "MOZ_X11_EGL" /etc/environment 2>/dev/null; then
  echo 'MOZ_X11_EGL=1' >> /etc/environment
  echo "    ✓ MOZ_X11_EGL=1 añadido"
else
  echo "    ⏭ MOZ_X11_EGL ya configurado"
fi

hr
c_grn "✓ Listo. Pasos finales:"
echo "  • Audio: prueba con  speaker-test -c2 -t wav  (Ctrl+C para parar)"
echo "  • Si sigue sin sonido: reinicia (modprobe a veces necesita reboot)"
echo "  • Firefox: ciérralo y ábrelo de nuevo, luego visita about:support"
echo "    → 'Compositing' debe decir 'WebRender' y 'Hardware Video Decoding' ON"
echo "  • Si Firefox tiene perfil snap, EGL puede no aplicar: instala Firefox .deb"
hr
sync 2>/dev/null || true
