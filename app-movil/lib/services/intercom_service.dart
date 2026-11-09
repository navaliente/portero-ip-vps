import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sip_ua/sip_ua.dart';

class ApartmentConfig {
  final String exten;
  final String password;
  final String sipHost;
  final String wsUrl;
  final String doorExten;
  final String dtmfUnlock;
  final String pushRegisterUrl;

  const ApartmentConfig({
    required this.exten,
    required this.password,
    required this.sipHost,
    required this.wsUrl,
    this.doorExten = '8000',
    this.dtmfUnlock = '#',
    required this.pushRegisterUrl,
  });

  factory ApartmentConfig.fromJson(Map<String, dynamic> json) {
    final host = json['sip_host']?.toString() ?? '';
    return ApartmentConfig(
      exten: json['exten']?.toString() ?? '',
      password: json['password']?.toString() ?? '',
      sipHost: host,
      wsUrl: json['ws_url']?.toString() ?? 'ws://$host:8080/ws',
      doorExten: json['door_exten']?.toString() ?? '8000',
      dtmfUnlock: json['dtmf_unlock']?.toString() ?? '#',
      pushRegisterUrl:
          json['push_register_url']?.toString() ?? 'http://$host:8088/api/register-push',
    );
  }

  Map<String, dynamic> toJson() => {
        'exten': exten,
        'password': password,
        'sip_host': sipHost,
        'ws_url': wsUrl,
        'door_exten': doorExten,
        'dtmf_unlock': dtmfUnlock,
        'push_register_url': pushRegisterUrl,
      };
}

class IntercomService extends ChangeNotifier implements SipUaHelperListener {
  final SIPUAHelper _helper = SIPUAHelper();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  ApartmentConfig? config;
  RegistrationStateEnum registrationState = RegistrationStateEnum.NONE;
  Call? activeCall;
  CallStateEnum callState = CallStateEnum.NONE;
  bool isDoorUnlockedFeedback = false;
  bool isSpeakerOn = true;
  bool isMicMuted = false;

  bool get isRegistered =>
      registrationState == RegistrationStateEnum.REGISTERED;

  bool get hasActiveCall =>
      activeCall != null &&
      callState != CallStateEnum.ENDED &&
      callState != CallStateEnum.FAILED;

  Future<void> init() async {
    await remoteRenderer.initialize();
    _helper.addSipUaHelperListener(this);
    await loadSavedConfig();
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

  /// Descarga la configuración escaneada desde el Código QR del Panel Web y registra el celular
  Future<void> configureFromQrUrl(String qrUrl, {String? fcmToken}) async {
    final resp = await http.get(Uri.parse(qrUrl)).timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) {
      throw Exception('Error descargando configuración QR (HTTP ${resp.statusCode})');
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    config = ApartmentConfig.fromJson(data);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('apartment_config', jsonEncode(config!.toJson()));
    notifyListeners();

    connectSip();
    if (fcmToken != null && fcmToken.isNotEmpty) {
      await registerPushTokenOnVps(fcmToken);
    }
  }

  /// Registra el token FCM/APNs en el VPS (/etc/asterisk/push_devices.json)
  Future<void> registerPushTokenOnVps(String fcmToken) async {
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

    final settings = UaSettings()
      ..webSocketUrl = cfg.wsUrl
      ..webSocketSettings.allowBadCertificate = true
      ..uri = 'sip:${cfg.exten}-webrtc@${cfg.sipHost}'
      ..authorizationUser = cfg.exten
      ..password = cfg.password
      ..displayName = 'Depto ${cfg.exten}'
      ..userAgent = 'PorteroIP-App/1.0'
      ..dtmfMode = DtmfMode.RFC2833
      ..iceServers = [
        {'urls': 'stun:stun.l.google.com:19302'},
      ];

    _helper.start(settings);
  }

  /// Llama al frente de calle KD9203 (Extensión 8000) para monitorear la cámara en vivo
  Future<void> monitorDoorCamera() async {
    if (config == null) return;
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
  }

  /// Envía el pulso DTMF '#' (RFC2833/4733 + SIP INFO) para accionar el relé de cerradura del KD9203
  Future<void> unlockDoor() async {
    if (activeCall == null || config == null) return;
    final code = config!.dtmfUnlock;
    activeCall!.sendDTMF(code);
    isDoorUnlockedFeedback = true;
    notifyListeners();

    Future.delayed(const Duration(seconds: 3), () {
      isDoorUnlockedFeedback = false;
      notifyListeners();
    });
  }

  void toggleMute() {
    if (activeCall == null) return;
    isMicMuted = !isMicMuted;
    if (isMicMuted) {
      activeCall!.mute(true, false);
    } else {
      activeCall!.unmute(true, false);
    }
    notifyListeners();
  }

  Future<void> toggleSpeaker() async {
    isSpeakerOn = !isSpeakerOn;
    await Helper.setSpeakerphoneOn(isSpeakerOn);
    notifyListeners();
  }

  void hangup() {
    activeCall?.hangup();
  }

  // === Eventos de SIPUAHelper ===

  @override
  void registrationStateChanged(RegistrationState state) {
    registrationState = state.state ?? RegistrationStateEnum.NONE;
    notifyListeners();
  }

  @override
  void callStateChanged(Call call, CallState state) {
    activeCall = call;
    callState = state.state;

    if (state.state == CallStateEnum.STREAM && state.stream != null) {
      if (state.originator == 'remote') {
        remoteRenderer.srcObject = state.stream;
        Helper.setSpeakerphoneOn(true);
      }
    } else if (state.state == CallStateEnum.ENDED ||
        state.state == CallStateEnum.FAILED) {
      remoteRenderer.srcObject = null;
      activeCall = null;
    }
    notifyListeners();
  }

  @override
  void transportStateChanged(TransportState state) {}

  @override
  void onNewMessage(SIPMessageRequest msg) {}

  @override
  void onNewNotify(Notify ntf) {}

  @override
  void onNewReinvite(ReInvite event) {}

  @override
  void dispose() {
    remoteRenderer.dispose();
    super.dispose();
  }
}

