import 'package:flutter/material.dart';

import '../app/theme.dart';

/// Minimal line chart (weight trend, PR history). No chart dependency.
class LineChart extends StatelessWidget {
  const LineChart({
    super.key,
    required this.points,
    this.height = 140,
    this.unit = '',
    this.semanticsLabel,
  });
  final List<(DateTime, double)> points;
  final double height;
  final String unit;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    if (points.length < 2) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(
            points.isEmpty ? 'No data yet' : 'One more entry to see a trend',
            style: const TextStyle(color: Brand.slate),
          ),
        ),
      );
    }
    final last = points.last.$2;
    return Semantics(
      label:
          semanticsLabel ??
          'Trend chart, latest ${last.toStringAsFixed(1)}$unit',
      child: SizedBox(
        height: height,
        child: CustomPaint(
          painter: _LinePainter(points, unit),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter(this.points, this.unit);
  final List<(DateTime, double)> points;
  final String unit;

  @override
  void paint(Canvas canvas, Size size) {
    final xs = points
        .map((p) => p.$1.millisecondsSinceEpoch.toDouble())
        .toList();
    final ys = points.map((p) => p.$2).toList();
    final minX = xs.first, maxX = xs.last;
    var minY = ys.reduce((a, b) => a < b ? a : b),
        maxY = ys.reduce((a, b) => a > b ? a : b);
    if ((maxY - minY).abs() < 1e-6) {
      minY -= 1;
      maxY += 1;
    }
    const pad = 18.0;
    Offset at(int i) => Offset(
      pad +
          (xs[i] - minX) /
              (maxX - minX == 0 ? 1 : maxX - minX) *
              (size.width - 2 * pad),
      pad + (1 - (ys[i] - minY) / (maxY - minY)) * (size.height - 2 * pad),
    );
    final grid = Paint()
      ..color = Brand.track
      ..strokeWidth = 1;
    for (var g = 0; g < 3; g++) {
      final y = pad + g * (size.height - 2 * pad) / 2;
      canvas.drawLine(Offset(pad, y), Offset(size.width - pad, y), grid);
    }
    final path = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < points.length; i++) {
      path.lineTo(at(i).dx, at(i).dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..shader = Brand.progressGradient.createShader(Offset.zero & size)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
    final dot = Paint()..color = Brand.lime;
    for (var i = 0; i < points.length; i++) {
      canvas.drawCircle(at(i), i == points.length - 1 ? 5 : 3, dot);
    }
    final tp = TextPainter(
      text: TextSpan(
        text: '${ys.last.toStringAsFixed(1)}$unit',
        style: const TextStyle(
          color: Brand.text,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final lastPt = at(points.length - 1);
    tp.paint(
      canvas,
      Offset(
        (lastPt.dx - tp.width).clamp(0, size.width - tp.width),
        lastPt.dy - 20 < 0 ? lastPt.dy + 6 : lastPt.dy - 20,
      ),
    );
  }

  @override
  bool shouldRepaint(_LinePainter old) => old.points != points;
}
