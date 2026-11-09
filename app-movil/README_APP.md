# App Móvil del Edificio (Flutter: Android & iOS)

Aplicación móvil a medida para el sistema de Videoportero IP (**KD9203 + Asterisk VPS**).

## Características incluidas

1. **Autoconfiguración por Código QR (`QrScanScreen`)**:
   - El vecino abre la app, toca **Escanear QR del Departamento** y apunta al código QR del **Panel Web (`http://<IP_VPS>:8088/admin` $\rightarrow$ pestaña "QR App Edificio")**.
   - Automáticamente descarga la extensión (`101`, `102`...), la contraseña SIP, la dirección WebSocket/SIP del VPS y registra el **Token Push (FCM/APNs)** del celular en el VPS (`POST /api/register-push`).
2. **Despertar con Pantalla Apagada (`firebase_messaging` + `flutter_callkit_incoming`)**:
   - Cuando alguien toca el timbre en el KD9203, Asterisk ejecuta [`push/push_wakeup.py`](../push/push_wakeup.py), despertando el celular bloqueado con la pantalla nativa de llamada entrante (**CallKit** en iOS / **ConnectionService** en Android).
3. **Video H.264 en Vivo + Apertura de Cerradura con `#`**:
   - Muestra el stream H.264 del frente KD9203 (`RTCVideoView`) y un botón grande **"ABRIR PUERTA (ENVIAR #)"** que envía el pulso DTMF `RFC2833/4733` (`#`) al KD9203 para accionar el relé de 12V.
   - También permite tocar **"VER CÁMARA DE CALLE (8000)"** en cualquier momento para monitorear la entrada y abrir la puerta.

---

## Cómo compilar la App (APK / iOS)

1. Asegúrate de tener el SDK de Flutter instalado y entra a la carpeta `app-movil`:
   ```bash
   cd app-movil
   flutter create . --project-name portero_ip_app
   flutter pub get
   ```

2. **(Opcional para Push propio)** Agrega el archivo `google-services.json` de tu proyecto gratuito de Firebase en `android/app/google-services.json` (y `GoogleService-Info.plist` en `ios/Runner/`).

3. En `android/app/src/main/AndroidManifest.xml`, asegúrate de declarar los permisos de cámara, micrófono y pantalla completa para llamadas entrantes:
   ```xml
   <uses-permission android:name="android.permission.INTERNET"/>
   <uses-permission android:name="android.permission.CAMERA"/>
   <uses-permission android:name="android.permission.RECORD_AUDIO"/>
   <uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS"/>
   <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
   <uses-permission android:name="android.permission.USE_FULL_SCREEN_INTENT"/>
   <uses-permission android:name="android.permission.WAKE_LOCK"/>
   ```

4. Genera el instalador APK para los vecinos:
   ```bash
   flutter build apk --release
   ```
   El archivo quedará en `build/app/outputs/flutter-apk/app-release.apk`.

