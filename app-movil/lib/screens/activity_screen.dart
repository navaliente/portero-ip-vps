import 'package:flutter/material.dart';

import '../models/intercom_models.dart';
import '../services/intercom_service.dart';

class ActivityScreen extends StatelessWidget {
  final IntercomService svc;

  const ActivityScreen({super.key, required this.svc});

  String _formatDateTime(DateTime dt) {
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$d/$m • $h:$min';
  }

  @override
  Widget build(BuildContext context) {
    final items = svc.history;

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Registro de Actividad',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Timbres, aperturas remotas y vistas de cámara',
                    style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                  ),
                ],
              ),
              if (items.isNotEmpty)
                TextButton.icon(
                  onPressed: svc.clearHistory,
                  icon: const Icon(Icons.delete_sweep_rounded,
                      size: 18, color: Color(0xFF94A3B8)),
                  label: const Text('Limpiar',
                      style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12)),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: const Color(0xFF111827),
                            shape: BoxShape.circle,
                            border: Border.all(color: const Color(0xFF1E293B)),
                          ),
                          child: const Icon(Icons.history_rounded,
                              color: Color(0xFF475569), size: 42),
                        ),
                        const SizedBox(height: 14),
                        const Text(
                          'Sin eventos recientes',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Cuando alguien toque timbre o abras la puerta\nquedará registrado aquí.',
                          textAlign: TextAlign.center,
                          style:
                              TextStyle(color: Color(0xFF64748B), fontSize: 13),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.only(bottom: 20),
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, index) {
                      final e = items[index];
                      final style = _styleForEvent(e.type);
                      return Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFF111827),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFF1E293B)),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: style.color.withOpacity(0.14),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                    color: style.color.withOpacity(0.35)),
                              ),
                              child: Icon(style.icon,
                                  color: style.color, size: 22),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    e.title,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    e.subtitle,
                                    style: const TextStyle(
                                      color: Color(0xFF94A3B8),
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _formatDateTime(e.timestamp),
                              style: const TextStyle(
                                color: Color(0xFF64748B),
                                fontSize: 11,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  ({IconData icon, Color color}) _styleForEvent(AccessEventType type) {
    switch (type) {
      case AccessEventType.doorUnlocked:
        return (icon: Icons.lock_open_rounded, color: const Color(0xFF10B981));
      case AccessEventType.ringAnswered:
        return (
          icon: Icons.notifications_active_rounded,
          color: const Color(0xFF38BDF8)
        );
      case AccessEventType.ringMissed:
        return (
          icon: Icons.phone_missed_rounded,
          color: const Color(0xFFF43F5E)
        );
      case AccessEventType.cameraMonitor:
        return (icon: Icons.videocam_rounded, color: const Color(0xFF818CF8));
      case AccessEventType.ringIncoming:
        return (icon: Icons.doorbell_rounded, color: const Color(0xFFF59E0B));
    }
  }
}
