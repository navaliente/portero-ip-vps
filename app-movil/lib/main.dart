import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:uuid/uuid.dart';

import 'screens/access_control_screen.dart';
import 'screens/active_call_screen.dart';
import 'screens/activity_screen.dart';
import 'screens/qr_scan_screen.dart';
import 'screens/settings_screen.dart';
import 'services/intercom_service.dart';
import 'widgets/brand_graphics.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
  } catch (_) {}

  final data = message.data;
  if (data['type'] == 'incoming_intercom_call') {
    await showNativeIncomingCall(
      callerName: data['caller_name']?.toString() ?? 'Timbre Portero Edificio',
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
    type: 1,
    textAccept: 'Atender Video',
    textDecline: 'Rechazar',
    duration: 45000,
    android: const AndroidParams(
      isCustomNotification: true,
      isShowLogo: true,
      ringtonePath: 'system_ringtone_default',
      backgroundColor: '#090D16',
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
  } catch (_) {}

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
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF090D16),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6366F1),
          secondary: Color(0xFF10B981),
          surface: Color(0xFF111827),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: const Color(0xFF0F172A),
          indicatorColor: const Color(0xFF4F46E5).withOpacity(0.28),
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            final selected = states.contains(WidgetState.selected);
            return TextStyle(
              fontSize: 11,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected
                  ? const Color(0xFF818CF8)
                  : const Color(0xFF94A3B8),
            );
          }),
          iconTheme: WidgetStateProperty.resolveWith((states) {
            final selected = states.contains(WidgetState.selected);
            return IconThemeData(
              color: selected
                  ? const Color(0xFF818CF8)
                  : const Color(0xFF94A3B8),
            );
          }),
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
  int _selectedTab = 0;

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
              'Departamento ${_svc.config?.exten} vinculado correctamente.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFFDC2626),
            content: Text('Error al configurar desde QR: $e'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cfg = _svc.config;
    final inCall = _svc.hasActiveCall;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        elevation: 0,
        scrolledUnderElevation: 0,
        titleSpacing: 16,
        title: Row(
          children: [
            const BrandAppLogo(size: 38),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    cfg != null ? 'Depto ${cfg.exten}' : 'Portero IP',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                  Text(
                    cfg != null
                        ? 'Frente KD9203 • ${cfg.sipHost}'
                        : 'Sin vincular al edificio',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF94A3B8),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (!inCall)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: IconButton(
                tooltip: 'Escanear QR del Departamento',
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xFF1E293B),
                  foregroundColor: const Color(0xFF38BDF8),
                ),
                icon: const Icon(Icons.qr_code_scanner_rounded, size: 22),
                onPressed: _scanQrCode,
              ),
            ),
        ],
      ),
      body: inCall
          ? ActiveCallScreen(svc: _svc)
          : IndexedStack(
              index: _selectedTab,
              children: [
                _buildHomeTab(),
                ActivityScreen(svc: _svc),
                AccessControlScreen(svc: _svc),
                SettingsScreen(
                  svc: _svc,
                  fcmToken: widget.fcmToken,
                  onScanQr: _scanQrCode,
                ),
              ],
            ),
      bottomNavigationBar: inCall
          ? null
          : NavigationBar(
              selectedIndex: _selectedTab,
              onDestinationSelected: (i) => setState(() => _selectedTab = i),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.doorbell_outlined),
                  selectedIcon: Icon(Icons.doorbell_rounded),
                  label: 'Portero',
                ),
                NavigationDestination(
                  icon: Icon(Icons.history_outlined),
                  selectedIcon: Icon(Icons.history_rounded),
                  label: 'Actividad',
                ),
                NavigationDestination(
                  icon: Icon(Icons.face_retouching_natural_outlined),
                  selectedIcon: Icon(Icons.face_retouching_natural_rounded),
                  label: 'Accesos',
                ),
                NavigationDestination(
                  icon: Icon(Icons.tune_outlined),
                  selectedIcon: Icon(Icons.tune_rounded),
                  label: 'Ajustes',
                ),
              ],
            ),
    );
  }

  Widget _buildHomeTab() {
    final cfg = _svc.config;
    final online = _svc.isRegistered;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Hero Card de Conexión
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF1E293B),
                  const Color(0xFF0F172A),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: online
                    ? const Color(0xFF10B981).withOpacity(0.55)
                    : const Color(0xFF334155),
                width: 1.4,
              ),
              boxShadow: [
                BoxShadow(
                  color: (online
                          ? const Color(0xFF10B981)
                          : const Color(0xFF6366F1))
                      .withOpacity(0.08),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(9),
                          decoration: BoxDecoration(
                            color: const Color(0xFF4F46E5).withOpacity(0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.apartment_rounded,
                              color: Color(0xFF818CF8), size: 22),
                        ),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              cfg == null
                                  ? 'Departamento No Vinculado'
                                  : 'Departamento ${cfg.exten}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            Text(
                              cfg == null
                                  ? 'Escanea tu QR para comenzar'
                                  : 'Frente KD9203 (Ext. ${cfg.doorExten})',
                              style: const TextStyle(
                                  color: Color(0xFF94A3B8), fontSize: 12),
                            ),
                          ],
                        ),
                      ],
                    ),
                    PulsingStatusBadge(
                      isOnline: online,
                      onlineLabel: 'EN LÍNEA',
                      offlineLabel: cfg == null ? 'SIN CONFIG' : 'CONECTANDO',
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF090D16).withOpacity(0.7),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF1E293B)),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        online ? Icons.verified_user_rounded : Icons.wifi_find_rounded,
                        size: 16,
                        color: online
                            ? const Color(0xFF34D399)
                            : const Color(0xFFFBBF24),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          cfg == null
                              ? 'Toca "Escanear QR" o ingresa tus datos en Ajustes.'
                              : online
                                  ? 'Video H.264 + Audio listos • Límite 5 min'
                                  : 'Estableciendo enlace SIP seguro con ${cfg.sipHost}...',
                          style: const TextStyle(
                              color: Color(0xFFCBD5E1), fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          // Botón Hero Principal: Ver Cámara de Calle en Vivo
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              gradient: LinearGradient(
                colors: online
                    ? [const Color(0xFF4F46E5), const Color(0xFF0284C7)]
                    : [const Color(0xFF1E293B), const Color(0xFF1E293B)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: online
                  ? [
                      BoxShadow(
                        color: const Color(0xFF4F46E5).withOpacity(0.35),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                    ]
                  : null,
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(22),
                onTap: online ? _svc.monitorDoorCamera : null,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      Container(
                        width: 58,
                        height: 58,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(online ? 0.18 : 0.06),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Icon(
                          Icons.videocam_rounded,
                          color: online ? Colors.white : const Color(0xFF64748B),
                          size: 32,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'VER CÁMARA DE CALLE',
                              style: TextStyle(
                                color: online
                                    ? Colors.white
                                    : const Color(0xFF64748B),
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.4,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              online
                                  ? 'Video en vivo, hablar y abrir puerta (#)'
                                  : 'Conecta tu departamento para habilitar',
                              style: TextStyle(
                                color: online
                                    ? const Color(0xFFE0E7FF)
                                    : const Color(0xFF475569),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.arrow_forward_ios_rounded,
                        color: online ? Colors.white70 : const Color(0xFF475569),
                        size: 18,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),

          const Text(
            'ACCESOS RÁPIDOS',
            style: TextStyle(
              color: Color(0xFF64748B),
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 10),

          // Grilla de 4 tarjetas rápidas con íconos profesionales
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.28,
            children: [
              _QuickTile(
                icon: Icons.key_rounded,
                color: const Color(0xFF10B981),
                title: 'Abrir Puerta',
                subtitle: 'Ir a cámara + destrabar',
                onTap: () {
                  if (online) {
                    _svc.monitorDoorCamera();
                  } else {
                    _scanQrCode();
                  }
                },
              ),
              _QuickTile(
                icon: Icons.qr_code_2_rounded,
                color: const Color(0xFF38BDF8),
                title: 'Vincular QR',
                subtitle: cfg == null ? 'Configurar depto' : 'Cambiar interno',
                onTap: _scanQrCode,
              ),
              _QuickTile(
                icon: Icons.face_retouching_natural_rounded,
                color: const Color(0xFFA78BFA),
                title: 'Acceso Facial',
                subtitle: 'Biometría KD9203 lista',
                onTap: () => setState(() => _selectedTab = 2),
              ),
              _QuickTile(
                icon: Icons.history_rounded,
                color: const Color(0xFFF59E0B),
                title: 'Actividad',
                subtitle: '${_svc.history.length} eventos guardados',
                onTap: () => setState(() => _selectedTab = 1),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _QuickTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _QuickTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF111827),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFF1E293B)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 22),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Color(0xFF94A3B8), fontSize: 11),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
