import 'dart:io';

import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../domain/models.dart';
import '../domain/pose_logic.dart';

/// Aligned before/after with a drag slider. The "after" photo is scaled and
/// shifted onto the "before" torso so the comparison is honest.
class MorphSlider extends StatefulWidget {
  const MorphSlider({
    super.key,
    required this.before,
    required this.after,
    this.beforeLabel = 'Before',
    this.afterLabel = 'After',
    this.aligned = true,
  });
  final CheckinPhoto before;
  final CheckinPhoto after;
  final String beforeLabel;
  final String afterLabel;
  final bool aligned;

  @override
  State<MorphSlider> createState() => _MorphSliderState();
}

class _MorphSliderState extends State<MorphSlider> {
  double _t = 0.5;

  @override
  Widget build(BuildContext context) {
    final a = widget.aligned
        ? Alignment2D.between(widget.before.landmarks, widget.after.landmarks)
        : Alignment2D.identity;
    return AspectRatio(
      aspectRatio: 3 / 4,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Brand.radius),
        child: LayoutBuilder(
          builder: (context, c) {
            final w = c.maxWidth, h = c.maxHeight;
            return GestureDetector(
              onHorizontalDragUpdate: (d) =>
                  setState(() => _t = (d.localPosition.dx / w).clamp(0.0, 1.0)),
              onTapDown: (d) =>
                  setState(() => _t = (d.localPosition.dx / w).clamp(0.0, 1.0)),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _photo(widget.before),
                  ClipRect(
                    clipper: _LeftClip(_t),
                    child: Transform(
                      transform: Matrix4.identity()
                        ..translateByDouble(a.dx * w, a.dy * h, 0, 1)
                        ..scaleByDouble(a.scale, a.scale, 1, 1),
                      child: _photo(widget.after),
                    ),
                  ),
                  Positioned(
                    left: _t * w - 1.5,
                    top: 0,
                    bottom: 0,
                    child: Container(width: 3, color: Colors.white),
                  ),
                  Positioned(
                    left: _t * w - 18,
                    top: h / 2 - 18,
                    child: const CircleAvatar(
                      radius: 18,
                      backgroundColor: Colors.white,
                      child: Icon(Icons.compare_arrows, color: Brand.ink),
                    ),
                  ),
                  _label(widget.afterLabel, left: 8),
                  _label(widget.beforeLabel, right: 8),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  static Widget _photo(CheckinPhoto p) => File(p.localPath).existsSync()
      ? Image.file(File(p.localPath), fit: BoxFit.cover)
      : Container(
          color: Brand.card2,
          child: const Icon(Icons.image_not_supported, color: Brand.slate),
        );

  static Widget _label(String t, {double? left, double? right}) => Positioned(
    left: left,
    right: right,
    bottom: 8,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Brand.ink.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        t,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
      ),
    ),
  );
}

/// Shows the "after" image only left of the slider.
class _LeftClip extends CustomClipper<Rect> {
  _LeftClip(this.t);
  final double t;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width * t, size.height);

  @override
  bool shouldReclip(_LeftClip old) => old.t != t;
}

/// Free-tier manual side-by-side (no AI, no alignment).
class SideBySide extends StatelessWidget {
  const SideBySide({
    super.key,
    required this.left,
    required this.right,
    required this.leftLabel,
    required this.rightLabel,
  });
  final CheckinPhoto left;
  final CheckinPhoto right;
  final String leftLabel;
  final String rightLabel;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (final (p, l) in [(left, leftLabel), (right, rightLabel)])
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: Column(
              children: [
                AspectRatio(
                  aspectRatio: 3 / 4,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: File(p.localPath).existsSync()
                        ? Image.file(File(p.localPath), fit: BoxFit.cover)
                        : Container(color: Brand.card2),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l,
                  style: const TextStyle(color: Brand.textDim, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
    ],
  );
}
