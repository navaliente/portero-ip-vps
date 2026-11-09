# Cuaderno de Implementación Paso a Paso: Videoportero IP en la Nube (KD9203 + Asterisk VPS + Push + App Móvil)

Este cuaderno documenta **cosa por cosa** cada etapa realizada en el proyecto y sirve como manual operativo de instalación desde el cableado físico en el edificio hasta el servidor VPS, el Proxy Push, el Panel Web de Códigos QR y la App Móvil de los vecinos.

---

## Arquitectura General del Sistema

```
[Frente de Calle KD9203] ◄── 12V DC (Cable 2x1.5mm²) ── [Fuente 12V + Batería UPS en caja interior]
         │
    (Cable UTP Cat5e/6)
         │
         ▼
[Router del Edificio (NAT)]
         │
     (Internet)
         │
         ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ VPS EN LA NUBE (Ubuntu 22.04 / Debian 12 - 1 vCPU, 2 GB RAM, IP Fija)   │
│                                                                         │
│  1. Asterisk PBX (PJSIP)                                                │
│     - Puerto 5060 (UDP/TCP) y 5061 (TLS): Registra al KD9203 (Ext 8000) │
│     - Puerto 8080 (WS) y 8089 (WSS)     : Conecta App Móvil WebRTC      │
│     - Puertos 10000-20000 (UDP)         : Audio + Video H.264           │
│                                                                         │
│  2. Proxy Push (Flexisip + push_wakeup.py FCM HTTP v1)                  │
│     - Puertos 5062 (TCP/UDP) y 5063 (TLS): Conecta App Linphone         │
│     - Despierta celulares con pantalla apagada (Android Doze / iOS)     │
│                                                                         │
│  3. Panel Web Ligero y Servidor QR (Puerto 8088)                        │
│     - Muestra estado Online/Offline del portero 8000 y departamentos    │
│     - Crea/elimina departamentos y genera Códigos QR de configuración   │
└─────────────────────────────────────────────────────────────────────────┘
         │
   (Push FCM/APNs + Videollamada H.264)
         │
         ▼
[Celulares de los Vecinos (App Edificio / App Linphone)]
  - Despiertan con pantalla bloqueada (CallKit / ConnectionService)
  - Ven la cámara H.264 del KD9203 en vivo y hablan con la visita
  - Tocan "ABRIR PUERTA (#)" -> Envía DTMF '#' -> Activa el relé de cerradura
```

---

## ETAPA 1: Instalación Física y Red Local (Frente KD9203)

1. **Alimentación Eléctrica (12V DC)**:
   - Instalar la fuente de alimentación de `12V DC / 2A` con respaldo de batería (UPS 12V) dentro de una caja estanca en el interior del edificio (nunca dejar la fuente accesible desde la calle).
   - Llevar par de cobre `2 x 1.5 mm²` desde la fuente hasta la bornera `12V / GND` del frente **KD9203** para evitar caída de tensión al accionar la cerradura.
2. **Cerradura Eléctrica / Electroimán**:
   - Conectar el destrabador eléctrico (12V) al relé de puerta (**Door Lock Relay `NO/COM/NC`**) del KD9203 colocando el diodo volante (incluido con el frente) en paralelo a la bobina de la cerradura para proteger el relé contra picos inductivos.
3. **Datos (Ethernet)**:
   - Conectar un cable UTP (`Cat5e` o `Cat6`) desde el puerto RJ45 del KD9203 hasta el switch/router de internet del edificio.
   - **Importante**: No hace falta abrir puertos (Port Forwarding) en el router del edificio, ya que el KD9203 inicia la conexión saliente hacia la IP pública del VPS.

---

## ETAPA 2: Contratación y Preparación del VPS en la Nube

1. **Especificaciones del VPS**:
   - **Sistema Operativo**: Ubuntu 22.04 LTS / 24.04 LTS o Debian 12.
   - **Recursos**: `1 vCPU`, `2 GB RAM`, `20-40 GB SSD`.
   - **Red**: `1 Dirección IPv4 Pública Fija`.
2. **Subir el repositorio al VPS**:
   Conectarse por SSH al VPS (`ssh root@TU_IP_VPS`) y clonar el repositorio:
   ```bash
   apt update && apt install -y git
   git clone https://github.com/navaliente/portero-ip-vps.git
   cd portero-ip-vps
   chmod +x scripts/*.sh
   ```

---

## ETAPA 3: Instalación de Asterisk PBX, Seguridad y Video H.264

**¿Qué hace esta etapa?**
Configura Asterisk con el motor `PJSIP` ([`asterisk/pjsip.conf`](asterisk/pjsip.conf)), el plan de marcado ([`asterisk/extensions.conf`](asterisk/extensions.conf)), el servidor WebSocket ([`asterisk/http.conf`](asterisk/http.conf)), el rango RTP `10000-20000` ([`asterisk/rtp.conf`](asterisk/rtp.conf)), el firewall **UFW** y la protección anti-hackeo **Fail2ban**.

### Ejecución paso a paso en el VPS:
```bash
sudo bash scripts/install_vps.sh
```
*(Opcional: Si tienes un dominio apuntando al VPS, ejecuta `sudo bash scripts/install_vps.sh portero.tudominio.com` para obtener un certificado SSL Let's Encrypt automático).*

### ¿Qué queda configurado al terminar este script?
- **Extensión `8000`**: Reservada para el frente de calle **KD9203**.
- **Extensiones iniciales (`101`, `102`, `201`)**: Cada departamento se crea en **doble perfil simultáneo** (compartiendo la misma contraseña):
  - `[101]` (`endpoint-base`): Para apps SIP estándar como **Linphone** o monitores interiores.
  - `[101-webrtc]` (`endpoint-webrtc`): Para la **App Móvil propia del edificio (Flutter WebRTC)**.
- **Archivo de credenciales**: Todas las contraseñas autogeneradas quedan guardadas en `/root/credenciales_portero.txt`.

---

## ETAPA 4: Configuración del Proxy Push (Despertar Celulares Bloqueados)

**¿Por qué es crítica esta etapa?**
En Android (modo *Doze*) e iOS, el sistema operativo apaga las conexiones de red en segundo plano cuando la pantalla se bloquea. Para que el celular suene al instante cuando tocan timbre en el KD9203, configuramos dos mecanismos complementarios en el mismo VPS:

1. **Proxy Push Flexisip ([`push/flexisip.conf`](push/flexisip.conf))**: Escucha en los puertos `5062` (TCP/UDP) y `5063` (TLS), retiene la llamada entrante (`fork-late=true`, `wake-up-timeout=35`) y despierta los celulares que usan protocolo SIP Push RFC 8599 (como Linphone).
2. **Despertador Directo Firebase FCM HTTP v1 ([`push/push_wakeup.py`](push/push_wakeup.py))**: Cuando el KD9203 marca a un departamento, Asterisk ejecuta este script en paralelo antes de timbrar. El script firma un token OAuth2 usando `openssl` del sistema (sin instalar paquetes externos) y envía un paquete de datos `HIGH PRIORITY` a Firebase para encender la pantalla de llamada nativa (**CallKit / ConnectionService**) de la App propia del edificio.

### Ejecución paso a paso en el VPS:
```bash
sudo bash scripts/install_flexisip_push.sh
```

> **Para activar el envío directo FCM hacia la App propia**:
> Descarga el archivo JSON de cuenta de servicio desde *Firebase Console $\rightarrow$ Configuración del proyecto $\rightarrow$ Cuentas de servicio* y cópialo en el VPS como:
> `/etc/asterisk/firebase-service-account.json`

---

## ETAPA 5: Instalación del Panel Web Ligero y Servidor QR (Puerto 8088)

**¿Qué hace esta etapa?**
Instala el servicio `portero-panel.service` ([`panel-admin/app.py`](panel-admin/app.py)) que consume solo `~12 MB de RAM` y ofrece una interfaz web protegida por contraseña en `http://<IP_PUBLICA_VPS>:8088/admin`.

### Ejecución paso a paso en el VPS:
```bash
sudo bash scripts/install_panel_admin.sh
```

### Funciones del Panel Web:
1. **Monitor en vivo**: Muestra si el **Frente KD9203 (`8000`)** está `Online` y cuántos celulares están conectados en cada departamento (`SIP` y `Push`).
2. **Alta y Baja de Departamentos**: Permite crear nuevos departamentos (ej. `304`, `401`) o eliminarlos con un clic, recargando Asterisk automáticamente.
3. **Generador de Código QR (2 modos)**:
   - **Pestaña "QR App Edificio (JSON)"**: Para escanear desde la App propia del edificio.
   - **Pestaña "QR Linphone (XML)"**: Para escanear desde la app gratuita Linphone (*Asistente $\rightarrow$ Obtener configuración remota*).

---

## ETAPA 6: Configuración del Frente de Calle KD9203 (Interfaz Web Local)

Conéctate con una notebook a la red del edificio, abre en el navegador la IP local del **KD9203** y carga los datos generados en `/root/credenciales_portero.txt`:

| Sección en el KD9203 | Parámetro | Valor a Configurar |
| :--- | :--- | :--- |
| **Red (TCP/IP)** | DHCP o IP Fija Local | Activar DHCP (o IP fija dentro del router del edificio con DNS `8.8.8.8`) |
| **Servidor SIP** | Dirección IP del Servidor / Host | `<IP_PUBLICA_DE_TU_VPS>` |
| **Servidor SIP** | Puerto SIP / Transporte | `5060` (`UDP` o `TCP`) |
| **Cuenta SIP** | Extensión / User ID / Auth ID | `8000` |
| **Cuenta SIP** | Contraseña SIP | *(Copiar de `/root/credenciales_portero.txt` o del Panel Web)* |
| **NAT** | Keep-Alive / STUN | Keep-Alive `Activado (30s)` / STUN `stun.l.google.com:19302` |
| **Video** | Códec / Perfil | **`H.264`** (`Baseline Profile` para compatibilidad total iOS/Android) |
| **Video** | Resolución / FPS / Bitrate | `720p (1280x720)` o `640x480` a `15 fps` y **`512 - 768 kbps`** |
| **Apertura (Relé)** | Modo DTMF / Código de Relé 1 | `RFC2833` (o `RFC2833 + SIP INFO`) / Código: **`#`** |
| **Directorio / Botones**| Marcado a departamentos | Que al marcar el depto `101`, llame a la extensión SIP `101` |

---

## ETAPA 7: Configuración de los Celulares de los Vecinos

Tienes dos alternativas listas y compatibles simultáneamente en cada departamento:

### Opción A: Usar la App Propia del Edificio ([`app-movil/`](app-movil/))
1. Compilar el APK desde la carpeta `app-movil` siguiendo [`app-movil/README_APP.md`](app-movil/README_APP.md):
   ```bash
   cd app-movil
   flutter create . --project-name portero_ip_app
   flutter pub get
   flutter build apk --release
   ```
2. Instalar la app en el celular del vecino y tocar **"ESCANEAR QR DEL DEPARTAMENTO"**.
3. Escanear el código de la pestaña **"QR App Edificio (JSON)"** en el Panel Web (`http://<IP_VPS>:8088/admin`).
4. ¡Listo! El celular queda registrado con video H.264 en vivo, botón **"VER CÁMARA DE CALLE (8000)"** y botón gigante verde **"ABRIR PUERTA (ENVIAR #)"**.

### Opción B: Usar la App Gratuita Linphone
1. Instalar **Linphone** desde Google Play Store o Apple App Store.
2. Abrir **Linphone $\rightarrow$ Menú ($\equiv$) $\rightarrow$ Asistente $\rightarrow$ Obtener configuración remota**.
3. Tocar el ícono de **Escanear QR** y apuntar a la pestaña **"QR Linphone (XML)"** del Panel Web (`http://<IP_VPS>:8088/admin`).
4. Al atender una llamada del portero, presionar **`#`** en el teclado numérico para abrir la puerta.

---

## ETAPA 8: Pruebas de Verificación y Diagnóstico

1. **Verificar en el Panel Web (`http://<IP_VPS>:8088/admin`)**:
   - Comprobar que la extensión `8000` (Frente KD9203) figure como **`Online (1 SIP)`**.
   - Comprobar que el departamento figure como **`Online`**.
2. **Prueba de Monitoreo desde el Celular**:
   - Desde la App del celular, llamar al **`8000`** (o tocar *"VER CÁMARA DE CALLE (8000)"*). Debe verse el video H.264 del frente y escucharse el audio de la calle.
3. **Prueba de Timbre con Pantalla Apagada y Apertura (`#`)**:
   - Bloquear la pantalla del celular.
   - Marcar `101` en el frente de calle **KD9203**.
   - El celular debe encender la pantalla con la llamada entrante, mostrar el video H.264 al atender y accionar el relé de 12V al tocar **`ABRIR PUERTA (#)`**.

