<div align="center">

# BCM4360 Mint Toolkit

### WiFi + optimización para Linux Mint 22 en MacBook Air

Kit **offline** que arregla el WiFi Broadcom BCM4360 y optimiza el sistema con un solo comando.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Linux Mint](https://img.shields.io/badge/Linux%20Mint-22.3%20Zena-87CF3E?logo=linuxmint&logoColor=white)](https://linuxmint.com/)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04%20noble-E95420?logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Kernel](https://img.shields.io/badge/Kernel-6.14.0--37-blue?logo=linux&logoColor=white)](https://kernel.org/)
[![MacBook Air](https://img.shields.io/badge/MacBook%20Air-2013--2017-silver?logo=apple&logoColor=white)](https://support.apple.com/macbook-air)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/alejandr0pg/bcm4360-mint-toolkit/pulls)

[![GitHub stars](https://img.shields.io/github/stars/alejandr0pg/bcm4360-mint-toolkit?style=social)](https://github.com/alejandr0pg/bcm4360-mint-toolkit/stargazers)
[![GitHub forks](https://img.shields.io/github/forks/alejandr0pg/bcm4360-mint-toolkit?style=social)](https://github.com/alejandr0pg/bcm4360-mint-toolkit/network/members)
[![GitHub issues](https://img.shields.io/github/issues/alejandr0pg/bcm4360-mint-toolkit)](https://github.com/alejandr0pg/bcm4360-mint-toolkit/issues)

[Inicio rápido](#-inicio-rápido) • [Tutorial](#-tutorial-completo) • [Beneficios](#-beneficios) • [FAQ](#-faq) • [Contribuir](#-contribuir)

</div>

---

## 🚀 ¿Por qué este toolkit?

La mayoría de **MacBook Air (2013-2017)** usan el chip **Broadcom BCM4360**, que el kernel de Linux **no soporta de forma nativa**. Al instalar Mint te quedás sin WiFi, y sin WiFi no podés bajar el driver. Este toolkit rompe ese círculo vicioso.

> 💡 **El problema clásico**: necesitás Internet para bajar el driver de Internet.

### Lo que hace este kit

| 🎯 | Función |
|----|---------|
| 📦 | Prepara un USB con todos los `.deb` necesarios para instalar el driver **offline** |
| ⚡ | Optimiza el arranque (de ~20s a ~7s típicamente) |
| 🪶 | Reduce el uso de RAM y servicios en background |
| 🔁 | Todo es **reversible** — backups automáticos |

---

## 📦 Inicio rápido

### Opción A — Tengo el USB ya preparado

```bash
cd /media/$USER/BCM4360
sudo ./install-driver.sh    # Instala WiFi
sudo ./optimize-system.sh   # Optimiza sistema
sudo reboot
```

### Opción B — Preparar el USB desde cero (necesita Docker)

```bash
git clone https://github.com/alejandr0pg/bcm4360-mint-toolkit.git
cd bcm4360-mint-toolkit
./prepare-usb.sh /Volumes/TU_USB    # macOS
# o
./prepare-usb.sh /media/$USER/TU_USB # Linux con Internet
```

---

## 📊 Stats del proyecto

<div align="center">

| Métrica | Valor |
|---------|-------|
| 📦 Paquetes `.deb` incluidos | **68** |
| 💾 Tamaño total del USB | **~103 MB** |
| 🎯 Hardware soportado | MacBook Air 2013-2017 |
| 🐧 Distros compatibles | Linux Mint 22.x, Ubuntu 24.04 |
| 🏎️ Tiempo medio de arranque (antes/después) | **20s → 7s** |
| 🧪 Probado en kernel | `6.14.0-37-generic` |
| ⚖️ Licencia | MIT |
| 🌍 Idioma del soporte | 🇪🇸 Español / 🇬🇧 English |

</div>

---

## 📚 Tutorial completo

### 1️⃣ Preparar el USB (PC con Internet)

Necesitás:
- Un USB de **≥ 256 MB** formateado en **exFAT** o **FAT32**
- **Docker** instalado (Docker Desktop en macOS, `docker.io` en Linux)

```bash
# Clonar el repo
git clone https://github.com/alejandr0pg/bcm4360-mint-toolkit.git
cd bcm4360-mint-toolkit

# Ejecutar el preparador
./prepare-usb.sh /Volumes/MI_USB
```

El script:
1. Descarga **68 paquetes** `.deb` desde los repos oficiales de Ubuntu 24.04
2. Los copia al USB junto con los scripts
3. Tarda ~30-60s con Internet decente

### 2️⃣ Instalar el driver en la MacBook Air

Insertá el USB en la MacBook Air ya con Mint instalado (sin WiFi).

```bash
cd /media/$USER/BCM4360
sudo ./install-driver.sh
```

Lo que hace, paso a paso:

```
[1/5] Limpiando drivers Broadcom previos…
[2/5] Comprobando Secure Boot…
[3/5] Instalando paquetes…
[4/5] Verificando DKMS contra kernel 6.14.0-37-generic…
[5/5] Cargando módulo wl…
✓ Interfaz WiFi detectada: wlp3s0
```

### 3️⃣ Optimizar el sistema

```bash
sudo ./optimize-system.sh
sudo reboot
```

Se aplican 9 optimizaciones automáticas (ver tabla más abajo). Todos los archivos modificados se respaldan en `/root/optimize-system.backup.<fecha>/`.

---

## ⚡ Beneficios

### Antes vs Después

<div align="center">

| Métrica | 🐢 Antes | 🚀 Después | Mejora |
|---------|----------|------------|--------|
| Tiempo de arranque | ~20s | ~7s | **65% más rápido** |
| RAM al inicio | ~1.2 GB | ~650 MB | **45% menos** |
| Servicios al arrancar | 120+ | 95 | **~25 menos** |
| Crecimiento de logs | Ilimitado | 100MB máx | **Controlado** |
| Animaciones del escritorio | Lentas | Snappy | **Más fluido** |

</div>

### Detalle técnico de optimizaciones

| # | Cambio | Efecto |
|---|--------|--------|
| 1 | `GRUB_TIMEOUT=2` | Arranque ~3 segundos más rápido |
| 2 | `zram-config` + `vm.swappiness=10` | Swap comprimido en RAM, casi sin uso del disco |
| 3 | `vm.vfs_cache_pressure=50`, `dirty_ratio=10` | Mejor responsividad bajo carga |
| 4 | Deshabilita ModemManager, cups-browsed, avahi, apport, whoopsie, kerneloops | Menos servicios al arrancar |
| 5 | `journald` limitado a 100MB | No crece infinitamente |
| 6 | `fstrim.timer` semanal | Mantiene el SSD saludable |
| 7 | `preload` | Anticipa apps usadas frecuentemente |
| 8 | `apt autoremove` + `autoclean` | Libera espacio en disco |
| 9 | Cinnamon: animaciones reducidas | UI más responsiva |

> ✅ **Todo reversible**: restaurá los archivos desde `/root/optimize-system.backup.<fecha>/`

---

## 🗂️ Contenido del repo

```
bcm4360-mint-toolkit/
├── 📜 README.md              ← Este archivo
├── 📜 TUTORIAL.md            ← Guía detallada paso a paso
├── 🐧 install-driver.sh      ← Instala el driver desde debs/
├── ⚡ optimize-system.sh     ← Optimiza arranque y fluidez
├── 📦 prepare-usb.sh         ← Genera el USB desde cualquier PC con Docker
└── debs/                     ← (Generado por prepare-usb.sh — ~100 MB)
```

---

## ❓ FAQ

<details>
<summary><b>¿Funciona en mi MacBook Air?</b></summary>
<br>
Si tu modelo es de 2013-2017 y el chip WiFi es BCM4360, sí. Verificalo en Mint con:

```bash
lspci | grep -i broadcom
```

Si ves algo como `Broadcom Inc. and subsidiaries BCM4360`, este kit es para vos.
</details>

<details>
<summary><b>¿Y si tengo Secure Boot habilitado?</b></summary>
<br>
El módulo <code>wl</code> no está firmado, así que <b>no cargará</b> con Secure Boot activo. El script te avisa. Tenés dos opciones:

1. Desactivar Secure Boot desde la EFI (recomendado en MacBook Air)
2. Firmar el módulo manualmente con MOK (más complejo)
</details>

<details>
<summary><b>El módulo no compila contra kernel 6.14, ¿qué hago?</b></summary>
<br>
Es un problema conocido — Broadcom no actualizó el driver para las API nuevas del kernel. Hay <a href="https://bugs.launchpad.net/ubuntu/+source/bcmwl">parches comunitarios</a>. Abrí un issue con el log de <code>/var/lib/dkms/bcmwl/*/build/make.log</code> y te ayudamos.
</details>

<details>
<summary><b>¿Puedo usar el driver libre brcmfmac en lugar del propietario?</b></summary>
<br>
A veces funciona con el firmware actualizado. Probalo antes de instalar el propietario:

```bash
sudo modprobe -r wl
sudo modprobe brcmfmac
ip link | grep wl
```

Si aparece una interfaz <code>wlp*</code> o <code>wlan0</code> y conecta a redes, no necesitás este kit.
</details>

<details>
<summary><b>¿Cómo revierto las optimizaciones?</b></summary>
<br>
Todos los archivos modificados se respaldan automáticamente. Restaurá desde:

```bash
ls /root/optimize-system.backup.*
```

Por ejemplo:

```bash
sudo cp /root/optimize-system.backup.20260521-220000/grub /etc/default/grub
sudo update-grub
```
</details>

<details>
<summary><b>¿Funciona en MacBook Pro?</b></summary>
<br>
Si tu MacBook Pro usa el mismo chip BCM4360 (modelos 2013-2015), debería funcionar. Verificá con <code>lspci | grep -i broadcom</code>.
</details>

---

## 🤝 Contribuir

¿Encontraste un bug? ¿Querés agregar soporte para otro modelo? ¡Bienvenido!

1. Forkeá el repo
2. Creá una rama: `git checkout -b feat/mi-mejora`
3. Commit: `git commit -m "feat: descripción"`
4. Push: `git push origin feat/mi-mejora`
5. Abrí un Pull Request

### Áreas donde podés ayudar

- 🐛 Parches para compilar `bcmwl` contra kernels más nuevos
- 🌐 Traducciones del README (inglés, portugués, francés…)
- 🧪 Probar en otros modelos de MacBook
- 📝 Mejorar el tutorial con screenshots
- 🎨 Logo / banner del proyecto

---

## 👥 Colaboradores

<div align="center">

<a href="https://github.com/alejandr0pg">
  <img src="https://github.com/alejandr0pg.png" width="80px;" alt="alejandr0pg" style="border-radius: 50%;"/>
  <br />
  <sub><b>alejandr0pg</b></sub>
</a>

<br /><br />

<a href="https://github.com/alejandr0pg/bcm4360-mint-toolkit/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=alejandr0pg/bcm4360-mint-toolkit" />
</a>

<br /><br />

<sub>¿Querés aparecer aquí? Mandá un PR 🚀</sub>

</div>

---

## 📜 Licencia

Distribuido bajo licencia **MIT**. Mirá el archivo [LICENSE](LICENSE) para más detalles.

---

## 🙏 Créditos

- **Broadcom** — driver `wl` (propietario)
- **Ubuntu/Canonical** — empaquetado `bcmwl-kernel-source`
- **Linux Mint** — distro base
- **Docker** — para preparar el USB desde cualquier sistema
- La comunidad de la [Launchpad de Ubuntu](https://bugs.launchpad.net/ubuntu/+source/bcmwl) por mantener parches del driver

---

<div align="center">

**¿Te sirvió? Dale una ⭐ al repo**

[⬆ Volver arriba](#bcm4360-mint-toolkit)

</div>
