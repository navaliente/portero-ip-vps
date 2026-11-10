import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:sip_ua/sip_ua.dart';

import '../services/intercom_service.dart';
import '../widgets/brand_graphics.dart';

class ActiveCallScreen extends StatelessWidget {
  final IntercomService svc;

  const ActiveCallScreen({super.key, required this.svc});

  void _showDtmfKeypad(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) {
        const keys = [
          '1', '2', '3',
          '4', '5', '6',
          '7', '8', '9',
          '*', '0', '#',
        ];
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFF334155),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Teclado de Relés / Tonos DTMF',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Usa # para puerta principal o * / 0 para portón secundario',
                style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
              ),
              const SizedBox(height: 18),
              GridView.count(
                shrinkWrap: true,
                crossAxisCount: 3,
                mainAxisSpacing: 10,
                crossAxisSpacing: 12,
                childAspectRatio: 1.85,
                children: keys.map((k) {
                  final isUnlock = k == (svc.config?.dtmfUnlock ?? '#');
                  return ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isUnlock
                          ? const Color(0xFF059669)
                          : const Color(0xFF1E293B),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(
                          color: isUnlock
                              ? const Color(0xFF34D399)
                              : const Color(0xFF334155),
                        ),
                      ),
                    ),
                    onPressed: () {
                      svc.unlockDoor(customCode: k);
                      Navigator.pop(context);
                    },
                    child: Text(
                      k,
                      style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.bold),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isRinging = svc.isIncomingRinging;
    final maxSecs = svc.config?.maxCallSeconds ?? 300;
    final maxMin = (maxSecs ~/ 60).toString().padLeft(2, '0');
    final maxRem = (maxSecs % 60).toString().padLeft(2, '0');
    final isConnecting = svc.callState == CallStateEnum.CONNECTING ||
        svc.callState == CallStateEnum.CALL_INITIATION;

    return Column(
      children: [
        // Visor de Video HD
        Expanded(
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            decoration: BoxDecoration(
              color: const Color(0xFF030712),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: isRinging
                    ? const Color(0xFF10B981)
                    : const Color(0xFF1E293B),
                width: isRinging ? 2.2 : 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.55),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Video remoto H.264
                RTCVideoView(
                  svc.remoteRenderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),

                // Estado mientras suena el timbre entrante
                if (isRinging)
                  Container(
                    color: const Color(0xCC090D16),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const RadarRingVisualizer(
                          color: Color(0xFF10B981),
                          child: BrandAppLogo(size: 76),
                        ),
                        const SizedBox(height: 18),
                        const Text(
                          'TIMBRE DE ENTRADA PRINCIPAL',
                          style: TextStyle(
                            color: Color(0xFF34D399),
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.4,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          svc.config?.buildingName ?? 'Portero KD9203 (8000)',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Toca "Atender" para ver la cámara y hablar',
                          style:
                              TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                        ),
                      ],
                    ),
                  )
                else if (isConnecting && svc.remoteRenderer.srcObject == null)
                  const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(color: Color(0xFF38BDF8)),
                        SizedBox(height: 14),
                        Text(
                          'Conectando cámara H.264 del frente...',
                          style:
                              TextStyle(color: Color(0xFFCBD5E1), fontSize: 14),
                        ),
                      ],
                    ),
                  ),

                // Barra superior translúcida sobre el video
                Positioned(
                  top: 14,
                  left: 14,
                  right: 14,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.65),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.fiber_manual_record,
                              color: isRinging
                                  ? const Color(0xFF10B981)
                                  : Colors.redAccent,
                              size: 12,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              isRinging
                                  ? 'LLAMADA ENTRANTE'
                                  : 'KD9203 • H.264 EN VIVO',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (!isRinging)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.65),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.white12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.timer_outlined,
                                  color: Color(0xFF38BDF8), size: 14),
                              const SizedBox(width: 4),
                              Text(
                                '${svc.formattedCallDuration} / $maxMin:$maxRem',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),

                // Confirmación visual gigante al abrir la puerta
                if (svc.isDoorUnlockedFeedback)
                  Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 26, vertical: 18),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xEE059669), Color(0xEE10B981)],
                        ),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF10B981).withOpacity(0.5),
                            blurRadius: 24,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.lock_open_rounded,
                              color: Colors.white, size: 34),
                          const SizedBox(width: 12),
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '¡PUERTA DESTRABADA!',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                ),
                              ),
                              Text(
                                'Pulso DTMF (${svc.lastUnlockedCode ?? "#"}) enviado',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFFD1FAE5),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),

        // Dock inferior de controles de Videoportero
        Container(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 26),
          decoration: const BoxDecoration(
            color: Color(0xFF111827),
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(top: BorderSide(color: Color(0xFF1E293B), width: 1.5)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Botón principal gigante de Apertura de Puerta (#)
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  gradient: const LinearGradient(
                    colors: [Color(0xFF059669), Color(0xFF10B981)],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF10B981).withOpacity(0.35),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 17),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  onPressed: () => svc.unlockDoor(),
                  icon: const Icon(Icons.key_rounded, size: 26),
                  label: Text(
                    'ABRIR PUERTA PRINCIPAL (${svc.config?.dtmfUnlock ?? "#"})',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Fila de controles multimedia
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  if (isRinging)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF4F46E5),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          onPressed: svc.answerIncomingCall,
                          icon: const Icon(Icons.videocam_rounded),
                          label: const Text(
                            'Atender Video',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    )
                  else ...[
                    _DockActionButton(
                      icon: svc.isMicMuted ? Icons.mic_off : Icons.mic_rounded,
                      label: svc.isMicMuted ? 'Silenciado' : 'Hablar',
                      active: !svc.isMicMuted,
                      activeColor: const Color(0xFF38BDF8),
                      onTap: svc.toggleMute,
                    ),
                    _DockActionButton(
                      icon: svc.isSpeakerOn
                          ? Icons.volume_up_rounded
                          : Icons.hearing_rounded,
                      label: svc.isSpeakerOn ? 'Altavoz' : 'Auricular',
                      active: svc.isSpeakerOn,
                      activeColor: const Color(0xFF6366F1),
                      onTap: svc.toggleSpeaker,
                    ),
                    _DockActionButton(
                      icon: Icons.dialpad_rounded,
                      label: 'Teclado',
                      active: false,
                      activeColor: const Color(0xFF6366F1),
                      onTap: () => _showDtmfKeypad(context),
                    ),
                  ],
                  _DockActionButton(
                    icon: Icons.call_end_rounded,
                    label: isRinging ? 'Rechazar' : 'Cortar',
                    active: true,
                    activeColor: const Color(0xFFEF4444),
                    forceBg: const Color(0xFFDC2626),
                    onTap: svc.hangup,
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

class _DockActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final Color activeColor;
  final Color? forceBg;
  final VoidCallback onTap;

  const _DockActionButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.activeColor,
    required this.onTap,
    this.forceBg,
  });

  @override
  Widget build(BuildContext context) {
    final bg = forceBg ??
        (active ? activeColor.withOpacity(0.18) : const Color(0xFF1E293B));
    final fg = forceBg != null
        ? Colors.white
        : (active ? activeColor : const Color(0xFF94A3B8));

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: forceBg != null
                    ? Colors.transparent
                    : (active
                        ? activeColor.withOpacity(0.5)
                        : const Color(0xFF334155)),
              ),
            ),
            child: Icon(icon, color: fg, size: 24),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFFCBD5E1),
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
