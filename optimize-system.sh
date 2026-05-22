#!/usr/bin/env bash
# optimize-system.sh — Optimiza Linux Mint 22.x para arranque más rápido
# y mayor fluidez en MacBook Air. Aplica solo cambios reversibles y seguros.
#
# Uso: sudo ./optimize-system.sh
#
# Cambios que realiza:
#   1. Reduce GRUB timeout a 2s
#   2. Habilita y configura zram (swap comprimido en RAM)
#   3. Ajusta vm.swappiness y vfs_cache_pressure
#   4. Deshabilita servicios poco usados (bluetooth opcional, ModemManager, etc.)
#   5. Limita journald a 100MB de logs
#   6. Activa fstrim semanal para SSD
#   7. Preload de aplicaciones frecuentes
#   8. Limpia paquetes huérfanos y caché de apt
#   9. Reduce GTK animations en LightDM/Cinnamon (opcional)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Logging: guardar TODO (stdout+stderr) en el USB junto al script ──
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="$LOG_DIR/optimize-system_$(date +%Y%m%d-%H%M%S).log"
if ! touch "$LOG_FILE" 2>/dev/null; then
  LOG_FILE="/tmp/optimize-system_$(date +%Y%m%d-%H%M%S).log"
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

if [[ $EUID -ne 0 ]]; then
  c_red "Ejecuta con sudo."
  exit 1
fi

BACKUP="/root/optimize-system.backup.$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"
c_blu "═══ Optimizador de Linux Mint 22 (MacBook Air) ═══"
echo "Backups en: $BACKUP"
hr

# 1) GRUB: timeout corto y quiet splash
c_ylw "[1/9] Reduciendo timeout de GRUB a 2 segundos…"
if [[ -f /etc/default/grub ]]; then
  cp /etc/default/grub "$BACKUP/grub"
  sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=2/' /etc/default/grub
  if ! grep -q "^GRUB_TIMEOUT_STYLE=" /etc/default/grub; then
    echo "GRUB_TIMEOUT_STYLE=hidden" >> /etc/default/grub
  fi
  update-grub 2>&1 | tail -3
fi

# 2) zram (swap comprimido en RAM, mucho más rápido que swap en disco)
c_ylw "[2/9] Configurando zram-config…"
apt install -y zram-config 2>/dev/null || c_ylw "  zram-config no disponible offline, saltando"

# 3) sysctl: swappiness bajo + cache pressure
c_ylw "[3/9] Ajustando parámetros del kernel (sysctl)…"
cat > /etc/sysctl.d/99-mint-optimize.conf <<'EOF'
# Reducir uso de swap (preferir RAM)
vm.swappiness=10
# Mantener caché de inodos/dentries
vm.vfs_cache_pressure=50
# Escrituras a disco menos agresivas en SSD
vm.dirty_ratio=10
vm.dirty_background_ratio=5
# Mejor responsividad en sistemas de escritorio
kernel.sched_autogroup_enabled=1
EOF
sysctl --system >/dev/null

# 4) Deshabilitar servicios pesados/innecesarios en un laptop común
c_ylw "[4/9] Deshabilitando servicios poco usados…"
for svc in ModemManager.service cups-browsed.service avahi-daemon.service \
           apport.service whoopsie.service kerneloops.service; do
  if systemctl list-unit-files | grep -q "^$svc"; then
    systemctl disable --now "$svc" 2>/dev/null && echo "  ✓ $svc" || true
  fi
done

# 5) journald: límite de 100MB de logs
c_ylw "[5/9] Limitando logs de journald a 100MB…"
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/size.conf <<'EOF'
[Journal]
SystemMaxUse=100M
SystemKeepFree=200M
EOF
systemctl restart systemd-journald

# 6) fstrim semanal para SSD
c_ylw "[6/9] Habilitando fstrim semanal (SSD)…"
systemctl enable --now fstrim.timer 2>/dev/null || true

# 7) Preload (anticipa apps usadas frecuentemente)
c_ylw "[7/9] Instalando preload…"
apt install -y preload 2>/dev/null || c_ylw "  preload no disponible offline, saltando"

# 8) Limpiar paquetes huérfanos y caché
c_ylw "[8/9] Limpiando paquetes huérfanos y caché de apt…"
apt autoremove -y 2>&1 | tail -2
apt autoclean -y 2>&1 | tail -2

# 9) Cinnamon: animaciones más rápidas (si está disponible)
c_ylw "[9/9] Reduciendo duración de animaciones de Cinnamon (si aplica)…"
if [[ -n "${SUDO_USER:-}" ]] && command -v sudo >/dev/null; then
  sudo -u "$SUDO_USER" dbus-launch gsettings set org.cinnamon.muffin \
    workspace-cycle false 2>/dev/null || true
  sudo -u "$SUDO_USER" dbus-launch gsettings set org.cinnamon \
    enable-vfade false 2>/dev/null || true
  sudo -u "$SUDO_USER" dbus-launch gsettings set org.cinnamon \
    desktop-effects-on-dialogs false 2>/dev/null || true
fi

hr
c_grn "✓ Optimización completa."
echo
echo "Resumen de cambios:"
echo "  • GRUB timeout: 2s"
echo "  • zram + swappiness=10 (menos swap a disco)"
echo "  • Servicios pesados desactivados"
echo "  • Logs limitados a 100MB"
echo "  • fstrim semanal para SSD"
echo "  • Caché limpiada"
echo
echo "Backups originales en: $BACKUP"
echo
c_ylw "Reinicia el sistema para que todos los cambios surtan efecto:"
echo "    sudo reboot"
hr
