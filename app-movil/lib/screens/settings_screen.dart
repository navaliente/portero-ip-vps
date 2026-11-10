import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  bool _showPass = false;
  bool _showManualForm = false;

  @override
  void initState() {
    super.initState();
    _syncControllers();
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
          const Text(
            'Ajustes y Vinculación',
            style: TextStyle(
                color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            'Conexión con servidor VPS, notificaciones y energía',
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
                _DiagRow('Departamento', cfg?.exten ?? 'No asignado'),
                _DiagRow('Servidor VPS', cfg?.sipHost ?? '---'),
                _DiagRow('WebSocket SIP', cfg?.wsUrl ?? '---'),
                _DiagRow('Duración Máxima', '${cfg?.maxCallSeconds ?? 300}s (5 min)'),
                _DiagRow(
                  'Notificaciones Push',
                  token != null ? 'Token FCM Activo' : 'Modo SIP Directo',
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
          const SizedBox(height: 14),

          // Tarjeta de Configuración Manual SIP
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
