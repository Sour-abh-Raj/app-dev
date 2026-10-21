import 'dart:math' as math;
import 'dart:ui';

/// Normalised (0-1) landmark positions keyed by short names:
/// nose, l_eye, r_eye, l_ear, r_ear, l_shoulder, r_shoulder, l_hip, r_hip,
/// l_ankle, r_ankle.
typedef Landmarks = Map<String, Offset>;

class PoseHint {
  const PoseHint(this.ready, this.message);
  final bool ready;
  final String message;
}

/// Pose-guide hints shown over the camera (ML Kit runs on-device; this is the
/// pure decision logic so it can be unit-tested).
class PoseHints {
  const PoseHints._();

  static Offset? _mid(Landmarks lm, String a, String b) {
    final pa = lm[a], pb = lm[b];
    if (pa == null || pb == null) return null;
    return Offset((pa.dx + pb.dx) / 2, (pa.dy + pb.dy) / 2);
  }

  static PoseHint evaluate(Landmarks? lm, String angle) {
    if (lm == null || lm.length < 5) {
      return const PoseHint(false, 'Step into the frame — head to ankles');
    }
    final head = lm['nose'] ?? _mid(lm, 'l_ear', 'r_ear');
    final ankles =
        _mid(lm, 'l_ankle', 'r_ankle') ?? lm['l_ankle'] ?? lm['r_ankle'];
    final hips = _mid(lm, 'l_hip', 'r_hip') ?? lm['l_hip'] ?? lm['r_hip'];
    final shoulders =
        _mid(lm, 'l_shoulder', 'r_shoulder') ??
        lm['l_shoulder'] ??
        lm['r_shoulder'];
    if (head == null || ankles == null || hips == null || shoulders == null) {
      return const PoseHint(
        false,
        'Step back so your head and feet are in frame',
      );
    }
    if (head.dy < 0.04 || ankles.dy > 0.97) {
      return const PoseHint(
        false,
        'Step back so your head and feet are in frame',
      );
    }
    final height = ankles.dy - head.dy;
    if (height < 0.55) return const PoseHint(false, 'Move a little closer');
    if (hips.dx < 0.38)
      return const PoseHint(false, 'Move right to center yourself');
    if (hips.dx > 0.62)
      return const PoseHint(false, 'Move left to center yourself');

    final ls = lm['l_shoulder'], rs = lm['r_shoulder'];
    if (ls != null && rs != null) {
      final widthRatio = (ls.dx - rs.dx).abs() / height;
      if (angle == 'side' && widthRatio > 0.14) {
        return const PoseHint(false, 'Turn 90° to show your side');
      }
      if (angle != 'side' && widthRatio < 0.12) {
        return PoseHint(
          false,
          angle == 'back'
              ? 'Face away, square to the camera'
              : 'Face the camera square-on',
        );
      }
      if (angle != 'side' && (ls.dy - rs.dy).abs() > 0.04) {
        return const PoseHint(false, 'Hold the phone upright and level');
      }
    }
    return const PoseHint(true, 'Perfect — hold still');
  }

  /// Face region to blur (normalised rect), from face landmarks.
  static Rect? faceRect(Landmarks lm) {
    final pts = [
      'nose',
      'l_eye',
      'r_eye',
      'l_ear',
      'r_ear',
    ].map((k) => lm[k]).whereType<Offset>().toList();
    if (pts.length < 2) return null;
    final xs = pts.map((p) => p.dx), ys = pts.map((p) => p.dy);
    final cx = (xs.reduce(math.min) + xs.reduce(math.max)) / 2;
    final cy = (ys.reduce(math.min) + ys.reduce(math.max)) / 2;
    final ls = lm['l_shoulder'], rs = lm['r_shoulder'];
    final span = ls != null && rs != null
        ? (ls.dx - rs.dx).abs() * 0.75
        : (xs.reduce(math.max) - xs.reduce(math.min)) * 2.2;
    final size = math.max(span, 0.08);
    return Rect.fromCenter(
      center: Offset(cx, cy - size * 0.05),
      width: size,
      height: size * 1.3,
    );
  }
}

/// Similarity transform aligning a current photo onto a baseline photo using
/// the torso (shoulder-mid → hip-mid), so before/after line up in the morph.
class Alignment2D {
  const Alignment2D(this.scale, this.dx, this.dy);
  final double scale;
  final double dx; // normalised translation applied after scaling
  final double dy;

  static const identity = Alignment2D(1, 0, 0);

  static Alignment2D between(
    Map<String, double>? base,
    Map<String, double>? cur,
  ) {
    if (base == null || cur == null) return identity;
    final b1 = Offset(base['sx'] ?? 0, base['sy'] ?? 0),
        b2 = Offset(base['hx'] ?? 0, base['hy'] ?? 0);
    final c1 = Offset(cur['sx'] ?? 0, cur['sy'] ?? 0),
        c2 = Offset(cur['hx'] ?? 0, cur['hy'] ?? 0);
    final bl = (b2 - b1).distance, cl = (c2 - c1).distance;
    if (bl < 0.02 || cl < 0.02) return identity;
    final s = (bl / cl).clamp(0.5, 2.0);
    return Alignment2D(s, b1.dx - c1.dx * s, b1.dy - c1.dy * s);
  }

  /// Compact landmarks stored with each check-in photo.
  static Map<String, double>? torso(Landmarks? lm) {
    if (lm == null) return null;
    final s = PoseHints._mid(lm, 'l_shoulder', 'r_shoulder');
    final h = PoseHints._mid(lm, 'l_hip', 'r_hip');
    if (s == null || h == null) return null;
    return {'sx': s.dx, 'sy': s.dy, 'hx': h.dx, 'hy': h.dy};
  }
}
