# 📚 Tutorial completo — paso a paso

Esta guía te lleva desde una MacBook Air recién instalada con Linux Mint (sin WiFi) hasta un sistema totalmente operativo y optimizado.

## 🎯 Antes de empezar

### Verificá tu hardware

En la MacBook Air con Mint, abrí una terminal y corré:

```bash
lspci | grep -i network
```

Si ves algo así, este kit es para vos:

```
03:00.0 Network controller: Broadcom Inc. BCM4360 802.11ac Wireless Network Adapter
```

### Verificá tu kernel

```bash
uname -r
```

Deberías ver `6.14.0-XX-generic`. Si tu número es distinto, avisanos en un issue — quizás hace falta ajustar el script.

---

## 🪛 Paso 1 — Preparar el USB

### Requisitos

- Cualquier computadora con **Internet**
- **Docker** instalado:
  - **macOS**: [Docker Desktop](https://www.docker.com/products/docker-desktop/)
  - **Linux**: `sudo apt install docker.io`
  - **Windows**: Docker Desktop + WSL2
- Un **USB ≥ 256 MB** formateado en **exFAT** o **FAT32**

### Formatear el USB

**macOS:**

```bash
# Listar discos para identificar el USB
diskutil list external

# Formatear (CUIDADO: borra todo, confirmá el identificador)
diskutil eraseDisk ExFAT BCM4360 GPT /dev/diskN
```

**Linux:**

```bash
lsblk
sudo mkfs.exfat -n BCM4360 /dev/sdX1
```

### Clonar el repo y preparar

```bash
git clone https://github.com/alejandr0pg/bcm4360-mint-toolkit.git
cd bcm4360-mint-toolkit

# macOS
./prepare-usb.sh /Volumes/BCM4360

# Linux
./prepare-usb.sh /media/$USER/BCM4360
```

Salida esperada:

```
═══ Preparando USB para BCM4360 + Mint 22.x ═══
Destino: /Volumes/BCM4360

[1/3] Descargando .deb (~100 MB, puede tardar)…
68
[2/3] Copiando .deb al USB…
[3/3] Copiando scripts y README al USB…

✓ USB listo en /Volumes/BCM4360
```

---

## 🌐 Paso 2 — Instalar el driver WiFi

### Sacar el USB de la PC con Internet

En **macOS**, expulsalo con:

```bash
diskutil eject /Volumes/BCM4360
```

### Insertarlo en la MacBook Air

Conectalo, abrí el gestor de archivos y verificá que se monta correctamente. Debería aparecer como `BCM4360` con 5 archivos visibles + carpeta `debs/`.

### Ejecutar el instalador

Abrí terminal y corré:

```bash
cd /media/$USER/BCM4360
sudo ./install-driver.sh
```

### ¿Qué vas a ver?

```
═══ Instalador driver Broadcom BCM4360 (offline) ═══
────────────────────────────────────────────────────────────
Carpeta de paquetes: /media/usuario/BCM4360/debs
Kernel actual:       6.14.0-37-generic
────────────────────────────────────────────────────────────
Encontrados 68 paquetes .deb
[1/5] Limpiando drivers Broadcom previos…
[2/5] Comprobando Secure Boot…
    SecureBoot disabled
[3/5] Instalando paquetes…
[4/5] Verificando DKMS contra kernel 6.14.0-37-generic…
[5/5] Cargando módulo wl…
✓ Módulo wl cargado
────────────────────────────────────────────────────────────
✓ Interfaz WiFi detectada:
wlp3s0           UP             a8:20:66:xx:xx:xx
────────────────────────────────────────────────────────────
```

### ¿Y si Secure Boot está habilitado?

El script te avisará. Tenés que:

1. **Apagar la MacBook**
2. Encenderla manteniendo presionado **⌘ + R** para entrar a la EFI/recovery
3. Desactivar Secure Boot
4. Reiniciar y volver a ejecutar el script

---

## ⚡ Paso 3 — Optimizar el sistema

### Ejecutar el optimizador

```bash
sudo ./optimize-system.sh
```

Salida esperada:

```
═══ Optimizador de Linux Mint 22 (MacBook Air) ═══
Backups en: /root/optimize-system.backup.20260521-220000
────────────────────────────────────────────────────────────
[1/9] Reduciendo timeout de GRUB a 2 segundos…
[2/9] Configurando zram-config…
[3/9] Ajustando parámetros del kernel (sysctl)…
[4/9] Deshabilitando servicios poco usados…
  ✓ ModemManager.service
  ✓ cups-browsed.service
  ✓ avahi-daemon.service
[5/9] Limitando logs de journald a 100MB…
[6/9] Habilitando fstrim semanal (SSD)…
[7/9] Instalando preload…
[8/9] Limpiando paquetes huérfanos y caché de apt…
[9/9] Reduciendo duración de animaciones de Cinnamon…
────────────────────────────────────────────────────────────
✓ Optimización completa.
```

### Reiniciar

```bash
sudo reboot
```

¡Listo! Notarás:

- ⏱️ Arranque **mucho más rápido** (de ~20s a ~7s típicamente)
- 🪶 Menos RAM en uso al inicio
- 🎬 Cinnamon más fluido

---

## 🔄 Cómo revertir cambios

### Revertir optimizaciones

```bash
ls /root/optimize-system.backup.*
sudo cp /root/optimize-system.backup.<fecha>/grub /etc/default/grub
sudo update-grub
sudo rm /etc/sysctl.d/99-mint-optimize.conf
sudo rm /etc/systemd/journald.conf.d/size.conf

# Re-habilitar servicios si querés
sudo systemctl enable --now ModemManager.service
sudo systemctl enable --now cups-browsed.service
```

### Desinstalar el driver

```bash
sudo apt purge bcmwl-kernel-source broadcom-sta-dkms
sudo modprobe -r wl
```

---

## 🆘 Solución de problemas

### "El script falla al cargar el módulo wl"

```bash
# Ver el error exacto
dmesg | tail -30

# Verificar Secure Boot
mokutil --sb-state

# Ver log de compilación DKMS
sudo cat /var/lib/dkms/bcmwl/*/build/make.log
```

### "DKMS falla en kernel 6.14"

Es un problema de compatibilidad de la API del kernel con el driver propietario. Opciones:

1. Probar el driver libre `brcmfmac` (a veces funciona):
   ```bash
   sudo modprobe -r wl
   sudo modprobe brcmfmac
   ```

2. Bajar a un kernel anterior (5.15 LTS funciona bien):
   ```bash
   sudo apt install linux-image-5.15.0-91-generic
   ```

3. Abrí un issue con el `make.log` y te pasamos un parche.

### "El USB no se monta en Mint"

```bash
sudo mkdir -p /mnt/usb
sudo mount /dev/sdX1 /mnt/usb
cd /mnt/usb
```

---

## 🎓 Glosario

| Término | Qué significa |
|---------|---------------|
| **BCM4360** | Chip WiFi de Broadcom usado en MacBook Air 2013-2017 |
| **DKMS** | Dynamic Kernel Module Support — recompila módulos al actualizar kernel |
| **wl** | Driver propietario de Broadcom |
| **brcmfmac** | Driver libre alternativo (incluido en el kernel) |
| **Secure Boot** | Firmado de módulos del kernel — bloquea módulos no firmados |
| **zram** | Swap comprimido en RAM en lugar de en disco |
| **swappiness** | Qué tan agresivamente el kernel usa swap |
| **fstrim** | Comando que mantiene el rendimiento del SSD |

---

¿Algo no está claro? Abrí un [issue](https://github.com/alejandr0pg/bcm4360-mint-toolkit/issues) y mejoramos esta guía.
