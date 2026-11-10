import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sip_ua/sip_ua.dart';

import '../models/intercom_models.dart';

class IntercomService extends ChangeNotifier implements SipUaHelperListener {
  final SIPUAHelper _helper = SIPUAHelper();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  ApartmentConfig? config;
  RegistrationStateEnum registrationState = RegistrationStateEnum.NONE;
  TransportStateEnum transportState = TransportStateEnum.NONE;
  Call? activeCall;
  CallStateEnum callState = CallStateEnum.NONE;

  bool isDoorUnlockedFeedback = false;
  bool isSpeakerOn = true;
  bool isMicMuted = false;
  String? lastUnlockedCode;
  String? lastErrorMessage;
  String? fcmTokenCache;

  List<AccessEvent> history = [];
  int callDurationSeconds = 0;
  Timer? _callTimer;
  Timer? _reconnectTimer;
  bool _currentCallWasAnswered = false;
  bool _currentCallIsOutgoing = false;

  bool get isRegistered =>
      registrationState == RegistrationStateEnum.REGISTERED;

  bool get hasActiveCall =>
      activeCall != null &&
      callState != CallStateEnum.ENDED &&
      callState != CallStateEnum.FAILED;

  bool get isIncomingRinging =>
      hasActiveCall &&
      (callState == CallStateEnum.PROGRESS ||
          callState == CallStateEnum.CALL_INITIATION) &&
      activeCall?.direction == 'INCOMING';

  String get formattedCallDuration {
    final m = (callDurationSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (callDurationSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> init() async {
    await remoteRenderer.initialize();
    _helper.addSipUaHelperListener(this);
    await _loadHistory();
    await loadSavedConfig();
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('intercom_history');
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        history = decoded
            .map((e) => AccessEvent.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        history = [];
      }
    }
  }

  Future<void> _recordEvent(
    AccessEventType type,
    String title,
    String subtitle,
  ) async {
    final evt = AccessEvent(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      type: type,
      title: title,
      subtitle: subtitle,
      timestamp: DateTime.now(),
    );
    history = [evt, ...history].take(50).toList();
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'intercom_history',
        jsonEncode(history.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }

  Future<void> clearHistory() async {
    history = [];
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('intercom_history');
  }

  Future<void> loadSavedConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('apartment_config');
    if (raw != null && raw.isNotEmpty) {
      config = ApartmentConfig.fromJson(jsonDecode(raw));
      notifyListeners();
      connectSip();
    }
  }

  /// Descarga la configuración escaneada desde el Código QR del Panel Web
  Future<void> configureFromQrUrl(String qrUrl, {String? fcmToken}) async {
    final resp =
        await http.get(Uri.parse(qrUrl)).timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) {
      throw Exception(
          'Error descargando configuración QR (HTTP ${resp.statusCode})');
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    config = ApartmentConfig.fromJson(data);
    await _persistAndConnect(fcmToken: fcmToken);
  }

  /// Guarda configuración manual ingresada desde Ajustes
  Future<void> saveManualConfig(ApartmentConfig newConfig,
      {String? fcmToken}) async {
    config = newConfig;
    await _persistAndConnect(fcmToken: fcmToken ?? fcmTokenCache);
  }

  Future<void> _persistAndConnect({String? fcmToken}) async {
    if (config == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('apartment_config', jsonEncode(config!.toJson()));
    lastErrorMessage = null;
    notifyListeners();

    connectSip();
    final tokenToUse = fcmToken ?? fcmTokenCache;
    if (tokenToUse != null && tokenToUse.isNotEmpty) {
      await registerPushTokenOnVps(tokenToUse);
    }
  }

  /// Registra el token FCM/APNs en el VPS (/etc/asterisk/push_devices.json)
  Future<void> registerPushTokenOnVps(String fcmToken) async {
    fcmTokenCache = fcmToken;
    if (config == null || fcmToken.isEmpty) return;
    try {
      await http
          .post(
            Uri.parse(config!.pushRegisterUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'exten': config!.exten,
              'password': config!.password,
              'fcm_token': fcmToken,
              'platform': Platform.isIOS ? 'ios' : 'android',
            }),
          )
          .timeout(const Duration(seconds: 6));
    } catch (_) {}
  }

  void connectSip() {
    final cfg = config;
    if (cfg == null) return;
    _reconnectTimer?.cancel();
    lastErrorMessage = null;

    final settings = UaSettings()
      ..webSocketUrl = cfg.wsUrl
      ..webSocketSettings.allowBadCertificate = true
      ..uri = 'sip:${cfg.exten}-webrtc@${cfg.sipHost}'
      ..authorizationUser = cfg.exten
      ..password = cfg.password
      ..displayName = 'Depto ${cfg.exten}'
      ..userAgent = 'PorteroIP-Pro/1.1'
      ..dtmfMode = DtmfMode.RFC2833
      ..iceServers = [
        {'urls': 'stun:stun.l.google.com:19302'},
      ];

    try {
      _helper.start(settings);
    } catch (e) {
      lastErrorMessage = e.toString();
      notifyListeners();
    }
  }

  /// Llama al frente de calle KD9203 (Extensión 8000) para monitorear cámara en vivo
  Future<void> monitorDoorCamera() async {
    if (config == null) return;
    _currentCallIsOutgoing = true;
    _currentCallWasAnswered = false;
    isMicMuted = false;
    isSpeakerOn = true;

    await _recordEvent(
      AccessEventType.cameraMonitor,
      'Monitoreo de cámara iniciado',
      'Frente de calle KD9203 (Ext. ${config!.doorExten})',
    );

    final mediaConstraints = <String, dynamic>{
      'audio': true,
      'video': {
        'mandatory': {
          'minWidth': '640',
          'minHeight': '480',
          'minFrameRate': '15',
        },
        'facingMode': 'user',
      },
    };
    final stream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
    _helper.call(
      'sip:${config!.doorExten}@${config!.sipHost}',
      voiceOnly: false,
      mediaStream: stream,
    );
  }

  /// Atiende la llamada entrante del portero KD9203 con audio y video H.264
  Future<void> answerIncomingCall() async {
    if (activeCall == null) return;
    _currentCallWasAnswered = true;
    HapticFeedback.mediumImpact();

    final mediaConstraints = <String, dynamic>{
      'audio': true,
      'video': true,
    };
    final stream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
    activeCall!.answer(
      _helper.buildCallOptions(false),
      mediaStream: stream,
    );
    await Helper.setSpeakerphoneOn(true);
    isSpeakerOn = true;
    notifyListeners();
  }

  /// Envía el pulso DTMF '#' (o código secundario) para accionar el relé del KD9203
  Future<void> unlockDoor({String? customCode}) async {
    if (activeCall == null || config == null) return;
    final code = customCode ?? config!.dtmfUnlock;
    HapticFeedback.heavyImpact();
    activeCall!.sendDTMF(code);

    lastUnlockedCode = code;
    isDoorUnlockedFeedback = true;
    notifyListeners();

    await _recordEvent(
      AccessEventType.doorUnlocked,
      'Puerta Principal Destrabada ($code)',
      'Apertura remota enviada al frente KD9203',
    );

    Future.delayed(const Duration(seconds: 3), () {
      isDoorUnlockedFeedback = false;
      notifyListeners();
    });
  }

  void toggleMute() {
    if (activeCall == null) return;
    HapticFeedback.selectionClick();
    isMicMuted = !isMicMuted;
    if (isMicMuted) {
      activeCall!.mute(true, false);
    } else {
      activeCall!.unmute(true, false);
    }
    notifyListeners();
  }

  Future<void> toggleSpeaker() async {
    HapticFeedback.selectionClick();
    isSpeakerOn = !isSpeakerOn;
    await Helper.setSpeakerphoneOn(isSpeakerOn);
    notifyListeners();
  }

  void hangup() {
    HapticFeedback.lightImpact();
    activeCall?.hangup();
  }

  void _startCallTimer() {
    _callTimer?.cancel();
    callDurationSeconds = 0;
    _callTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      callDurationSeconds++;
      notifyListeners();
    });
  }

  void _stopCallTimer() {
    _callTimer?.cancel();
    _callTimer = null;
  }

  // === Eventos de SIPUAHelper ===

  @override
  void registrationStateChanged(RegistrationState state) {
    registrationState = state.state ?? RegistrationStateEnum.NONE;
    if (registrationState == RegistrationStateEnum.REGISTRATION_FAILED) {
      lastErrorMessage = 'Fallo de autenticación SIP (${state.cause ?? "ver clave"})';
    } else if (registrationState == RegistrationStateEnum.REGISTERED) {
      lastErrorMessage = null;
    }
    notifyListeners();
  }

  @override
  void callStateChanged(Call call, CallState state) {
    activeCall = call;
    callState = state.state;

    if (state.state == CallStateEnum.PROGRESS && call.direction == 'INCOMING') {
      _currentCallIsOutgoing = false;
      _currentCallWasAnswered = false;
      HapticFeedback.vibrate();
    } else if (state.state == CallStateEnum.CONFIRMED) {
      _currentCallWasAnswered = true;
      _startCallTimer();
      if (!_currentCallIsOutgoing) {
        _recordEvent(
          AccessEventType.ringAnswered,
          'Timbre atendido (Depto ${config?.exten ?? ""})',
          'Comunicación H.264 establecida',
        );
      }
    } else if (state.state == CallStateEnum.STREAM && state.stream != null) {
      if (state.originator == 'remote') {
        remoteRenderer.srcObject = state.stream;
        Helper.setSpeakerphoneOn(true);
      }
    } else if (state.state == CallStateEnum.ENDED ||
        state.state == CallStateEnum.FAILED) {
      if (!_currentCallIsOutgoing && !_currentCallWasAnswered) {
        _recordEvent(
          AccessEventType.ringMissed,
          'Timbre perdido',
          'Llamada entrante del frente de calle no atendida',
        );
      }
      _stopCallTimer();
      callDurationSeconds = 0;
      remoteRenderer.srcObject = null;
      activeCall = null;
    }
    notifyListeners();
  }

  @override
  void transportStateChanged(TransportState state) {
    transportState = state.state;
    if (state.state == TransportStateEnum.DISCONNECTED && config != null) {
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(const Duration(seconds: 5), () {
        if (!isRegistered) connectSip();
      });
    }
    notifyListeners();
  }

  @override
  void onNewMessage(SIPMessageRequest msg) {}

  @override
  void dispose() {
    _callTimer?.cancel();
    _reconnectTimer?.cancel();
    _helper.removeSipUaHelperListener(this);
    remoteRenderer.dispose();
    super.dispose();
  }
}
