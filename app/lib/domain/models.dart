/// Plain data models. They round-trip through JSON maps so Hive (offline truth)
/// and Firestore share one shape without code generation.
library;

enum Goal { loseFat, buildMuscle, recomp, strength }

extension GoalX on Goal {
  String get wire => const {
    Goal.loseFat: 'lose_fat',
    Goal.buildMuscle: 'build_muscle',
    Goal.recomp: 'recomp',
    Goal.strength: 'strength',
  }[this]!;
  String get label => const {
    Goal.loseFat: 'Lose fat',
    Goal.buildMuscle: 'Build muscle',
    Goal.recomp: 'Recomp',
    Goal.strength: 'Get stronger',
  }[this]!;
  String get blurb => const {
    Goal.loseFat: 'Drop fat, keep muscle',
    Goal.buildMuscle: 'Add size where it counts',
    Goal.recomp: 'Leaner and stronger at once',
    Goal.strength: 'Lift heavier, move better',
  }[this]!;
  static Goal fromWire(String? s) =>
      Goal.values.firstWhere((g) => g.wire == s, orElse: () => Goal.loseFat);
}

enum Level { beginner, intermediate, advanced }

Level levelFromWire(String? s) =>
    Level.values.firstWhere((l) => l.name == s, orElse: () => Level.beginner);

const equipmentOptions = <String, String>{
  'bodyweight': 'Bodyweight',
  'dumbbells': 'Dumbbells',
  'bench': 'Bench',
  'barbell': 'Barbell',
  'kettlebell': 'Kettlebell',
  'bands': 'Bands',
  'pullup_bar': 'Pull-up bar',
  'cable': 'Cable',
  'machine': 'Machines',
};

const injuryOptions = <String, String>{
  'knee': 'Knee',
  'lower_back': 'Lower back',
  'shoulder': 'Shoulder',
  'wrist': 'Wrist',
  'elbow': 'Elbow',
  'hip': 'Hip',
  'ankle': 'Ankle',
};

class Profile {
  Profile({
    this.name = '',
    this.birthYear,
    this.sex,
    this.heightCm,
    this.weightKg,
    this.goal = Goal.loseFat,
    this.targetKg,
    this.level = Level.beginner,
    this.equipment = const ['dumbbells'],
    this.daysPerWeek = 3,
    this.mins = 30,
    this.injuries = const [],
    this.injuryNotes = '',
    this.timezone = 'UTC',
    this.adultConsent = false,
    this.faceBlur = true,
    this.reminderHour = 18,
    this.checkinReminderHour = 9,
    this.biometricLock = false,
    this.healthSync = false,
    this.createdAt,
  });

  final String name;
  final int? birthYear;
  final String? sex; // male | female | other
  final double? heightCm;
  final double? weightKg;
  final Goal goal;
  final double? targetKg;
  final Level level;
  final List<String> equipment;
  final int daysPerWeek;
  final int mins;
  final List<String> injuries;
  final String injuryNotes;
  final String timezone;
  final bool adultConsent;
  final bool faceBlur;
  final int reminderHour;
  final int checkinReminderHour;
  final bool biometricLock;
  final bool healthSync;
  final DateTime? createdAt;

  Profile copyWith({
    String? name,
    int? birthYear,
    String? sex,
    double? heightCm,
    double? weightKg,
    Goal? goal,
    double? targetKg,
    Level? level,
    List<String>? equipment,
    int? daysPerWeek,
    int? mins,
    List<String>? injuries,
    String? injuryNotes,
    String? timezone,
    bool? adultConsent,
    bool? faceBlur,
    int? reminderHour,
    int? checkinReminderHour,
    bool? biometricLock,
    bool? healthSync,
    DateTime? createdAt,
  }) => Profile(
    name: name ?? this.name,
    birthYear: birthYear ?? this.birthYear,
    sex: sex ?? this.sex,
    heightCm: heightCm ?? this.heightCm,
    weightKg: weightKg ?? this.weightKg,
    goal: goal ?? this.goal,
    targetKg: targetKg ?? this.targetKg,
    level: level ?? this.level,
    equipment: equipment ?? this.equipment,
    daysPerWeek: daysPerWeek ?? this.daysPerWeek,
    mins: mins ?? this.mins,
    injuries: injuries ?? this.injuries,
    injuryNotes: injuryNotes ?? this.injuryNotes,
    timezone: timezone ?? this.timezone,
    adultConsent: adultConsent ?? this.adultConsent,
    faceBlur: faceBlur ?? this.faceBlur,
    reminderHour: reminderHour ?? this.reminderHour,
    checkinReminderHour: checkinReminderHour ?? this.checkinReminderHour,
    biometricLock: biometricLock ?? this.biometricLock,
    healthSync: healthSync ?? this.healthSync,
    createdAt: createdAt ?? this.createdAt,
  );

  /// Shape sent to /v1/plan/generate.
  Map<String, dynamic> toOnboarding() => {
    'goal': goal.wire,
    'level': level.name,
    'equipment': equipment.isEmpty ? ['bodyweight'] : equipment,
    'days_per_week': daysPerWeek,
    'mins': mins,
    'injuries': injuries,
    'injury_notes': injuryNotes,
    if (sex != null) 'sex': sex,
    if (heightCm != null) 'height_cm': heightCm,
    if (weightKg != null) 'weight_kg': weightKg,
    if (targetKg != null) 'target_kg': targetKg,
  };

  /// Firestore users/{uid} fields (server-managed fields are never written here).
  Map<String, dynamic> toFirestore() => {
    'profile': {
      'name': name,
      'dob': birthYear == null ? null : '$birthYear',
      'sex': sex,
      'height_cm': heightCm,
    },
    'goal': {'type': goal.wire, 'target_kg': targetKg, 'deadline': null},
    'level': level.name,
    'equipment': equipment,
    'days_per_week': daysPerWeek,
    'mins': mins,
    'injuries': injuries,
    'timezone': timezone,
    'photo_consent': {
      'adult': adultConsent,
      'ts': createdAt?.toIso8601String(),
    },
    'face_blur': faceBlur,
    'reminder_times': ['${reminderHour.toString().padLeft(2, '0')}:00'],
  };

  Map<String, dynamic> toJson() => {
    'name': name,
    'birth_year': birthYear,
    'sex': sex,
    'height_cm': heightCm,
    'weight_kg': weightKg,
    'goal': goal.wire,
    'target_kg': targetKg,
    'level': level.name,
    'equipment': equipment,
    'days_per_week': daysPerWeek,
    'mins': mins,
    'injuries': injuries,
    'injury_notes': injuryNotes,
    'timezone': timezone,
    'adult_consent': adultConsent,
    'face_blur': faceBlur,
    'reminder_hour': reminderHour,
    'checkin_reminder_hour': checkinReminderHour,
    'biometric_lock': biometricLock,
    'health_sync': healthSync,
    'created_at': createdAt?.toIso8601String(),
  };

  factory Profile.fromJson(Map<dynamic, dynamic> j) => Profile(
    name: j['name'] as String? ?? '',
    birthYear: j['birth_year'] as int?,
    sex: j['sex'] as String?,
    heightCm: (j['height_cm'] as num?)?.toDouble(),
    weightKg: (j['weight_kg'] as num?)?.toDouble(),
    goal: GoalX.fromWire(j['goal'] as String?),
    targetKg: (j['target_kg'] as num?)?.toDouble(),
    level: levelFromWire(j['level'] as String?),
    equipment: List<String>.from(
      j['equipment'] as List? ?? const ['dumbbells'],
    ),
    daysPerWeek: j['days_per_week'] as int? ?? 3,
    mins: j['mins'] as int? ?? 30,
    injuries: List<String>.from(j['injuries'] as List? ?? const []),
    injuryNotes: j['injury_notes'] as String? ?? '',
    timezone: j['timezone'] as String? ?? 'UTC',
    adultConsent: j['adult_consent'] as bool? ?? false,
    faceBlur: j['face_blur'] as bool? ?? true,
    reminderHour: j['reminder_hour'] as int? ?? 18,
    checkinReminderHour: j['checkin_reminder_hour'] as int? ?? 9,
    biometricLock: j['biometric_lock'] as bool? ?? false,
    healthSync: j['health_sync'] as bool? ?? false,
    createdAt: _dt(j['created_at']),
  );
}

DateTime? _dt(Object? v) => v is String ? DateTime.tryParse(v) : null;

/// Rebuilds a [Profile] from users/{uid} (restore on a new device).
Profile? profileFromFirestore(Map<String, dynamic>? d) {
  if (d == null || d['goal'] is! Map) return null;
  final prof = (d['profile'] as Map?) ?? const {};
  final consent = (d['photo_consent'] as Map?) ?? const {};
  return Profile(
    name: prof['name'] as String? ?? '',
    sex: prof['sex'] as String?,
    heightCm: (prof['height_cm'] as num?)?.toDouble(),
    birthYear: int.tryParse('${prof['dob'] ?? ''}'),
    goal: GoalX.fromWire((d['goal'] as Map)['type'] as String?),
    targetKg: ((d['goal'] as Map)['target_kg'] as num?)?.toDouble(),
    level: levelFromWire(d['level'] as String?),
    equipment: List<String>.from(
      d['equipment'] as List? ?? const ['bodyweight'],
    ),
    daysPerWeek: d['days_per_week'] as int? ?? 3,
    mins: d['mins'] as int? ?? 30,
    injuries: List<String>.from(d['injuries'] as List? ?? const []),
    timezone: d['timezone'] as String? ?? 'UTC',
    adultConsent: consent['adult'] as bool? ?? false,
    faceBlur: d['face_blur'] as bool? ?? true,
    createdAt: _dt(consent['ts']),
  );
}

// ---------- plan ----------

class SessionExercise {
  const SessionExercise({
    required this.exId,
    required this.sets,
    required this.reps,
    this.loadKg,
    required this.restS,
  });

  final String exId;
  final int sets;
  final String reps; // "8-12", "30s"
  final double? loadKg;
  final int restS;

  bool get timed => reps.endsWith('s');

  /// Reps prefilled for a set: the bottom of a range ("8-12" → 8), or the
  /// seconds of a timed hold ("30s" → 30).
  int get targetReps {
    final first = reps.split(RegExp(r'[-/s]')).first;
    return int.tryParse(first) ?? 10;
  }

  SessionExercise copyWith({int? sets, double? loadKg, String? exId}) =>
      SessionExercise(
        exId: exId ?? this.exId,
        sets: sets ?? this.sets,
        reps: reps,
        loadKg: loadKg ?? this.loadKg,
        restS: restS,
      );

  Map<String, dynamic> toJson() => {
    'ex_id': exId,
    'sets': sets,
    'reps': reps,
    'load_kg': loadKg,
    'rest_s': restS,
  };

  factory SessionExercise.fromJson(Map<dynamic, dynamic> j) => SessionExercise(
    exId: j['ex_id'] as String,
    sets: j['sets'] as int,
    reps: j['reps'] as String,
    loadKg: (j['load_kg'] as num?)?.toDouble(),
    restS: j['rest_s'] as int,
  );
}

class PlanSession {
  const PlanSession({
    required this.dayIndex,
    required this.name,
    required this.estMins,
    required this.exercises,
  });

  final int dayIndex;
  final String name;
  final int estMins;
  final List<SessionExercise> exercises;

  Map<String, dynamic> toJson() => {
    'day_index': dayIndex,
    'name': name,
    'est_mins': estMins,
    'exercises': exercises.map((e) => e.toJson()).toList(),
  };

  factory PlanSession.fromJson(Map<dynamic, dynamic> j) => PlanSession(
    dayIndex: j['day_index'] as int,
    name: j['name'] as String,
    estMins: j['est_mins'] as int,
    exercises: (j['exercises'] as List)
        .map((e) => SessionExercise.fromJson(e as Map))
        .toList(),
  );
}

class PlanWeek {
  const PlanWeek({required this.weekIndex, required this.sessions});

  final int weekIndex;
  final List<PlanSession> sessions;

  Map<String, dynamic> toJson() => {
    'week_index': weekIndex,
    'sessions': sessions.map((s) => s.toJson()).toList(),
  };

  factory PlanWeek.fromJson(Map<dynamic, dynamic> j) => PlanWeek(
    weekIndex: j['week_index'] as int,
    sessions: (j['sessions'] as List)
        .map((s) => PlanSession.fromJson(s as Map))
        .toList(),
  );
}

class Mesocycle {
  const Mesocycle({
    required this.name,
    required this.weeks,
    this.kcalTarget,
    this.proteinG,
    this.notes = '',
  });

  final String name;
  final List<PlanWeek> weeks;
  final int? kcalTarget;
  final int? proteinG;
  final String notes;

  Map<String, dynamic> toJson() => {
    'name': name,
    'weeks': weeks.map((w) => w.toJson()).toList(),
    'kcal_target': kcalTarget,
    'protein_g': proteinG,
    'notes': notes,
  };

  factory Mesocycle.fromJson(Map<dynamic, dynamic> j) => Mesocycle(
    name: j['name'] as String,
    weeks: (j['weeks'] as List)
        .map((w) => PlanWeek.fromJson(w as Map))
        .toList(),
    kcalTarget: j['kcal_target'] as int?,
    proteinG: j['protein_g'] as int?,
    notes: j['notes'] as String? ?? '',
  );
}

class Plan {
  const Plan({
    required this.version,
    required this.startDate,
    required this.mesocycle,
    required this.source,
    this.queued = false,
    this.cycle = 0,
    this.weekOffset = 0,
  });

  final int version;
  final DateTime startDate; // Week 1 Day 1 of the programme (never moves)
  final Mesocycle mesocycle;
  final String source; // ai | template
  final bool queued; // AI failed → template applied, will retry
  final int cycle; // completed mesocycles (weeks wrap after 4)
  /// Absolute week before this mesocycle began (a re-plan at week 5 → 4).
  final int weekOffset;

  Map<String, dynamic> toJson() => {
    'version': version,
    'start_date': startDate.toIso8601String(),
    'mesocycle': mesocycle.toJson(),
    'source': source,
    'queued': queued,
    'cycle': cycle,
    'week_offset': weekOffset,
  };

  factory Plan.fromJson(Map<dynamic, dynamic> j) => Plan(
    version: j['version'] as int,
    startDate: DateTime.parse(j['start_date'] as String),
    mesocycle: Mesocycle.fromJson(j['mesocycle'] as Map),
    source: j['source'] as String,
    queued: j['queued'] as bool? ?? false,
    cycle: j['cycle'] as int? ?? 0,
    weekOffset: j['week_offset'] as int? ?? 0,
  );
}

// ---------- logs ----------

class SetLog {
  const SetLog({
    required this.exId,
    required this.setN,
    required this.reps,
    required this.loadKg,
    required this.done,
    this.ts,
  });

  final String exId;
  final int setN;
  final int reps;
  final double loadKg;
  final bool done;
  final DateTime? ts;

  SetLog copyWith({
    int? reps,
    double? loadKg,
    bool? done,
    DateTime? ts,
    String? exId,
  }) => SetLog(
    exId: exId ?? this.exId,
    setN: setN,
    reps: reps ?? this.reps,
    loadKg: loadKg ?? this.loadKg,
    done: done ?? this.done,
    ts: ts ?? this.ts,
  );

  Map<String, dynamic> toJson() => {
    'ex_id': exId,
    'set_n': setN,
    'reps': reps,
    'load_kg': loadKg,
    'done': done,
    'ts': ts?.toIso8601String(),
  };

  factory SetLog.fromJson(Map<dynamic, dynamic> j) => SetLog(
    exId: j['ex_id'] as String,
    setN: j['set_n'] as int,
    reps: j['reps'] as int,
    loadKg: (j['load_kg'] as num).toDouble(),
    done: j['done'] as bool,
    ts: _dt(j['ts']),
  );
}

class Workout {
  const Workout({
    required this.id,
    required this.planVersion,
    required this.week,
    required this.dayIndex,
    required this.sessionName,
    required this.scheduledFor,
    this.startedAt,
    this.finishedAt,
    this.sets = const [],
    this.volumeKg = 0,
    this.prs = const [],
    this.catchup = false,
    this.updatedAt,
  });

  final String id;
  final int planVersion;
  final int week;
  final int dayIndex;
  final String sessionName;
  final DateTime scheduledFor;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final List<SetLog> sets;
  final double volumeKg;
  final List<String> prs;
  final bool catchup;
  final DateTime? updatedAt;

  bool get finished => finishedAt != null;

  Workout copyWith({
    DateTime? startedAt,
    DateTime? finishedAt,
    List<SetLog>? sets,
    double? volumeKg,
    List<String>? prs,
    DateTime? updatedAt,
  }) => Workout(
    id: id,
    planVersion: planVersion,
    week: week,
    dayIndex: dayIndex,
    sessionName: sessionName,
    scheduledFor: scheduledFor,
    startedAt: startedAt ?? this.startedAt,
    finishedAt: finishedAt ?? this.finishedAt,
    sets: sets ?? this.sets,
    volumeKg: volumeKg ?? this.volumeKg,
    prs: prs ?? this.prs,
    catchup: catchup,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'plan_ref': 'v$planVersion',
    'plan_version': planVersion,
    'week': week,
    'day_index': dayIndex,
    'session_name': sessionName,
    'scheduled_for': scheduledFor.toIso8601String(),
    'started_at': startedAt?.toIso8601String(),
    'finished_at': finishedAt?.toIso8601String(),
    'sets': sets.map((s) => s.toJson()).toList(),
    'volume_kg': volumeKg,
    'prs': prs,
    'catchup': catchup,
    'updated_at': updatedAt?.toIso8601String(),
  };

  factory Workout.fromJson(Map<dynamic, dynamic> j) => Workout(
    id: j['id'] as String,
    planVersion: j['plan_version'] as int? ?? 1,
    week: j['week'] as int,
    dayIndex: j['day_index'] as int,
    sessionName: j['session_name'] as String? ?? 'Workout',
    scheduledFor: DateTime.parse(j['scheduled_for'] as String),
    startedAt: _dt(j['started_at']),
    finishedAt: _dt(j['finished_at']),
    sets: (j['sets'] as List? ?? const [])
        .map((s) => SetLog.fromJson(s as Map))
        .toList(),
    volumeKg: (j['volume_kg'] as num? ?? 0).toDouble(),
    prs: List<String>.from(j['prs'] as List? ?? const []),
    catchup: j['catchup'] as bool? ?? false,
    updatedAt: _dt(j['updated_at']),
  );
}

class Macros {
  const Macros({
    required this.kcal,
    required this.p,
    required this.c,
    required this.f,
    this.confidence = 1,
    this.model = 'manual',
    this.name = '',
  });

  final int kcal;
  final double p;
  final double c;
  final double f;
  final double confidence;
  final String model;
  final String name;

  Macros copyWith({int? kcal, double? p, double? c, double? f, String? name}) =>
      Macros(
        kcal: kcal ?? this.kcal,
        p: p ?? this.p,
        c: c ?? this.c,
        f: f ?? this.f,
        confidence: confidence,
        model: model,
        name: name ?? this.name,
      );

  Map<String, dynamic> toJson() => {
    'kcal': kcal,
    'P': p,
    'C': c,
    'F': f,
    'confidence': confidence,
    'model': model,
    'name': name,
  };

  factory Macros.fromJson(Map<dynamic, dynamic> j) => Macros(
    kcal: (j['kcal'] as num).round(),
    p: (j['P'] as num).toDouble(),
    c: (j['C'] as num).toDouble(),
    f: (j['F'] as num).toDouble(),
    confidence: (j['confidence'] as num? ?? 1).toDouble(),
    model: j['model'] as String? ?? 'manual',
    name: j['name'] as String? ?? '',
  );
}

enum MealStatus { analyzing, done, needsConnection, capReached, failed }

class Meal {
  const Meal({
    required this.id,
    required this.loggedAt,
    this.localPhoto,
    this.photoPath,
    this.text,
    this.ai,
    this.override,
    this.status = MealStatus.done,
    this.idemKey,
  });

  final String id;
  final DateTime loggedAt;
  final String? localPhoto;
  final String? photoPath;
  final String? text;
  final Macros? ai;
  final Macros? override;
  final MealStatus status;
  final String? idemKey;

  Macros? get macros => override ?? ai;

  Meal copyWith({
    Macros? ai,
    Macros? override,
    MealStatus? status,
    String? photoPath,
    String? text,
  }) => Meal(
    id: id,
    loggedAt: loggedAt,
    localPhoto: localPhoto,
    photoPath: photoPath ?? this.photoPath,
    text: text ?? this.text,
    ai: ai ?? this.ai,
    override: override ?? this.override,
    status: status ?? this.status,
    idemKey: idemKey,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'logged_at': loggedAt.toIso8601String(),
    'local_photo': localPhoto,
    'photo_path': photoPath,
    'text': text,
    'ai': ai?.toJson(),
    'override': override?.toJson(),
    'status': status.name,
    'idem_key': idemKey,
  };

  factory Meal.fromJson(Map<dynamic, dynamic> j) => Meal(
    id: j['id'] as String,
    loggedAt: DateTime.parse(j['logged_at'] as String),
    localPhoto: j['local_photo'] as String?,
    photoPath: j['photo_path'] as String?,
    text: j['text'] as String?,
    ai: j['ai'] == null ? null : Macros.fromJson(j['ai'] as Map),
    override: j['override'] == null
        ? null
        : Macros.fromJson(j['override'] as Map),
    status: MealStatus.values.firstWhere(
      (s) => s.name == j['status'],
      orElse: () => MealStatus.done,
    ),
    idemKey: j['idem_key'] as String?,
  );
}

class CheckinPhoto {
  const CheckinPhoto({
    required this.angle,
    required this.localPath,
    this.path,
    this.landmarks,
  });

  final String angle; // front | side | back
  final String localPath;
  final String? path; // storage path once uploaded
  /// Normalised (0-1) shoulder-mid and hip-mid points for alignment.
  final Map<String, double>? landmarks;

  String? get thumb => path?.replaceFirst(RegExp(r'\.jpg$'), '_thumb.jpg');

  CheckinPhoto copyWith({String? path}) => CheckinPhoto(
    angle: angle,
    localPath: localPath,
    path: path ?? this.path,
    landmarks: landmarks,
  );

  Map<String, dynamic> toJson() => {
    'angle': angle,
    'local_path': localPath,
    'path': path,
    'thumb': thumb,
    'landmarks': landmarks,
  };

  factory CheckinPhoto.fromJson(Map<dynamic, dynamic> j) => CheckinPhoto(
    angle: j['angle'] as String,
    localPath: j['local_path'] as String? ?? '',
    path: j['path'] as String?,
    landmarks: (j['landmarks'] as Map?)?.map(
      (k, v) => MapEntry(k as String, (v as num).toDouble()),
    ),
  );
}

class Survey {
  const Survey({
    this.adherence = 3,
    this.sleep = 3,
    this.soreness = 3,
    this.motivation = 3,
  });

  final int adherence;
  final int sleep;
  final int soreness;
  final int motivation;

  Survey copyWith({
    int? adherence,
    int? sleep,
    int? soreness,
    int? motivation,
  }) => Survey(
    adherence: adherence ?? this.adherence,
    sleep: sleep ?? this.sleep,
    soreness: soreness ?? this.soreness,
    motivation: motivation ?? this.motivation,
  );

  Map<String, dynamic> toJson() => {
    'adherence': adherence,
    'sleep': sleep,
    'soreness': soreness,
    'motivation': motivation,
  };

  factory Survey.fromJson(Map<dynamic, dynamic> j) => Survey(
    adherence: j['adherence'] as int? ?? 3,
    sleep: j['sleep'] as int? ?? 3,
    soreness: j['soreness'] as int? ?? 3,
    motivation: j['motivation'] as int? ?? 3,
  );
}

class Delta {
  const Delta({
    required this.metric,
    required this.from,
    required this.to,
    required this.unit,
    required this.confidence,
  });

  final String metric;
  final double from;
  final double to;
  final String unit;
  final double confidence;

  double get change => to - from;

  String get label =>
      const {
        'waist_cm': 'Waist',
        'body_fat_pct': 'Est. body fat',
        'weight_kg': 'Weight',
        'shoulder_waist_ratio': 'Shoulder:waist',
      }[metric] ??
      metric;

  /// "−3.2 cm (est.)" — deltas carry their confidence; never fake precision.
  String get display {
    final sign = change > 0 ? '+' : (change < 0 ? '−' : '±');
    final v = change.abs().toStringAsFixed(1);
    final est = metric == 'weight_kg' ? '' : ' (est.)';
    return '$sign$v $unit$est';
  }

  Map<String, dynamic> toJson() => {
    'metric': metric,
    'from': from,
    'to': to,
    'unit': unit,
    'confidence': confidence,
  };

  factory Delta.fromJson(Map<dynamic, dynamic> j) => Delta(
    metric: j['metric'] as String,
    from: (j['from'] as num).toDouble(),
    to: (j['to'] as num).toDouble(),
    unit: j['unit'] as String,
    confidence: (j['confidence'] as num).toDouble(),
  );
}

class AiReport {
  const AiReport({
    required this.summary,
    required this.deltas,
    required this.planChanges,
    required this.coachNote,
    required this.promptVersion,
  });

  final String summary;
  final List<Delta> deltas;
  final List<String> planChanges;
  final String coachNote;
  final String promptVersion;

  Map<String, dynamic> toJson() => {
    'summary': summary,
    'deltas': deltas.map((d) => d.toJson()).toList(),
    'plan_changes': planChanges,
    'coach_note': coachNote,
    'prompt_version': promptVersion,
  };

  factory AiReport.fromJson(Map<dynamic, dynamic> j) => AiReport(
    summary: j['summary'] as String,
    deltas: (j['deltas'] as List).map((d) => Delta.fromJson(d as Map)).toList(),
    planChanges: List<String>.from(j['plan_changes'] as List),
    coachNote: j['coach_note'] as String,
    promptVersion: j['prompt_version'] as String? ?? 'v1',
  );
}

enum CheckinStatus { draft, uploading, analyzing, done, queued, failed, manual }

class Checkin {
  const Checkin({
    required this.id,
    required this.weekIndex,
    required this.createdAt,
    this.weightKg,
    this.photos = const [],
    this.survey = const Survey(),
    this.report,
    this.status = CheckinStatus.draft,
    this.baseline = false,
  });

  final String id;
  final int weekIndex;
  final DateTime createdAt;
  final double? weightKg;
  final List<CheckinPhoto> photos;
  final Survey survey;
  final AiReport? report;
  final CheckinStatus status;
  final bool baseline;

  CheckinPhoto? photo(String angle) {
    for (final p in photos) {
      if (p.angle == angle) return p;
    }
    return null;
  }

  Checkin copyWith({
    double? weightKg,
    List<CheckinPhoto>? photos,
    Survey? survey,
    AiReport? report,
    CheckinStatus? status,
  }) => Checkin(
    id: id,
    weekIndex: weekIndex,
    createdAt: createdAt,
    weightKg: weightKg ?? this.weightKg,
    photos: photos ?? this.photos,
    survey: survey ?? this.survey,
    report: report ?? this.report,
    status: status ?? this.status,
    baseline: baseline,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'week_index': weekIndex,
    'created_at': createdAt.toIso8601String(),
    'weight_kg': weightKg,
    'photos': photos.map((p) => p.toJson()).toList(),
    'survey': survey.toJson(),
    'ai_report': report?.toJson(),
    'status': status.name,
    'baseline': baseline,
  };

  factory Checkin.fromJson(Map<dynamic, dynamic> j) => Checkin(
    id: j['id'] as String,
    weekIndex: j['week_index'] as int,
    createdAt: DateTime.parse(j['created_at'] as String),
    weightKg: (j['weight_kg'] as num?)?.toDouble(),
    photos: (j['photos'] as List? ?? const [])
        .map((p) => CheckinPhoto.fromJson(p as Map))
        .toList(),
    survey: j['survey'] == null
        ? const Survey()
        : Survey.fromJson(j['survey'] as Map),
    report: j['ai_report'] == null
        ? null
        : AiReport.fromJson(j['ai_report'] as Map),
    status: CheckinStatus.values.firstWhere(
      (s) => s.name == j['status'],
      orElse: () => CheckinStatus.draft,
    ),
    baseline: j['baseline'] as bool? ?? false,
  );
}

class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.content,
    required this.ts,
    this.flagged = false,
  });

  final String role; // user | assistant
  final String content;
  final DateTime ts;
  final bool flagged;

  Map<String, dynamic> toJson() => {
    'role': role,
    'content': content,
    'ts': ts.toIso8601String(),
    'flagged': flagged,
  };

  factory ChatMessage.fromJson(Map<dynamic, dynamic> j) => ChatMessage(
    role: j['role'] as String,
    content: j['content'] as String,
    ts: DateTime.parse(j['ts'] as String),
    flagged: j['flagged'] as bool? ?? false,
  );
}
