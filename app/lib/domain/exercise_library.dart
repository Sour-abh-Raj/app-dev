import 'dart:convert';

import 'package:flutter/services.dart';

class Exercise {
  const Exercise({
    required this.id,
    required this.name,
    required this.muscle,
    required this.equipment,
    required this.difficulty,
    required this.contraindications,
    required this.demoVideoUrl,
    required this.cues,
    required this.substitutions,
    required this.timed,
  });

  final String id;
  final String name;
  final String muscle;
  final List<String> equipment;
  final int difficulty;
  final List<String> contraindications;
  final String demoVideoUrl;
  final List<String> cues;
  final List<String> substitutions;
  final bool timed;

  /// Equipment is "all required"; bodyweight needs nothing.
  Set<String> get needs => equipment.where((e) => e != 'bodyweight').toSet();

  bool get loadable => needs.isNotEmpty;

  factory Exercise.fromJson(Map<String, dynamic> j) => Exercise(
    id: j['id'] as String,
    name: j['name'] as String,
    muscle: j['muscle'] as String,
    equipment: List<String>.from(j['equipment'] as List),
    difficulty: j['difficulty'] as int,
    contraindications: List<String>.from(j['contraindications'] as List),
    demoVideoUrl: j['demo_video_url'] as String? ?? '',
    cues: List<String>.from(j['cues'] as List),
    substitutions: List<String>.from(j['substitutions'] as List),
    timed: j['kind'] == 'time',
  );
}

/// The seeded exercise library (O5: version-keyed; the version travels with
/// the asset and the Firestore copy).
class ExerciseLibrary {
  ExerciseLibrary(this.version, List<Exercise> items)
    : byId = {for (final e in items) e.id: e};

  final int version;
  final Map<String, Exercise> byId;

  Iterable<Exercise> get all => byId.values;

  Exercise? operator [](String id) => byId[id];

  String nameOf(String id) => byId[id]?.name ?? id;

  bool allowed(
    Exercise e,
    Set<String> equipment,
    Set<String> injuries,
    int maxDifficulty,
  ) =>
      equipment.containsAll(e.needs) &&
      !e.contraindications.any(injuries.contains) &&
      e.difficulty <= maxDifficulty;

  /// Substitutions the user can actually do (equipment + injuries respected).
  List<Exercise> substitutesFor(
    String id,
    Set<String> equipment,
    Set<String> injuries,
  ) {
    final ex = byId[id];
    if (ex == null) return const [];
    final direct = ex.substitutions
        .map((s) => byId[s])
        .whereType<Exercise>()
        .where((e) => allowed(e, equipment, injuries, 3));
    final sameMuscle = all.where(
      (e) =>
          e.id != id &&
          e.muscle == ex.muscle &&
          !ex.substitutions.contains(e.id) &&
          allowed(e, equipment, injuries, 3),
    );
    return [...direct, ...sameMuscle];
  }

  static ExerciseLibrary fromJsonString(String raw) {
    final data = jsonDecode(raw) as Map<String, dynamic>;
    return ExerciseLibrary(
      data['version'] as int,
      (data['exercises'] as List)
          .map((e) => Exercise.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  static Future<ExerciseLibrary> load([AssetBundle? bundle]) async =>
      fromJsonString(
        await (bundle ?? rootBundle).loadString('assets/seed/exercises.json'),
      );
}
