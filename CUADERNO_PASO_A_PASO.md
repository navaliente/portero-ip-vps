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

1. **Verificar en el Panel Web (`https://vps-6615824-x.dattaweb.com/admin`)**:
   - Comprobar que la extensión `8000` (Frente KD9203) figure como **`Online (1 SIP)`**.
   - Comprobar que el departamento figure como **`Online`**.
2. **Prueba de Monitoreo desde el Celular**:
   - Desde la App del celular, llamar al **`8000`** (o tocar *"VER CÁMARA DE CALLE (8000)"*). Debe verse el video H.264 del frente y escucharse el audio de la calle.
3. **Prueba de Timbre con Pantalla Apagada y Apertura (`#`)**:
   - Bloquear la pantalla del celular.
   - Marcar `101` en el frente de calle **KD9203**.
   - El celular debe encender la pantalla con la llamada entrante, mostrar el video H.264 al atender y accionar el relé de 12V al tocar **`ABRIR PUERTA (#)`**.

---

## ETAPA 9: Monitores Interiores y Escalabilidad de Departamentos

### 1. ¿Hasta cuántos departamentos soporta cada portero `DS-KD9203-ME6`?
- **Capacidad de directorio en el frente `DS-KD9203-ME6`**: Soporta hasta **2.000 departamentos / contactos** y hasta **10.000 tarjetas Mifare / rostros**.
- **Capacidad de tu VPS (`1 vCPU / 2 GB RAM` con Asterisk)**: Soporta cómodamente **entre 150 y 300 departamentos** registrados en simultáneo y hasta **15 videollamadas H.264 al mismo tiempo**.
- **Sin cableado vertical**: No necesitas tirar cables UTP a cada piso si los vecinos usan la App en su celular o un monitor interior con Wi-Fi conectado al router de cada departamento.

### 2. ¿Qué monitores físicos se pueden poner en un departamento o casa?
Como el portero trabaja contra tu central Asterisk en la VPS (por Internet), el monitor del departamento **debe soportar registro SIP Estándar (Standard SIP Proxy)** o estar en la misma red LAN del frente:

| Modelo de Monitor | ¿Tiene Wi-Fi? | ¿Sirve conectado al Wi-Fi del vecino hacia la VPS? | Notas de Instalación |
| :--- | :---: | :---: | :--- |
| **Hikvision `DS-KH6220-LE1`** | ❌ No (solo cable red + PoE) | ⚠️ Limitado en firmware original | Conviene solo si está cableado al mismo switch local del edificio. |
| **Hikvision `DS-KH6320-WTE1`** | ✅ **Sí (Wi-Fi + PoE)** | ✅ **Sí** (Configurando *SIP Estándar / PBX*) | Muy estético, pantalla táctil 7". Requiere fuente 12V DC si se usa por Wi-Fi sin cable de red. |
| **Akuvox `C313W` (7" Linux)** | ✅ **Sí (Wi-Fi + PoE)** | ✅ **100% Nativo SIP + H.264** | **Recomendado para conectar al Wi-Fi del cliente**. 100% compatible con Asterisk VPS y abre con `#`. |
| **Fanvil `i51W` / `i52W` / `i53W`** | ✅ **Sí (Wi-Fi + PoE)** | ✅ **100% Nativo SIP + H.264** | Se registra como una extensión más (ej. `101`) en el mismo departamento junto con los celulares. |

> **Nota sobre múltiples pantallas y celulares en el mismo departamento**:
> Gracias al comando `PJSIP_DIAL_CONTACTS` en [`asterisk/extensions.conf`](asterisk/extensions.conf), cuando tocan timbre al **`101`**, suenan **al mismo tiempo** el monitor Wi-Fi de la pared y los celulares de toda la familia registrados con la extensión `101`.

---

## ETAPA 10: Conexión del Switch de Prueba (`ST106PDI-2-65`) y Cambio de Red al Edificio

### 1. Conexión con el Switch PoE `ST106PDI-2-65` (6 puertos: 4 PoE + 2 Uplink)
- **Importante sobre alimentación del `DS-KD9203-ME6`**: El frente `DS-KD9203-ME6` **no se alimenta por PoE estándar**; siempre lleva **fuente de 12V DC (1A o 2A)** en su bornera trasera (`12V` y `GND`).
- El switch PoE `ST106PDI-2-65` detecta automáticamente que el portero no pide PoE y **funciona como un switch común de datos sin quemar nada**:
  - **Puerto `UPLINK 1`**: Cable de red hacia tu Router de Internet.
  - **Puerto `UPLINK 2` o `PoE 2`**: Cable de red hacia tu PC (para configurar).
  - **Puerto `PoE 1`**: Cable de red hacia el conector RJ45 del portero `DS-KD9203-ME6`.

### 2. ¿Cómo cambiar de tu Wi-Fi/Red de prueba a la Red del Edificio?
- En el portero (`DS-KD9203-ME6`) y en los celulares **NO hay que cambiar la IP del servidor**, porque todos apuntan a la IP pública fija de tu VPS (`138.219.41.163` / `vps-6615824-x.dattaweb.com`).
- Para que el portero funcione en cualquier edificio sin tocarle la red:
  1. Entrar a `http://192.168.100.186` -> **Configuración** -> **Red** -> **Ajustes Básicos** -> **TCP/IP**.
  2. Tildar **DHCP (Obtener IP automáticamente)** y verificar que en **DNS Preferido** quede `8.8.8.8` y alternativo `1.1.1.1`.
  3. Guardar cambios. Al enchufarlo al router del edificio, tomará IP automáticamente y se conectará solo a tu VPS.

---

## ANEXO MAESTRO: Credenciales, Contraseñas y Datos Reales del Sistema

### 1. Servidor VPS (DonWeb / Dattaweb Cloud)
| Recurso | Dato / Dirección | Usuario | Contraseña / Detalle |
| :--- | :--- | :--- | :--- |
| **IP Pública Fija (IPv4)** | `138.219.41.163` | - | Host: `vps-6615824-x.dattaweb.com` |
| **Acceso SSH al VPS** | `138.219.41.163` (Puerto `5514` o `22`) | `root` | `Coninsur25/` |
| **CloudPanel (Gestión VPS)** | `https://vps-6615824-x.dattaweb.com:8443` | `navaliente` | `Coninsur25/` (Correo: `alfredonavaliente@gmail.com`) |
| **Usuario Sitio CloudPanel** | `vps-6615824-x` (FTP/SSH local) | `vps-6615824-x` | `Coninsur25/` |

### 2. Panel Web del Portero y App Web de Vecinos
| Interfaz / URL | Dirección Web | Usuario | Contraseña |
| :--- | :--- | :--- | :--- |
| **Panel Administrador + QR (HTTPS)** | `https://vps-6615824-x.dattaweb.com/admin` | `admin` | `pavuTAre38` |
| **Panel Administrador (Puerto directo)** | `http://138.219.41.163:8088/admin` | `admin` | `pavuTAre38` |
| **WebApp Vecino (Depto 101)** | `https://vps-6615824-x.dattaweb.com/vecino?exten=101` | `101` | *(Se autoconfigura desde el link o QR)* |
| **WebSocket Seguro (WSS WebRTC)** | `wss://vps-6615824-x.dattaweb.com/ws` | - | Puerto interno Asterisk: `8089` (WSS) / `8086` (WS) |
| **Consola en Vivo Local (Cámara + Relé + Timbre)** | `http://localhost:8090` (o en Wi-Fi: `http://192.168.100.175:8090`) | - | Comando: `node "panel-admin/servidor_local_en_vivo.js"` |
| **Descarga App Android (`.apk` Local / GitHub)** | `http://192.168.100.175:8090/portero-ip-edificio.apk` | - | Guardado también en [`portero-ip-edificio.apk`](portero-ip-edificio.apk) |

### 3. Cuentas y Contraseñas SIP en Asterisk (`/root/credenciales_portero.txt`)
*Servidor / Dominio SIP: `138.219.41.163` (o `vps-6615824-x.dattaweb.com`) — Puerto SIP: `5060` (UDP/TCP) y `49160` (TCP alternativo)*

| Extensión / Interno | Dispositivo / Departamento | Usuario SIP / Auth ID | Contraseña SIP | Perfil WebRTC Asociado |
| :---: | :--- | :---: | :--- | :---: |
| **`8000`** | **Frente de Calle Hikvision `DS-KD9203-ME6`** | `8000` | **`uJb2YSICXu3Q`** | - |
| **`101`** | **Departamento 101** | `101` | **`dRNLgy0xrANn`** | `101-webrtc` (misma clave) |
| **`102`** | **Departamento 102** | `102` | **`0FAPVUVOiMTY`** | `102-webrtc` (misma clave) |
| **`201`** | **Departamento 201** | `201` | **`MCR3Yupj6T3k`** | `201-webrtc` (misma clave) |

### 4. Frente de Calle Físico (`Hikvision DS-KD9203-ME6`)
| Parámetro | Valor Configurado |
| :--- | :--- |
| **Modelo y Firmware** | `DS-KD9203-ME6` (`V3.5.0 build 241114`) |
| **Dirección MAC** | `a4:d5:c2:64:37:11` |
| **IP Local actual (en tu red)** | `http://192.168.100.186` (Máscara `255.255.255.0`, Puerta de enlace `192.168.100.1`) |
| **Usuario de Administración (Web / iVMS-4200 / SADP)** | `admin` |
| **Contraseña de Activación del Portero** | **`1234567a`** |
| **Configuración SIP grabada en el equipo** | Habilitado (`true`), Servidor `138.219.41.163`, Puerto `5060`, Usuario `8000`, Clave `uJb2YSICXu3Q` |
| **Departamentos precargados en el Portero (`PhoneNumberRecords` y `UserInfo`)** | **`101`** (ID `10010110101`), **`102`** (ID `10010110102`), **`201`** (ID `10010110201`) |

### 5. Reglas que deben estar abiertas en el Firewall Externo de DonWeb (`micuenta.donweb.com`)
Para que el portero y las llamadas de voz/video atraviesen el firewall perimetral de DonWeb (**Mis Servicios -> Cloud & IaaS -> Firewall**):
1. **SIP Estándar**: Protocolo **UDP y TCP**, Puerto **`5060`**, Origen `0.0.0.0/0`.
2. **Audio y Video H.264 (RTP)**: Protocolo **UDP**, Rango de puertos **`10000` a `20000`**, Origen `0.0.0.0/0`.
3. **Web y Panel QR**: Protocolo **TCP**, Puertos **`80`, `443`, `8088`, `8089`**, Origen `0.0.0.0/0`.
4. **SSH Administración**: Protocolo **TCP**, Puertos **`22` y `5514`**, Origen `0.0.0.0/0`.


