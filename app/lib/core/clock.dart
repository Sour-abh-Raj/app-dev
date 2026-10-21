import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// All "now" reads go through [Clock] so debug builds can time-travel (O11:
/// simulate the day-7 check-in and trial expiry). Release builds ignore offsets.
class Clock {
  Clock([this._offset = Duration.zero]);

  final Duration _offset;

  DateTime now() => kReleaseMode ? DateTime.now() : DateTime.now().add(_offset);

  Duration get offset => kReleaseMode ? Duration.zero : _offset;
}

class ClockNotifier extends Notifier<Clock> {
  @override
  Clock build() => Clock();

  void advance(Duration d) {
    if (kReleaseMode) return;
    state = Clock(state.offset + d);
  }

  void reset() => state = Clock();
}

final clockProvider = NotifierProvider<ClockNotifier, Clock>(ClockNotifier.new);

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

int daysBetween(DateTime a, DateTime b) =>
    (dateOnly(b).difference(dateOnly(a)).inHours / 24).round(); // DST-safe
