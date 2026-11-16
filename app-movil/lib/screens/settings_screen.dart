import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../models/intercom_models.dart';
import '../services/intercom_service.dart';
import '../widgets/brand_graphics.dart';

class SettingsScreen extends StatefulWidget {
  final IntercomService svc;
  final String? fcmToken;
  final VoidCallback onScanQr;

  const SettingsScreen({
    super.key,
    required this.svc,
    required this.fcmToken,
    required this.onScanQr,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _extenCtrl;
  late TextEditingController _passCtrl;
  late TextEditingController _hostCtrl;
  late TextEditingController _wsCtrl;
  late TextEditingController _dtmfCtrl;
  final TextEditingController _inviteCodeCtrl = TextEditingController();
  final TextEditingController _memberNameCtrl = TextEditingController();
  bool _showPass = false;
  bool _showManualForm = false;
  int _techTapCount = 0;
  bool _showTechSection = false;
  bool _familyLoading = false;
  String _familyRole = 'titular';
  List<Map<String, dynamic>> _familyMembers = [];
  String? _familyError;

  static const String _apiBase = 'https://vps-6615824-x.dattaweb.com';

  @override
  void initState() {
    super.initState();
    _syncControllers();
    _familyRole = widget.svc.config?.role ?? 'titular';
    _loadFamilyStatus();
  }

  String _getOrCreateDeviceId() {
    final existing = widget.svc.config?.deviceId ?? '';
    if (existing.isNotEmpty) return existing;
    final rnd = Random.secure();
    return 'dev-${List.generate(12, (_) => rnd.nextInt(16).toRadixString(16)).join()}';
  }

  Future<void> _loadFamilyStatus() async {
    final cfg = widget.svc.config;
    if (cfg == null || cfg.exten.isEmpty) return;
    setState(() {
      _familyLoading = true;
      _familyError = null;
    });
    try {
      final resp = await http.post(
        Uri.parse('$_apiBase/api/family/status'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'exten': cfg.exten,
          'password': cfg.password,
          'device_id': _getOrCreateDeviceId(),
          'invite_code': cfg.inviteCode,
        }),
      );
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        if (mounted) {
          setState(() {
            _familyRole = data['role']?.toString() ?? cfg.role;
            final list = data['members'] as List<dynamic>? ?? [];
            _familyMembers = list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
          });
        }
      }
    } catch (_) {
      // Offline / fallback silencioso
    } finally {
      if (mounted) setState(() => _familyLoading = false);
    }
  }

  Future<void> _joinWithFamilyCode() async {
    final code = _inviteCodeCtrl.text.trim().toUpperCase();
    if (code.isEmpty) return;
    setState(() {
      _familyLoading = true;
      _familyError = null;
    });
    try {
      final devId = _getOrCreateDeviceId();
      final resp = await http.post(
        Uri.parse('$_apiBase/api/family/join'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'invite_code': code, 'device_id': devId}),
      );
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (resp.statusCode == 200 && data['ok'] == true && data['config'] != null) {
        final cfgMap = Map<String, dynamic>.from(data['config'] as Map);
        cfgMap['role'] = 'familiar';
        cfgMap['device_id'] = devId;
        cfgMap['invite_code'] = data['invite_code'] ?? code;
        final cfg = ApartmentConfig.fromJson(cfgMap);
        await widget.svc.saveManualConfig(cfg, fcmToken: widget.fcmToken);
        _inviteCodeCtrl.clear();
        if (mounted) {
          setState(() => _familyRole = 'familiar');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: const Color(0xFF059669),
              content: Text('¡Vinculado como Familiar al Depto ${cfg.exten}!'),
            ),
          );
        }
      } else {
        setState(() => _familyError = data['error']?.toString() ?? 'Código inválido o revocado');
      }
    } catch (e) {
      setState(() => _familyError = 'Error de conexión al validar código');
    } finally {
      if (mounted) setState(() => _familyLoading = false);
    }
  }

  Future<void> _addFamilyMember() async {
    final cfg = widget.svc.config;
    if (cfg == null) return;
    final name = _memberNameCtrl.text.trim();
    if (name.isEmpty) return;
    setState(() {
      _familyLoading = true;
      _familyError = null;
    });
    try {
      final resp = await http.post(
        Uri.parse('$_apiBase/api/family/add'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'exten': cfg.exten,
          'password': cfg.password,
          'device_id': _getOrCreateDeviceId(),
          'name': name,
        }),
      );
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (resp.statusCode == 200 && data['ok'] == true) {
        final list = data['members'] as List<dynamic>? ?? [];
        _memberNameCtrl.clear();
        if (mounted) {
          setState(() {
            _familyMembers = list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
          });
        }
      } else {
        setState(() => _familyError = data['error']?.toString() ?? 'No se pudo agregar');
      }
    } catch (_) {
      setState(() => _familyError = 'Sin conexión con el servidor');
    } finally {
      if (mounted) setState(() => _familyLoading = false);
    }
  }

  Future<void> _revokeFamilyMember(String memberId) async {
    final cfg = widget.svc.config;
    if (cfg == null) return;
    setState(() => _familyLoading = true);
    try {
      final resp = await http.post(
        Uri.parse('$_apiBase/api/family/revoke'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'exten': cfg.exten,
          'password': cfg.password,
          'device_id': _getOrCreateDeviceId(),
          'member_id': memberId,
        }),
      );
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final list = data['members'] as List<dynamic>? ?? [];
        if (mounted) {
          setState(() {
            _familyMembers = list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Permiso revocado al instante')),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _familyLoading = false);
    }
  }

  void _syncControllers() {
    final c = widget.svc.config;
    _extenCtrl = TextEditingController(text: c?.exten ?? '101');
    _passCtrl = TextEditingController(text: c?.password ?? '');
    _hostCtrl = TextEditingController(text: c?.sipHost ?? '138.219.41.163');
    _wsCtrl = TextEditingController(
        text: c?.wsUrl ?? 'wss://vps-6615824-x.dattaweb.com/ws');
    _dtmfCtrl = TextEditingController(text: c?.dtmfUnlock ?? '#');
  }

  @override
  void dispose() {
    _extenCtrl.dispose();
    _passCtrl.dispose();
    _hostCtrl.dispose();
    _wsCtrl.dispose();
    _dtmfCtrl.dispose();
    _inviteCodeCtrl.dispose();
    _memberNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveManual() async {
    if (!_formKey.currentState!.validate()) return;
    final host = _hostCtrl.text.trim();
    final cfg = ApartmentConfig(
      exten: _extenCtrl.text.trim(),
      password: _passCtrl.text.trim(),
      sipHost: host,
      wsUrl: _wsCtrl.text.trim(),
      doorExten: '8000',
      dtmfUnlock: _dtmfCtrl.text.trim().isEmpty ? '#' : _dtmfCtrl.text.trim(),
      pushRegisterUrl: 'https://vps-6615824-x.dattaweb.com/api/register-push',
      maxCallSeconds: 300,
    );
    await widget.svc.saveManualConfig(cfg, fcmToken: widget.fcmToken);
    if (mounted) {
      FocusScope.of(context).unfocus();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF059669),
          content: Text(
              'Configuración guardada para Depto ${cfg.exten}. Conectando...'),
        ),
      );
      setState(() => _showManualForm = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = widget.svc;
    final cfg = svc.config;
    final token = widget.fcmToken ?? svc.fcmTokenCache;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onTap: () {
              _techTapCount++;
              if (_techTapCount >= 5) {
                setState(() => _showTechSection = !_showTechSection);
                _techTapCount = 0;
              }
            },
            child: const Text(
              'Ajustes y Familia',
              style: TextStyle(
                  color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Vinculación por QR o código familiar • Hasta 5 miembros por unidad',
            style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
          ),
          const SizedBox(height: 16),

          // Botón escanear QR
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF4F46E5),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 15),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            onPressed: widget.onScanQr,
            icon: const Icon(Icons.qr_code_scanner_rounded),
            label: Text(
              cfg == null
                  ? 'VINCULAR CON CÓDIGO QR'
                  : 'CAMBIAR DEPTO (ESCANEAR QR)',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 12),

          // Diagnóstico en tiempo real
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF111827),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFF1E293B)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Estado de Red y Servidor',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.bold),
                    ),
                    PulsingStatusBadge(
                      isOnline: svc.isRegistered,
                      onlineLabel: 'ONLINE',
                      offlineLabel: 'OFFLINE',
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _DiagRow('Departamento', cfg != null ? 'Depto ${cfg.exten}' : 'No asignado'),
                _DiagRow(
                  'Rol de acceso',
                  _familyRole == 'titular' ? 'Titular del Depto' : 'Familiar Autorizado',
                ),
                _DiagRow('Duración Máxima', '${cfg?.maxCallSeconds ?? 300}s (5 min)'),
                _DiagRow(
                  'Notificaciones Push',
                  token != null ? 'Activas' : 'Modo SIP Directo',
                ),
                if (svc.lastErrorMessage != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF450A0A),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFDC2626)),
                    ),
                    child: Text(
                      'Último aviso: ${svc.lastErrorMessage}',
                      style: const TextStyle(
                          color: Color(0xFFFCA5A5), fontSize: 12),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF38BDF8),
                          side: const BorderSide(color: Color(0xFF1E293B)),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: svc.connectSip,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('Reconectar ahora'),
                      ),
                    ),
                    if (token != null) ...[
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Copiar Token Push',
                        style: IconButton.styleFrom(
                          backgroundColor: const Color(0xFF1E293B),
                          foregroundColor: Colors.white70,
                        ),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: token));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Token FCM copiado al portapapeles')),
                          );
                        },
                        icon: const Icon(Icons.copy_rounded, size: 18),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          ],
          const SizedBox(height: 14),

          // Tarjeta: Ingresar con Código Familiar (primera descarga)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF111827),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFF1E293B)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Ingresar con Código Familiar',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Si el Titular de tu departamento te compartió un código, ingrésalo aquí sin usar datos técnicos.',
                  style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _inviteCodeCtrl,
                        textCapitalization: TextCapitalization.characters,
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        decoration: InputDecoration(
                          hintText: 'Ej: FAM-201-4829',
                          hintStyle: const TextStyle(color: Color(0xFF64748B)),
                          filled: true,
                          fillColor: const Color(0xFF090D16),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF059669),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: _familyLoading ? null : _joinWithFamilyCode,
                      child: const Text('Activar', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
                if (_familyError != null) ...[
                  const SizedBox(height: 8),
                  Text(_familyError!, style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 12)),
                ],
              ],
            ),
          ),

          // Tarjeta: Gestión de Familia (solo visible para el Titular)
          if (cfg != null && _familyRole == 'titular') ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF111827),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Mi Familia (Titular)',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.bold),
                      ),
                      Text(
                        '${_familyMembers.length} / 5',
                        style: const TextStyle(
                            color: Color(0xFF38BDF8),
                            fontSize: 12,
                            fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Designa hasta 5 personas de tu familia para atender el portero y quita permisos cuando quieras.',
                    style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                  ),
                  const SizedBox(height: 10),
                  if (_familyMembers.length < 5)
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _memberNameCtrl,
                            style: const TextStyle(color: Colors.white, fontSize: 13),
                            decoration: InputDecoration(
                              hintText: 'Nombre (ej: María, Lucas)',
                              hintStyle: const TextStyle(color: Color(0xFF64748B)),
                              filled: true,
                              fillColor: const Color(0xFF090D16),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF4F46E5),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed: _familyLoading ? null : _addFamilyMember,
                          child: const Text('+ Invitar', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  if (_familyMembers.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    ..._familyMembers.map((m) {
                      final code = m['code']?.toString() ?? '';
                      final name = m['name']?.toString() ?? 'Familiar';
                      final id = m['id']?.toString() ?? '';
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF090D16),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF1E293B)),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(name, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                                  Text('Código: $code', style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 11, fontFamily: 'monospace')),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Copiar código',
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: code));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Código $code copiado')),
                                );
                              },
                              icon: const Icon(Icons.copy_rounded, color: Colors.white70, size: 18),
                            ),
                            IconButton(
                              tooltip: 'Quitar permiso',
                              onPressed: _familyLoading ? null : () => _revokeFamilyMember(id),
                              icon: const Icon(Icons.delete_outline_rounded, color: Color(0xFFF87171), size: 20),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ],
              ),
            ),
          ],

          // Tarjeta de Configuración Manual SIP (solo visible para soporte técnico tras 5 toques en el título)
          if (_showTechSection) ...[
          const SizedBox(height: 14),
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF111827),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFF1E293B)),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.tune_rounded,
                      color: Color(0xFF818CF8)),
                  title: const Text(
                    'Configuración Manual SIP',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold),
                  ),
                  subtitle: const Text(
                    'Ingresar datos sin escanear código QR',
                    style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                  ),
                  trailing: Icon(
                    _showManualForm
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    color: Colors.white70,
                  ),
                  onTap: () =>
                      setState(() => _showManualForm = !_showManualForm),
                ),
                if (_showManualForm)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        children: [
                          _buildField(_extenCtrl, 'Interno / Departamento (ej: 101)',
                              Icons.apartment_rounded),
                          const SizedBox(height: 10),
                          TextFormField(
                            controller: _passCtrl,
                            obscureText: !_showPass,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              labelText: 'Contraseña SIP',
                              prefixIcon: const Icon(Icons.lock_outline_rounded,
                                  size: 20),
                              suffixIcon: IconButton(
                                icon: Icon(_showPass
                                    ? Icons.visibility_off
                                    : Icons.visibility),
                                onPressed: () =>
                                    setState(() => _showPass = !_showPass),
                              ),
                              filled: true,
                              fillColor: const Color(0xFF090D16),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            validator: (v) =>
                                (v == null || v.isEmpty) ? 'Requerida' : null,
                          ),
                          const SizedBox(height: 10),
                          _buildField(_hostCtrl, 'IP / Dominio VPS',
                              Icons.dns_rounded),
                          const SizedBox(height: 10),
                          _buildField(_wsCtrl, 'URL WebSocket (WSS)',
                              Icons.link_rounded),
                          const SizedBox(height: 10),
                          _buildField(_dtmfCtrl, 'Código DTMF de Puerta',
                              Icons.dialpad_rounded),
                          const SizedBox(height: 14),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF10B981),
                                foregroundColor: Colors.white,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              onPressed: _saveManual,
                              icon: const Icon(Icons.save_rounded),
                              label: const Text('Guardar y Conectar',
                                  style:
                                      TextStyle(fontWeight: FontWeight.bold)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          ],
          const SizedBox(height: 14),

          // Guía de Batería y Segundo Plano para sonar con pantalla apagada
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1B4B).withOpacity(0.4),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                  color: const Color(0xFF6366F1).withOpacity(0.35)),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.battery_saver_rounded,
                        color: Color(0xFFFBBF24), size: 22),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Para sonar siempre con pantalla apagada',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 10),
                Text(
                  '1. En Ajustes de Android -> Aplicaciones -> Portero IP -> Batería: elige "Sin restricciones".\n'
                  '2. Habilita "Inicio automático" en segundo plano.\n'
                  '3. Permite todas las notificaciones y pantalla completa.',
                  style: TextStyle(
                      color: Color(0xFFCBD5E1), fontSize: 12, height: 1.5),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withOpacity(0.08)),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.verified_user_rounded,
                        color: Color(0xFF38BDF8), size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Propiedad Intelectual & Descargo',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 8),
                Text(
                  '© 2026 valiente.tech — Todos los derechos reservados.\n'
                  'Esta aplicación y su código son propiedad exclusiva de valiente.tech. '
                  'Queda prohibida su copia, replicación, descompilación o redistribución no autorizada.\n\n'
                  'Descargo de responsabilidad: El servicio se brinda "tal cual", sujeto a la conectividad de red, energía eléctrica y hardware del edificio. '
                  'valiente.tech no asume responsabilidad por daños directos o indirectos derivados del uso o interrupciones del servicio.',
                  style: TextStyle(
                      color: Color(0xFF94A3B8), fontSize: 11.5, height: 1.45),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildField(
      TextEditingController ctrl, String label, IconData icon) {
    return TextFormField(
      controller: ctrl,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, size: 20),
        filled: true,
        fillColor: const Color(0xFF090D16),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
      validator: (v) => (v == null || v.isEmpty) ? 'Campo requerido' : null,
    );
  }
}

class _DiagRow extends StatelessWidget {
  final String label;
  final String value;

  const _DiagRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12)),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
