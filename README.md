# Videoportero IP en la Nube (Frente KD9203 + Asterisk VPS)

Configuración lista para producción de **Asterisk (PJSIP)** sobre un VPS Ubuntu 22.04 / Debian 12 para conectar un frente de calle **KD9203** y las aplicaciones móviles de los vecinos con soporte para video **H.264**, atravesamiento de **NAT (4G/5G y fibra)** y apertura de cerradura por **DTMF (`#`)**.

---

## Estructura del Proyecto

- [`asterisk/pjsip.conf`](asterisk/pjsip.conf): Transporte UDP/TCP/TLS, plantillas con soporte NAT (`rtp_symmetric`, `force_rport`, `rewrite_contact`), códec de video `h264`, extensión `8000` (Portero KD9203) y extensiones de vecinos (`101`, `102`, `201`) con soporte para **hasta 5 celulares simultáneos por departamento**.
- [`asterisk/extensions.conf`](asterisk/extensions.conf): Plan de marcado que hace sonar todos los celulares registrados de un departamento al mismo tiempo (`PJSIP_DIAL_CONTACTS`), permite llamar al `8000` para monitorear la cámara y cuenta con test de eco en `9999`.
- [`asterisk/rtp.conf`](asterisk/rtp.conf): Rango de puertos RTP (`10000-20000`) y soporte ICE/STUN.
- [`asterisk/logger.conf`](asterisk/logger.conf): Registro de eventos de seguridad para bloqueo automático de intrusos con **Fail2ban**.
- [`scripts/install_vps.sh`](scripts/install_vps.sh): Instalador automático para Ubuntu 22.04/24.04 o Debian 12 (instala Asterisk, genera contraseñas aleatorias, configura Firewall UFW y Fail2ban).
- [`scripts/install_flexisip_push.sh`](scripts/install_flexisip_push.sh): Instala y configura el **Proxy Push (Flexisip)** en el mismo VPS (puertos `5062` y `5063` TLS) conectado localmente a Asterisk (`127.0.0.1:5060`).
- [`push/flexisip.conf`](push/flexisip.conf): Configuración de Flexisip con `fork-late=true` y `wake-up-timeout=35` para despertar celulares bloqueados vía FCM/APNs antes de entregar el `INVITE` de videollamada.
- [`push/linphone-provisioning-template.xml`](push/linphone-provisioning-template.xml) y [`scripts/generar_qr_vecino.sh`](scripts/generar_qr_vecino.sh): Generador de **Códigos QR de autoprovisionamiento** para que cada vecino configure su app Linphone en 1 segundo escaneando un QR.
- [`scripts/agregar_vecino.sh`](scripts/agregar_vecino.sh): Script para dar de alta nuevos departamentos en segundos sin reiniciar llamadas activas.
- [`docker-compose.yml`](docker-compose.yml): Alternativa de despliegue en contenedor Docker (`network_mode: host`) con Asterisk + Flexisip.

---

## 1. Instalación Rápida en el VPS (Ubuntu 22.04 / Debian 12)

Sube esta carpeta a tu VPS (o clónala) y ejecuta:

```bash
chmod +x scripts/*.sh
sudo bash scripts/install_vps.sh
```

Si tienes un subdominio apuntando a la IP del VPS (ej. `portero.miedificio.com`) para usar certificado **Let's Encrypt** en SIP TLS:

```bash
sudo bash scripts/install_vps.sh portero.miedificio.com
```

Al finalizar, el script mostrará en pantalla y guardará en `/root/credenciales_portero.txt` la IP pública y las contraseñas generadas para la extensión `8000` y los primeros departamentos.

---

## 2. Cómo Agregar Nuevos Departamentos

Para crear la extensión de un nuevo departamento (por ejemplo, el departamento `304`):

```bash
sudo bash scripts/agregar_vecino.sh 304
```

También puedes definir una contraseña personalizada como segundo parámetro:

```bash
sudo bash scripts/agregar_vecino.sh 304 MiClaveSegura304
```

---

## 2.5. Instalar el Proxy Push (Flexisip) y Generar QR para Vecinos

Para que los celulares despierten cuando tienen la pantalla apagada (Android Doze / iOS Background), ejecuta en el mismo VPS:

```bash
sudo bash scripts/install_flexisip_push.sh
```

### Cómo funciona la arquitectura en el mismo VPS:
1. **Frente KD9203 (Siempre encendido)** $\rightarrow$ Registra directo en **Asterisk (`Puerto 5060`)**.
2. **Celulares de Vecinos (App Linphone)** $\rightarrow$ Registran a través de **Flexisip (`Puerto 5062 TCP` / `5063 TLS`)**, el cual guarda los tokens Push (`pn-prid`) y reenvía el registro localmente a Asterisk (`127.0.0.1:5060`).
3. **Al tocar timbre en el KD9203 (ej. Depto `101`)**:
   - Asterisk envía el `INVITE` a Flexisip (`127.0.0.1:5062`).
   - Flexisip envía la notificación Push (FCM/APNs) a todos los celulares registrados del Depto `101` y retiene el `INVITE` (`fork-late=true`, `wake-up-timeout=35`).
   - En ~1.5 segundos los celulares despiertan, se registran y reciben la videollamada **H.264** simultáneamente.

### Generar Código QR de configuración automática para un vecino:
Para evitar cargar IP, puerto, códec H.264 y DTMF `#` a mano en cada celular, genera el QR de aprovisionamiento remoto:

```bash
sudo bash scripts/generar_qr_vecino.sh 101
```

El vecino solo abre **Linphone $\rightarrow$ Asistente $\rightarrow$ Obtener configuración remota $\rightarrow$ Escanear QR**, y su celular queda listo con video H.264, Proxy Push y apertura con `#`.

---

## 3. Configuración del Frente de Calle KD9203 (Web UI Local)

Ingresa por navegador a la IP local del **KD9203** en el edificio y configura los siguientes parámetros:

1. **Configuración SIP (Cuenta / VoIP)**:
   - **Habilitar SIP / Registrar**: `Activado`
   - **Servidor SIP (Host)**: `<IP_PUBLICA_DE_TU_VPS>`
   - **Puerto SIP**: `5060` (Transporte `UDP` o `TCP`)
   - **Usuario / Extensión (Account / User ID)**: `8000`
   - **ID de Autenticación (Auth ID)**: `8000`
   - **Contraseña**: *(La generada en `/root/credenciales_portero.txt`)*
   - **NAT / STUN**: Activar `Keep-alive` (30 seg) o STUN `stun.l.google.com:19302`.

2. **Configuración de Video (Crítico para fluidez en 4G/5G)**:
   - **Códec de Video**: `H.264`
   - **Perfil H.264**: `Baseline Profile` (máxima compatibilidad con celulares iOS/Android)
   - **Resolución recomendada para stream SIP**: `720p (1280x720)` o `VGA/CIF (640x480)`
   - **Bitrate máximo**: `512 kbps` a `768 kbps` (evita cortes de video cuando el vecino está con señal celular moderada)
   - **FPS**: `15 fps`

3. **Configuración de Apertura de Puerta (Relé / DTMF)**:
   - **Modo DTMF**: `RFC2833` (compatible con `rfc4733` de Asterisk) o `RFC2833 + SIP INFO`
   - **Código de apertura de Relé 1**: `#` (o `*#` según prefieras que marquen los vecinos en el teclado de la app)

---

## 4. Comandos Útiles de Diagnóstico en el VPS

Entrar a la consola de Asterisk:
```bash
sudo asterisk -rvvv
```

Ver qué departamentos y si el portero `8000` están registrados (`Avail`):
```bash
pjsip show endpoints
pjsip show aors
```

Activar traza SIP en vivo para depurar llamadas o registro del KD9203:
```bash
pjsip set logger on
```
*(Para desactivarlo: `pjsip set logger off`)*

Ver direcciones IP bloqueadas por intentos de hackeo en Fail2ban:
```bash
sudo fail2ban-client status asterisk
```

