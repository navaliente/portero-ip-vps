import 'package:flutter/material.dart';

class BrandAppLogo extends StatelessWidget {
  final double size;
  final bool showGlow;

  const BrandAppLogo({super.key, this.size = 44, this.showGlow = true});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.28),
        boxShadow: showGlow
            ? [
                BoxShadow(
                  color: const Color(0xFF6366F1).withOpacity(0.35),
                  blurRadius: 18,
                  spreadRadius: 1,
                ),
                BoxShadow(
                  color: const Color(0xFF06B6D4).withOpacity(0.20),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ]
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.asset(
        'assets/icon/app_icon.png',
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          color: const Color(0xFF1E293B),
          child: Icon(Icons.doorbell_rounded,
              color: const Color(0xFF38BDF8), size: size * 0.6),
        ),
      ),
    );
  }
}

class PulsingStatusBadge extends StatefulWidget {
  final bool isOnline;
  final String onlineLabel;
  final String offlineLabel;

  const PulsingStatusBadge({
    super.key,
    required this.isOnline,
    this.onlineLabel = 'CONECTADO',
    this.offlineLabel = 'RECONECTANDO',
  });

  @override
  State<PulsingStatusBadge> createState() => _PulsingStatusBadgeState();
}

class _PulsingStatusBadgeState extends State<PulsingStatusBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final baseColor =
        widget.isOnline ? const Color(0xFF10B981) : const Color(0xFFF59E0B);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: baseColor.withOpacity(0.14),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: baseColor.withOpacity(0.45), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _ctrl,
            builder: (_, __) {
              return Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: baseColor.withOpacity(0.55 + _ctrl.value * 0.45),
                  boxShadow: [
                    BoxShadow(
                      color: baseColor.withOpacity(0.6 * _ctrl.value),
                      blurRadius: 6,
                      spreadRadius: 2 * _ctrl.value,
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(width: 6),
          Text(
            widget.isOnline ? widget.onlineLabel : widget.offlineLabel,
            style: TextStyle(
              color: baseColor,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}

class RadarRingVisualizer extends StatefulWidget {
  final Color color;
  final Widget child;

  const RadarRingVisualizer({
    super.key,
    required this.color,
    required this.child,
  });

  @override
  State<RadarRingVisualizer> createState() => _RadarRingVisualizerState();
}

class _RadarRingVisualizerState extends State<RadarRingVisualizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 170,
      height: 170,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: _ctrl,
            builder: (_, __) {
              return CustomPaint(
                size: const Size(170, 170),
                painter: _RadarPainter(_ctrl.value, widget.color),
              );
            },
          ),
          widget.child,
        ],
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  final double progress;
  final Color color;

  _RadarPainter(this.progress, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = size.width / 2;

    for (int i = 0; i < 3; i++) {
      final p = (progress + i / 3) % 1.0;
      final r = maxR * 0.4 + p * (maxR * 0.6);
      final opacity = (1.0 - p) * 0.45;
      final paint = Paint()
        ..color = color.withOpacity(opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2;
      canvas.drawCircle(center, r, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RadarPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class ScannerCornersPainter extends CustomPainter {
  final Color color;

  ScannerCornersPainter({this.color = const Color(0xFF38BDF8)});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round;

    const len = 34.0;
    const r = 16.0;
    final w = size.width;
    final h = size.height;

    // Top-left
    canvas.drawPath(
      Path()
        ..moveTo(0, len)
        ..lineTo(0, r)
        ..quadraticBezierTo(0, 0, r, 0)
        ..lineTo(len, 0),
      paint,
    );
    // Top-right
    canvas.drawPath(
      Path()
        ..moveTo(w - len, 0)
        ..lineTo(w - r, 0)
        ..quadraticBezierTo(w, 0, w, r)
        ..lineTo(w, len),
      paint,
    );
    // Bottom-left
    canvas.drawPath(
      Path()
        ..moveTo(0, h - len)
        ..lineTo(0, h - r)
        ..quadraticBezierTo(0, h, r, h)
        ..lineTo(len, h),
      paint,
    );
    // Bottom-right
    canvas.drawPath(
      Path()
        ..moveTo(w - len, h)
        ..lineTo(w - r, h)
        ..quadraticBezierTo(w, h, w, h - r)
        ..lineTo(w, h - len),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
