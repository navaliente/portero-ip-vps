class ApartmentConfig {
  final String exten;
  final String password;
  final String sipHost;
  final String wsUrl;
  final String doorExten;
  final String dtmfUnlock;
  final String pushRegisterUrl;
  final String buildingName;
  final int maxCallSeconds;

  const ApartmentConfig({
    required this.exten,
    required this.password,
    required this.sipHost,
    required this.wsUrl,
    this.doorExten = '8000',
    this.dtmfUnlock = '#',
    required this.pushRegisterUrl,
    this.buildingName = 'Edificio Smart • KD9203',
    this.maxCallSeconds = 300,
  });

  factory ApartmentConfig.fromJson(Map<String, dynamic> json) {
    final host = json['sip_host']?.toString() ?? '138.219.41.163';
    final ws = json['wss_url']?.toString() ??
        json['ws_url']?.toString() ??
        'wss://vps-6615824-x.dattaweb.com/ws';
    return ApartmentConfig(
      exten: json['exten']?.toString() ?? '',
      password: json['password']?.toString() ?? '',
      sipHost: host,
      wsUrl: ws,
      doorExten: json['door_exten']?.toString() ?? '8000',
      dtmfUnlock: json['dtmf_unlock']?.toString() ?? '#',
      pushRegisterUrl: json['push_register_url']?.toString() ??
          'https://vps-6615824-x.dattaweb.com/api/register-push',
      buildingName:
          json['building_name']?.toString() ?? 'Edificio Smart • KD9203',
      maxCallSeconds:
          int.tryParse(json['max_call_seconds']?.toString() ?? '') ?? 300,
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
        'building_name': buildingName,
        'max_call_seconds': maxCallSeconds,
      };
}

enum AccessEventType {
  ringIncoming,
  ringAnswered,
  ringMissed,
  cameraMonitor,
  doorUnlocked,
}

class AccessEvent {
  final String id;
  final AccessEventType type;
  final String title;
  final String subtitle;
  final DateTime timestamp;

  const AccessEvent({
    required this.id,
    required this.type,
    required this.title,
    required this.subtitle,
    required this.timestamp,
  });

  factory AccessEvent.fromJson(Map<String, dynamic> json) {
    final typeName = json['type']?.toString() ?? 'cameraMonitor';
    final parsedType = AccessEventType.values.firstWhere(
      (e) => e.name == typeName,
      orElse: () => AccessEventType.cameraMonitor,
    );
    return AccessEvent(
      id: json['id']?.toString() ?? '',
      type: parsedType,
      title: json['title']?.toString() ?? '',
      subtitle: json['subtitle']?.toString() ?? '',
      timestamp: DateTime.tryParse(json['timestamp']?.toString() ?? '') ??
          DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'title': title,
        'subtitle': subtitle,
        'timestamp': timestamp.toIso8601String(),
      };
}
