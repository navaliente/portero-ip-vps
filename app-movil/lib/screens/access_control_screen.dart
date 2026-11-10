import 'package:flutter/material.dart';

import '../services/intercom_service.dart';

class AccessControlScreen extends StatelessWidget {
  final IntercomService svc;

  const AccessControlScreen({super.key, required this.svc});

  @override
  Widget build(BuildContext context) {
    final exten = svc.config?.exten ?? '---';
    final online = svc.isRegistered;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Accesos y Biometría',
            style: TextStyle(
                color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            'Funciones inteligentes integradas en el frente DS-KD9203-ME6',
            style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
          ),
          const SizedBox(height: 16),

          // Tarjeta Reconocimiento Facial 3D
          _FeatureStatusCard(
            icon: Icons.face_retouching_natural_rounded,
            accentColor: const Color(0xFF38BDF8),
            title: 'Reconocimiento Facial 3D',
            badge: 'LISTO EN EQUIPO',
            description:
                'Tu frente de calle cuenta con cámara dual infrarroja y algoritmo Deep Learning Anti-Spoofing (no se engaña con fotos ni pantallas).',
            bullets: [
              'Velocidad de apertura: < 0.2 segundos al acercarte a la puerta.',
              'Capacidad del edificio: hasta 10.000 rostros almacenados.',
              'Enrolamiento: El administrador puede capturar tu rostro en vivo frente al portero o subir una foto desde la consola del edificio.',
            ],
          ),
          const SizedBox(height: 14),

          // Tarjeta Llave Digital Remota (DTMF)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF064E3B).withOpacity(0.55),
                  const Color(0xFF111827),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                  color: const Color(0xFF10B981).withOpacity(0.45)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981).withOpacity(0.2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.key_rounded,
                          color: Color(0xFF34D399), size: 24),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Llave Digital desde Celular',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.bold),
                          ),
                          Text(
                            'Departamento $exten • Código DTMF "${svc.config?.dtmfUnlock ?? "#"}"',
                            style: const TextStyle(
                                color: Color(0xFF6EE7B7), fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981).withOpacity(0.2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        'ACTIVO',
                        style: TextStyle(
                            color: Color(0xFF34D399),
                            fontSize: 10,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'Abre la puerta desde cualquier lugar con datos móviles o Wi-Fi al atender el timbre o al abrir la cámara en vivo.',
                  style: TextStyle(
                      color: Color(0xFFCBD5E1), fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF10B981),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: const Color(0xFF1E293B),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: online ? svc.monitorDoorCamera : null,
                    icon: const Icon(Icons.videocam_rounded, size: 20),
                    label: const Text(
                      'Abrir Cámara y Destrabar Puerta',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Tarjeta Tarjetas Mifare & QR
          const _FeatureStatusCard(
            icon: Icons.contactless_rounded,
            accentColor: Color(0xFFA78BFA),
            title: 'Tarjetas Mifare y Pases QR',
            badge: 'COMPATIBLE',
            description:
                'El lector frontal del KD9203 admite llaveros RFID Mifare 13.56MHz, NFC y lectura óptica de códigos QR de invitados.',
            bullets: [
              'Pases temporales con vencimiento para visitas o delivery.',
              'Auditoría completa con fotografía automática en cada apertura.',
            ],
          ),
        ],
      ),
    );
  }
}

class _FeatureStatusCard extends StatelessWidget {
  final IconData icon;
  final Color accentColor;
  final String title;
  final String badge;
  final String description;
  final List<String> bullets;

  const _FeatureStatusCard({
    required this.icon,
    required this.accentColor,
    required this.title,
    required this.badge,
    required this.description,
    required this.bullets,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
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
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: accentColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: accentColor, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: accentColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: accentColor.withOpacity(0.35)),
                ),
                child: Text(
                  badge,
                  style: TextStyle(
                      color: accentColor,
                      fontSize: 10,
                      fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            description,
            style: const TextStyle(
                color: Color(0xFFCBD5E1), fontSize: 13, height: 1.45),
          ),
          const SizedBox(height: 10),
          ...bullets.map(
            (b) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Icon(Icons.check_circle_rounded,
                        size: 14, color: accentColor),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      b,
                      style: const TextStyle(
                          color: Color(0xFF94A3B8), fontSize: 12, height: 1.35),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
