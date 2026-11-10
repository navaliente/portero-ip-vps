import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../widgets/brand_graphics.dart';

class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _scanned = false;
  bool _torchOn = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF090D16),
      appBar: AppBar(
        backgroundColor: const Color(0xFF111827),
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Vincular Departamento (QR)',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            tooltip: 'Linterna',
            icon: Icon(
              _torchOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
              color: _torchOn ? const Color(0xFFFBBF24) : Colors.white70,
            ),
            onPressed: () {
              _controller.toggleTorch();
              setState(() => _torchOn = !_torchOn);
            },
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: (capture) {
              if (_scanned) return;
              for (final barcode in capture.barcodes) {
                final val = barcode.rawValue;
                if (val != null && val.startsWith('http')) {
                  _scanned = true;
                  Navigator.of(context).pop(val);
                  break;
                }
              }
            },
          ),
          // Marco central de escaneo
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 240,
                  height: 240,
                  child: CustomPaint(
                    painter: ScannerCornersPainter(
                      color: const Color(0xFF38BDF8),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.65),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: const Color(0xFF38BDF8).withOpacity(0.4),
                    ),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.qr_code_2_rounded,
                          color: Color(0xFF38BDF8), size: 18),
                      SizedBox(width: 8),
                      Text(
                        'Encuadra el código QR dentro del marco',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A).withOpacity(0.92),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFF1E293B)),
              ),
              child: const Text(
                'Abre el Panel Web del Edificio y selecciona "Código QR -> App Portero Edificio" para vincular tu departamento automáticamente.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Color(0xFFCBD5E1), fontSize: 13, height: 1.4),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
