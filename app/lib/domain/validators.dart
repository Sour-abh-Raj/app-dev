/// Input validators. Each returns null when valid, or a short user-facing
/// message. Ranges match the AI service's Pydantic models.
class Validators {
  const Validators._();

  static String? weightKg(double? v) {
    if (v == null) return 'Enter your weight';
    if (v < 30 || v > 300) return 'Weight must be 30–300 kg';
    return null;
  }

  static String? heightCm(double? v) {
    if (v == null) return null; // optional
    if (v < 100 || v > 250) return 'Height must be 100–250 cm';
    return null;
  }

  static String? birthYear(int? y, DateTime now) {
    if (y == null) return null;
    if (y < now.year - 100 || y > now.year) return 'Check the year';
    if (now.year - y < 18) return 'Forme AI is for adults (18+)';
    return null;
  }

  static String? reps(int? v) {
    if (v == null || v < 0) return 'Reps can’t be negative';
    if (v > 300) return 'That’s a lot of reps — check the number';
    return null;
  }

  static String? loadKg(double? v) {
    if (v == null || v < 0) return 'Load can’t be negative';
    if (v > 400) return 'Max 400 kg';
    return null;
  }

  static String? mealText(String? v) {
    final t = v?.trim() ?? '';
    if (t.isEmpty) return 'Describe the meal';
    if (t.length > 500) return 'Keep it under 500 characters';
    return null;
  }

  /// Macros must roughly add up (4/4/9 kcal per g, ±25% or ±60 kcal).
  static String? macros({
    required int kcal,
    required double p,
    required double c,
    required double f,
  }) {
    if (kcal < 0 || p < 0 || c < 0 || f < 0) return 'Values can’t be negative';
    if (kcal > 5000) return 'Max 5000 kcal per meal';
    final fromMacros = p * 4 + c * 4 + f * 9;
    final tolerance = (kcal * 0.25).clamp(60, 1000);
    if ((fromMacros - kcal).abs() > tolerance)
      return 'Calories don’t match the macros';
    return null;
  }

  static final _promo = RegExp(r'^[A-Z0-9-]{4,40}$');

  /// Normalises a promo code the same way the server does.
  static String? normalizePromo(String raw) {
    final c = raw.replaceAll(RegExp(r'\s+'), '').toUpperCase();
    return _promo.hasMatch(c) ? c : null;
  }

  static String? email(String? v) {
    final t = v?.trim() ?? '';
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(t))
      return 'Enter a valid email';
    return null;
  }

  static String? password(String? v) {
    if ((v ?? '').length < 8) return 'At least 8 characters';
    return null;
  }

  static String? chatMessage(String? v) {
    final t = v?.trim() ?? '';
    if (t.isEmpty) return '';
    if (t.length > 2000) return 'Keep it under 2000 characters';
    return null;
  }
}
