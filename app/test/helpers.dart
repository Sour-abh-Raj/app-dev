import 'dart:io';

import 'package:forme/domain/exercise_library.dart';
import 'package:forme/domain/models.dart';
import 'package:forme/domain/plan_engine.dart';
import 'package:hive/hive.dart';

ExerciseLibrary loadLib() => ExerciseLibrary.fromJsonString(
  File('assets/seed/exercises.json').readAsStringSync(),
);

Profile profile({
  Goal goal = Goal.loseFat,
  Level level = Level.beginner,
  List<String> equipment = const ['dumbbells'],
  int days = 3,
  int mins = 30,
  List<String> injuries = const [],
}) => Profile(
  goal: goal,
  level: level,
  equipment: equipment,
  daysPerWeek: days,
  mins: mins,
  injuries: injuries,
  sex: 'male',
  heightCm: 178,
  weightKg: 82,
);

Plan plan(DateTime start, {Profile? p, int version = 1}) => Plan(
  version: version,
  startDate: start,
  mesocycle: PlanEngine(loadLib()).template(p ?? profile()),
  source: 'template',
);

/// Fresh Hive directory per test file.
Future<Directory> initHive() async {
  final dir = await Directory.systemTemp.createTemp('forme_hive_');
  Hive.init(dir.path);
  return dir;
}
