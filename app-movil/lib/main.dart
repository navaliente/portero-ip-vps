import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:sip_ua/sip_ua.dart';
import 'package:uuid/uuid.dart';

import 'screens/qr_scan_screen.dart';
import 'services/intercom_service.dart';

/// Handler de segundo plano (Pantalla apagada / Android Doze / iOS CallKit)
/// Cuando Asterisk ejecuta push_wakeup.py, este handler despierta el teléfono con
/// pantalla completa de llamada entrante nativa.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
  } catch (_) {}

  final data = message.data;
  if (data['type'] == 'incoming_intercom_call') {
    await showNativeIncomingCall(
      callerName: data['caller_name']?.toString() ?? 'Portero Edificio',
      callerNumber: data['caller']?.toString() ?? '8000',
    );
  }
}

Future<void> showNativeIncomingCall({
  required String callerName,
  required String callerNumber,
}) async {
  final callUuid = const Uuid().v4();
  final params = CallKitParams(
    id: callUuid,
    nameCaller: callerName,
    appName: 'Portero IP',
    handle: callerNumber,
    type: 1, // 1 = Videollamada H.264
    textAccept: 'Atender Video',
    textDecline: 'Rechazar',
    duration: 40000,
    android: const AndroidParams(
      isCustomNotification: true,
      isShowLogo: false,
      ringtonePath: 'system_ringtone_default',
      backgroundColor: '#0F172A',
      actionColor: '#10B981',
      textColor: '#FFFFFF',
      incomingCallNotificationChannelName: 'Timbre Videoportero',
    ),
    ios: const IOSParams(
      iconName: 'CallKitLogo',
      handleType: 'generic',
      supportsVideo: true,
      maximumCallGroups: 1,
      maximumCallsPerCallGroup: 1,
      audioSessionMode: 'videoChat',
      audioSessionActive: true,
    ),
  );
  await FlutterCallkitIncoming.showCallkitIncoming(params);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String? fcmToken;
  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, sound: true, badge: true);
    fcmToken = await messaging.getToken();
  } catch (_) {
    // Permite probar la app en modo SIP/WebRTC local aun antes de agregar google-services.json
  }

  final intercomService = IntercomService();
  await intercomService.init();
  if (fcmToken != null) {
    await intercomService.registerPushTokenOnVps(fcmToken);
  }

  runApp(PorteroIpApp(intercom: intercomService, fcmToken: fcmToken));
}

class PorteroIpApp extends StatelessWidget {
  final IntercomService intercom;
  final String? fcmToken;

  const PorteroIpApp({super.key, required this.intercom, this.fcmToken});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Portero IP Edificio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6366F1),
          secondary: Color(0xFF10B981),
        ),
      ),
      home: IntercomHomePage(intercom: intercom, fcmToken: fcmToken),
    );
  }
}

class IntercomHomePage extends StatefulWidget {
  final IntercomService intercom;
  final String? fcmToken;

  const IntercomHomePage({super.key, required this.intercom, this.fcmToken});

  @override
  State<IntercomHomePage> createState() => _IntercomHomePageState();
}

class _IntercomHomePageState extends State<IntercomHomePage>
    with WidgetsBindingObserver {
  IntercomService get _svc => widget.intercom;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _svc.addListener(_onServiceUpdate);
    _listenCallKitEvents();
  }

  void _listenCallKitEvents() {
    FlutterCallkitIncoming.onEvent.listen((CallEvent? event) {
      if (event == null) return;
      if (event.event == Event.actionCallAccept) {
        _svc.connectSip();
        _svc.answerIncomingCall();
      } else if (event.event == Event.actionCallDecline ||
          event.event == Event.actionCallEnded) {
        _svc.hangup();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Al despertar la app desde una notificación Push, asegurar registro SIP inmediato
    if (state == AppLifecycleState.resumed) {
      if (!_svc.isRegistered) {
        _svc.connectSip();
      }
    }
  }

  void _onServiceUpdate() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _svc.removeListener(_onServiceUpdate);
    super.dispose();
  }

  Future<void> _scanQrCode() async {
    final qrUrl = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (qrUrl == null || !mounted) return;

    try {
      await _svc.configureFromQrUrl(qrUrl, fcmToken: widget.fcmToken);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF059669),
            content: Text(
              'Departamento ${_svc.config?.exten} configurado correctamente.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.redAccent,
            content: Text('Error al configurar desde QR: $e'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cfg = _svc.config;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: Row(
          children: [
            const Icon(Icons.videocam_rounded, color: Color(0xFF818CF8)),
            const SizedBox(width: 10),
            Text(
              cfg != null ? 'Portero IP • Depto ${cfg.exten}' : 'Portero IP',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Escanear QR del Departamento',
            icon: const Icon(Icons.qr_code_scanner_rounded),
            onPressed: _scanQrCode,
          ),
        ],
      ),
      body: _svc.hasActiveCall ? _buildActiveCallView() : _buildIdleDashboard(),
    );
  }

  Widget _buildIdleDashboard() {
    final cfg = _svc.config;
    final online = _svc.isRegistered;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Tarjeta de Estado SIP + Push
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: online ? const Color(0xFF10B981) : const Color(0xFF475569),
              ),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor:
                      online ? const Color(0xFF065F46) : const Color(0xFF334155),
                  child: Icon(
                    online ? Icons.check_circle : Icons.cloud_off,
                    color: online ? const Color(0xFF34D399) : Colors.grey,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        cfg == null
                            ? 'Departamento no vinculado'
                            : 'Departamento ${cfg.exten}',
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        cfg == null
                            ? 'Escanea el código QR del Panel Web para activar tu portero'
                            : online
                                ? 'Conectado al VPS (${cfg.sipHost}) • Push Activo'
                                : 'Reconectando a ${cfg.sipHost}...',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.blueGrey.shade200,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),

          // Botón principal para ver la cámara del Frente de Calle KD9203 (Ext 8000)
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF4F46E5),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 20),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            onPressed: online ? _svc.monitorDoorCamera : null,
            icon: const Icon(Icons.visibility_rounded, size: 28),
            label: const Text(
              'VER CÁMARA DE CALLE (8000)',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 14),

          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Color(0xFF475569)),
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            onPressed: _scanQrCode,
            icon: const Icon(Icons.qr_code_2_rounded),
            label: Text(
              cfg == null
                  ? 'ESCANEAR QR DEL DEPARTAMENTO'
                  : 'CAMBIAR DEPARTAMENTO (ESCANEAR QR)',
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }

  Widget _buildActiveCallView() {
    final isIncomingRinging = _svc.callState == CallStateEnum.PROGRESS &&
        _svc.activeCall?.direction == 'INCOMING';

    return Column(
      children: [
        // Visor de Video H.264 del Frente de Calle KD9203
        Expanded(
          child: Container(
            margin: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF334155), width: 2),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                RTCVideoView(
                  _svc.remoteRenderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
                Positioned(
                  top: 14,
                  left: 14,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.fiber_manual_record,
                            color: Colors.redAccent, size: 14),
                        SizedBox(width: 6),
                        Text(
                          'Frente KD9203 (H.264 EN VIVO)',
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_svc.isDoorUnlockedFeedback)
                  Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 16),
                      decoration: BoxDecoration(
                        color: const Color(0xDD059669),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.lock_open_rounded,
                              color: Colors.white, size: 32),
                          SizedBox(width: 12),
                          Text(
                            '¡PUERTA ABIERTA (#)!',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),

        // Controles de Llamada y Botón Gigante de Apertura DTMF (#)
        Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          decoration: const BoxDecoration(
            color: Color(0xFF1E293B),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Botón Principal: ABRIR PUERTA (Envía DTMF '#')
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: _svc.unlockDoor,
                  icon: const Icon(Icons.lock_open_rounded, size: 28),
                  label: Text(
                    'ABRIR PUERTA (ENVIAR ${_svc.config?.dtmfUnlock ?? "#"})',
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Fila de botones: Atender (si está sonando), Silenciar Mic, Altavoz, Cortar
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  if (isIncomingRinging)
                    FloatingActionButton.extended(
                      heroTag: 'btn_answer',
                      backgroundColor: const Color(0xFF059669),
                      onPressed: _svc.answerIncomingCall,
                      icon: const Icon(Icons.call),
                      label: const Text('Atender'),
                    ),
                  IconButton.filled(
                    style: IconButton.styleFrom(
                      backgroundColor: _svc.isMicMuted
                          ? Colors.amber.shade700
                          : const Color(0xFF334155),
                      padding: const EdgeInsets.all(16),
                    ),
                    onPressed: _svc.toggleMute,
                    icon: Icon(_svc.isMicMuted ? Icons.mic_off : Icons.mic),
                  ),
                  IconButton.filled(
                    style: IconButton.styleFrom(
                      backgroundColor: _svc.isSpeakerOn
                          ? const Color(0xFF4F46E5)
                          : const Color(0xFF334155),
                      padding: const EdgeInsets.all(16),
                    ),
                    onPressed: _svc.toggleSpeaker,
                    icon: Icon(
                        _svc.isSpeakerOn ? Icons.volume_up : Icons.volume_down),
                  ),
                  FloatingActionButton.extended(
                    heroTag: 'btn_hangup',
                    backgroundColor: Colors.redAccent,
                    onPressed: _svc.hangup,
                    icon: const Icon(Icons.call_end),
                    label: const Text('Cortar'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

