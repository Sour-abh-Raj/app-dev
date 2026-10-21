import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../domain/models.dart';
import '../../domain/pose_logic.dart';
import '../../widgets/common.dart';

const angles = ['front', 'side', 'back'];

String angleLabel(String a) => switch (a) {
  'front' => 'Front',
  'side' => 'Side',
  _ => 'Back',
};

/// Captures front → side → back with the pose guide. Returns the processed,
/// privately stored photos (EXIF stripped, optional face blur, ≤2048 px).
class PhotoSetCapture extends ConsumerStatefulWidget {
  const PhotoSetCapture({
    super.key,
    required this.checkinId,
    required this.onDone,
    this.initial = const [],
  });
  final String checkinId;
  final List<CheckinPhoto> initial;
  final ValueChanged<List<CheckinPhoto>> onDone;

  @override
  ConsumerState<PhotoSetCapture> createState() => _PhotoSetCaptureState();
}

class _PhotoSetCaptureState extends ConsumerState<PhotoSetCapture> {
  late final List<CheckinPhoto> _photos = [...widget.initial];

  String? get _next {
    for (final a in angles) {
      if (!_photos.any((p) => p.angle == a)) return a;
    }
    return null;
  }

  Future<void> _capture(String angle) async {
    final photo = await Navigator.of(context).push<CheckinPhoto>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) =>
            CameraCaptureScreen(checkinId: widget.checkinId, angle: angle),
      ),
    );
    if (photo == null) return;
    setState(() {
      _photos.removeWhere((p) => p.angle == angle);
      _photos.add(photo);
    });
  }

  @override
  Widget build(BuildContext context) {
    final next = _next;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            for (final a in angles)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: _Slot(
                    angle: a,
                    photo: _photos.where((p) => p.angle == a).firstOrNull,
                    onTap: () => _capture(a),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        const PrivacyNote(
          text: 'Encrypted, never public. Stored privately; face blur is on by default.',
        ),
        const SizedBox(height: 16),
        if (next != null)
          FilledButton.icon(
            onPressed: () => _capture(next),
            icon: const Icon(Icons.camera_alt),
            label: Text('Take ${angleLabel(next).toLowerCase()} photo'),
          )
        else
          FilledButton(
            onPressed: () => widget.onDone(_photos),
            child: const Text('Use these photos'),
          ),
      ],
    );
  }
}

class _Slot extends StatelessWidget {
  const _Slot({required this.angle, required this.photo, required this.onTap});
  final String angle;
  final CheckinPhoto? photo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: 3 / 4,
    child: BrandCard(
      padding: 0,
      onTap: onTap,
      border: photo != null ? Brand.lime : null,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (photo != null && File(photo!.localPath).existsSync())
            Image.file(File(photo!.localPath), fit: BoxFit.cover)
          else
            const Icon(Icons.accessibility_new, size: 42, color: Brand.slate),
          Positioned(
            left: 8,
            bottom: 6,
            child: Text(
              photo != null ? '${angleLabel(angle)} ✓' : angleLabel(angle),
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: photo != null ? Brand.lime : Brand.text,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Full-screen camera with silhouette overlay and live ML Kit hints.
class CameraCaptureScreen extends ConsumerStatefulWidget {
  const CameraCaptureScreen({
    super.key,
    required this.checkinId,
    required this.angle,
  });
  final String checkinId;
  final String angle;

  @override
  ConsumerState<CameraCaptureScreen> createState() =>
      _CameraCaptureScreenState();
}

class _CameraCaptureScreenState extends ConsumerState<CameraCaptureScreen> {
  CameraController? _cam;
  PoseDetector? _detector;
  PoseHint _hint = const PoseHint(
    false,
    'Step into the frame — head to ankles',
  );
  bool _busy = false;
  bool _processing = false;
  String? _error;
  int _frame = 0;
  int? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) throw CameraException('none', 'No camera');
      // Back camera by default: a friend or a tripod gives the best alignment.
      final cam = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cams.first,
      );
      final ctrl = CameraController(
        cam,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.nv21
            : ImageFormatGroup.bgra8888,
      );
      await ctrl.initialize();
      _detector = PoseDetector(
        options: PoseDetectorOptions(mode: PoseDetectionMode.stream),
      );
      await ctrl.startImageStream((img) => _onFrame(img, cam));
      if (!mounted) return;
      setState(() => _cam = ctrl);
    } catch (e) {
      if (mounted)
        setState(
          () => _error = 'Camera unavailable — you can pick a photo instead.',
        );
    }
  }

  /// Every 6th frame → ML Kit → hint. Runs on-device; nothing leaves the phone.
  Future<void> _onFrame(CameraImage img, CameraDescription cam) async {
    if (_busy || _detector == null || (_frame++ % 6) != 0) return;
    _busy = true;
    try {
      final input = _toInputImage(img, cam);
      if (input == null) return;
      final poses = await _detector!.processImage(input);
      final rotated = cam.sensorOrientation % 180 != 0;
      final w = rotated ? img.height.toDouble() : img.width.toDouble();
      final h = rotated ? img.width.toDouble() : img.height.toDouble();
      final lm = poses.isEmpty ? null : _norm(poses.first, w, h);
      final hint = PoseHints.evaluate(lm, widget.angle);
      if (mounted && hint.message != _hint.message) {
        if (hint.ready && !_hint.ready) HapticFeedback.lightImpact();
        setState(() => _hint = hint);
      }
    } catch (_) {
      // A dropped frame is fine.
    } finally {
      _busy = false;
    }
  }

  static InputImage? _toInputImage(CameraImage img, CameraDescription cam) {
    final rotation = InputImageRotationValue.fromRawValue(
      cam.sensorOrientation,
    );
    final format = InputImageFormatValue.fromRawValue(img.format.raw as int);
    if (rotation == null || format == null || img.planes.length != 1)
      return null;
    final plane = img.planes.first;
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: ui.Size(img.width.toDouble(), img.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  static const _keys = {
    PoseLandmarkType.nose: 'nose',
    PoseLandmarkType.leftEye: 'l_eye',
    PoseLandmarkType.rightEye: 'r_eye',
    PoseLandmarkType.leftEar: 'l_ear',
    PoseLandmarkType.rightEar: 'r_ear',
    PoseLandmarkType.leftShoulder: 'l_shoulder',
    PoseLandmarkType.rightShoulder: 'r_shoulder',
    PoseLandmarkType.leftHip: 'l_hip',
    PoseLandmarkType.rightHip: 'r_hip',
    PoseLandmarkType.leftAnkle: 'l_ankle',
    PoseLandmarkType.rightAnkle: 'r_ankle',
  };

  static Landmarks _norm(Pose pose, double w, double h) => {
    for (final e in pose.landmarks.entries)
      if (_keys.containsKey(e.key) && e.value.likelihood > 0.5)
        _keys[e.key]!: Offset(e.value.x / w, e.value.y / h),
  };

  Future<void> _shoot({bool countdown = false}) async {
    final cam = _cam;
    if (cam == null || _processing) return;
    if (countdown) {
      for (var i = 5; i > 0; i--) {
        if (!mounted) return;
        setState(() => _timer = i);
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      setState(() => _timer = null);
    }
    setState(() => _processing = true);
    try {
      await cam.stopImageStream();
      final file = await cam.takePicture();
      await _finish(file.path);
    } catch (e) {
      if (mounted) {
        setState(() => _processing = false);
        showSnack(context, 'Couldn’t take the photo — try again.');
      }
    }
  }

  Future<void> _pick() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (x == null) return;
    setState(() => _processing = true);
    await _finish(x.path);
  }

  Future<void> _finish(String path) async {
    final s = ref.read(servicesProvider);
    final faceBlur = s.local.profile?.faceBlur ?? true;
    Landmarks? lm;
    if (s.pose != null) {
      try {
        final bytes = await File(path).readAsBytes();
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        lm = await s.pose!.detectFile(
          path,
          ui.Size(frame.image.width.toDouble(), frame.image.height.toDouble()),
        );
      } catch (_) {}
    }
    final saved = await s.photos.saveCheckinPhoto(
      path,
      checkinId: widget.checkinId,
      angle: widget.angle,
      blurFace: faceBlur && lm != null && widget.angle != 'back'
          ? PoseHints.faceRect(lm)
          : null,
    );
    if (!mounted) return;
    Navigator.of(context).pop(
      CheckinPhoto(
        angle: widget.angle,
        localPath: saved,
        landmarks: Alignment2D.torso(lm),
      ),
    );
  }

  @override
  void dispose() {
    final cam = _cam;
    _cam = null;
    unawaited(() async {
      try {
        if (cam?.value.isStreamingImages ?? false) await cam!.stopImageStream();
      } catch (_) {}
      await cam?.dispose();
      await _detector?.close();
    }());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cam = _cam;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text('${angleLabel(widget.angle)} photo'),
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (cam != null && cam.value.isInitialized)
                  Center(child: CameraPreview(cam))
                else
                  Center(
                    child: Text(
                      _error ?? 'Starting camera…',
                      style: const TextStyle(color: Brand.textDim),
                    ),
                  ),
                IgnorePointer(
                  child: CustomPaint(
                    painter: _GuidePainter(widget.angle, _hint.ready),
                  ),
                ),
                Positioned(
                  left: 16,
                  right: 16,
                  top: 12,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(
                      vertical: 10,
                      horizontal: 14,
                    ),
                    decoration: BoxDecoration(
                      color: (_hint.ready ? Brand.lime : Brand.card2)
                          .withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      _hint.message,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: _hint.ready ? Brand.ink : Brand.text,
                      ),
                    ),
                  ),
                ),
                if (_timer != null)
                  Center(
                    child: Text(
                      '$_timer',
                      style: const TextStyle(
                        fontSize: 96,
                        fontWeight: FontWeight.w800,
                        color: Brand.lime,
                      ),
                    ),
                  ),
                if (_processing)
                  const Center(
                    child: CircularProgressIndicator(color: Brand.lime),
                  ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Pick from gallery',
                    onPressed: _processing ? null : _pick,
                    icon: const Icon(
                      Icons.photo_library_outlined,
                      color: Brand.text,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: cam == null || _processing ? null : () => _shoot(),
                    child: Container(
                      width: 74,
                      height: 74,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _hint.ready ? Brand.lime : Brand.text,
                          width: 4,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(5),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _hint.ready ? Brand.lime : Brand.text,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '5-second timer',
                    onPressed: cam == null || _processing
                        ? null
                        : () => _shoot(countdown: true),
                    icon: const Icon(Icons.timer_outlined, color: Brand.text),
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

/// Body silhouette guide: the same framing every week makes photos comparable.
class _GuidePainter extends CustomPainter {
  _GuidePainter(this.angle, this.ready);
  final String angle;
  final bool ready;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = (ready ? Brand.lime : Colors.white).withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    final cx = size.width / 2;
    final top = size.height * 0.1, bottom = size.height * 0.94;
    final h = bottom - top;
    final shoulder = angle == 'side' ? h * 0.07 : h * 0.13;
    canvas.drawCircle(Offset(cx, top + h * 0.06), h * 0.055, p);
    final body = Path()
      ..moveTo(cx - shoulder, top + h * 0.16)
      ..lineTo(cx + shoulder, top + h * 0.16)
      ..lineTo(cx + shoulder * 0.8, top + h * 0.5)
      ..lineTo(cx + shoulder * 0.55, bottom)
      ..moveTo(cx - shoulder, top + h * 0.16)
      ..lineTo(cx - shoulder * 0.8, top + h * 0.5)
      ..lineTo(cx - shoulder * 0.55, bottom);
    canvas.drawPath(body, p);
    canvas.drawLine(
      Offset(cx - size.width * 0.3, bottom),
      Offset(cx + size.width * 0.3, bottom),
      p,
    );
  }

  @override
  bool shouldRepaint(_GuidePainter old) =>
      old.ready != ready || old.angle != angle;
}

/// Test hook: lets widget tests inject photos without a camera.
@visibleForTesting
CheckinPhoto fakePhoto(String angle, String path) => CheckinPhoto(
  angle: angle,
  localPath: path,
  landmarks: const {'sx': 0.5, 'sy': 0.3, 'hx': 0.5, 'hy': 0.55},
);
