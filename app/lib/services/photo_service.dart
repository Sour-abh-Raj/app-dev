import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui';

import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../domain/pose_logic.dart';

/// Photo pipeline: orientation baked in, EXIF/GPS stripped (re-encode), size
/// bounded, optional face blur — all before anything leaves the device.
class PhotoService {
  PhotoService({Future<Directory> Function()? docsDir})
    : _docsDir = docsDir ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _docsDir;
  static const storageMaxEdge =
      2048; // originals; the server makes _1024/_thumb
  static const visionMaxEdge = 1024; // O5: vision inputs ≤1024 px

  Future<String> _path(String sub, String name) async {
    final dir = Directory('${(await _docsDir()).path}/$sub');
    await dir.create(recursive: true);
    return '${dir.path}/$name';
  }

  /// Processes a captured check-in photo and stores it privately on device.
  Future<String> saveCheckinPhoto(
    String srcPath, {
    required String checkinId,
    required String angle,
    Rect? blurFace,
  }) async {
    final bytes = await File(srcPath).readAsBytes();
    final out = await Isolate.run(
      () => processJpeg(bytes, storageMaxEdge, blurFace),
    );
    final path = await _path('photos/$checkinId', '$angle.jpg');
    await File(path).writeAsBytes(out, flush: true);
    return path;
  }

  /// Meal photo → ≤1024 px JPEG on disk; returns the path.
  Future<String> saveMealPhoto(String srcPath, String mealId) async {
    final bytes = await File(srcPath).readAsBytes();
    final out = await Isolate.run(
      () => processJpeg(bytes, visionMaxEdge, null),
    );
    final path = await _path('meals', '$mealId.jpg');
    await File(path).writeAsBytes(out, flush: true);
    return path;
  }

  Future<String> b64(String path) async =>
      base64Encode(await File(path).readAsBytes());

  /// Pure image step (runs in an isolate). Public for tests.
  static Uint8List processJpeg(Uint8List input, int maxEdge, Rect? blurFace) {
    var im = img.decodeImage(input);
    if (im == null) throw const FormatException('not an image');
    im = img.bakeOrientation(im);
    if (im.width > maxEdge || im.height > maxEdge) {
      im = im.width >= im.height
          ? img.copyResize(
              im,
              width: maxEdge,
              interpolation: img.Interpolation.average,
            )
          : img.copyResize(
              im,
              height: maxEdge,
              interpolation: img.Interpolation.average,
            );
    }
    if (blurFace != null) {
      final x = (blurFace.left * im.width).round().clamp(0, im.width - 1);
      final y = (blurFace.top * im.height).round().clamp(0, im.height - 1);
      final w = (blurFace.width * im.width).round().clamp(1, im.width - x);
      final h = (blurFace.height * im.height).round().clamp(1, im.height - y);
      final region = img.copyCrop(im, x: x, y: y, width: w, height: h);
      // Pixelate then blur: irreversible and cheap.
      final small = img.copyResize(
        region,
        width: 8,
        height: (8 * h / w).ceil().clamp(1, 64),
      );
      final blurred = img.gaussianBlur(
        img.copyResize(small, width: w, height: h),
        radius: 6,
      );
      img.compositeImage(im, blurred, dstX: x, dstY: y);
    }
    im.exif = img.ExifData(); // drop all metadata, including GPS
    return img.encodeJpg(im, quality: 85);
  }
}

/// On-device ML Kit pose detection.
class PoseService {
  PoseService()
    : _detector = PoseDetector(
        options: PoseDetectorOptions(
          mode: PoseDetectionMode.single,
          model: PoseDetectionModel.base,
        ),
      );

  final PoseDetector _detector;

  static const _map = {
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

  /// Landmarks normalised to the image size; null when nobody is detected.
  Future<Landmarks?> detectFile(String path, Size imageSize) async {
    final poses = await _detector.processImage(InputImage.fromFilePath(path));
    if (poses.isEmpty) return null;
    final out = <String, Offset>{};
    poses.first.landmarks.forEach((type, lm) {
      final key = _map[type];
      if (key != null && lm.likelihood > 0.5) {
        out[key] = Offset(lm.x / imageSize.width, lm.y / imageSize.height);
      }
    });
    return out;
  }

  Future<void> dispose() => _detector.close();
}
