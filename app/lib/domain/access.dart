/// Entitlement state and feature gates (free forever / Pro / grace mode).
library;

enum Tier { free, pro, grace }

class Entitlement {
  const Entitlement({
    this.pro = false,
    this.trial = false,
    this.expiresAt,
    this.productId,
    this.billingIssue = false,
    this.willRenew = false,
    this.everSubscribed = false,
    this.winbackUntil,
    this.promo = false,
    this.fetchedAt,
  });

  final bool pro;
  final bool trial;
  final DateTime? expiresAt;
  final String? productId;
  final bool billingIssue;
  final bool willRenew;
  final bool everSubscribed;
  final DateTime? winbackUntil;
  final bool promo;
  final DateTime? fetchedAt;

  static const maxOfflineAge = Duration(days: 7);

  /// Pro only counts while the cached state is fresh enough (≤7 days offline).
  bool proAt(DateTime now) =>
      pro && (fetchedAt == null || now.difference(fetchedAt!) <= maxOfflineAge);

  Tier tierAt(DateTime now) {
    if (proAt(now)) return Tier.pro;
    return everSubscribed ? Tier.grace : Tier.free;
  }

  bool winbackEligible(DateTime now) =>
      !proAt(now) && winbackUntil != null && winbackUntil!.isAfter(now);

  Entitlement copyWith({
    bool? pro,
    bool? trial,
    DateTime? expiresAt,
    String? productId,
    bool? billingIssue,
    bool? willRenew,
    bool? everSubscribed,
    DateTime? winbackUntil,
    bool? promo,
    DateTime? fetchedAt,
  }) => Entitlement(
    pro: pro ?? this.pro,
    trial: trial ?? this.trial,
    expiresAt: expiresAt ?? this.expiresAt,
    productId: productId ?? this.productId,
    billingIssue: billingIssue ?? this.billingIssue,
    willRenew: willRenew ?? this.willRenew,
    everSubscribed: everSubscribed ?? this.everSubscribed,
    winbackUntil: winbackUntil ?? this.winbackUntil,
    promo: promo ?? this.promo,
    fetchedAt: fetchedAt ?? this.fetchedAt,
  );

  Map<String, dynamic> toJson() => {
    'pro': pro,
    'trial': trial,
    'expires_at': expiresAt?.toIso8601String(),
    'product_id': productId,
    'billing_issue': billingIssue,
    'will_renew': willRenew,
    'ever_subscribed': everSubscribed,
    'winback_until': winbackUntil?.toIso8601String(),
    'promo': promo,
    'fetched_at': fetchedAt?.toIso8601String(),
  };

  factory Entitlement.fromJson(Map<dynamic, dynamic> j) => Entitlement(
    pro: j['pro'] as bool? ?? false,
    trial: j['trial'] as bool? ?? false,
    expiresAt: _dt(j['expires_at']),
    productId: j['product_id'] as String?,
    billingIssue: j['billing_issue'] as bool? ?? false,
    willRenew: j['will_renew'] as bool? ?? false,
    everSubscribed: j['ever_subscribed'] as bool? ?? false,
    winbackUntil: _dt(j['winback_until']),
    promo: j['promo'] as bool? ?? false,
    fetchedAt: _dt(j['fetched_at']),
  );
}

DateTime? _dt(Object? v) => v is String ? DateTime.tryParse(v) : null;

/// What each tier may use. Grace mode == free allowances, with logs, photos
/// and streaks kept: users are never locked out of their own data.
class Access {
  const Access(this.tier);

  final Tier tier;

  bool get pro => tier == Tier.pro;

  // Free forever (habit layer) — every tier.
  bool get workoutLogger => true;
  bool get prGraphs => true;
  bool get photoCapture => true;
  bool get streaksAndReminders => true;
  bool get manualSideBySide => true;

  // Pro only.
  bool get adaptiveReplans => pro;
  bool get aiPhotoReports => pro;
  bool get timelineAndMorph => pro;
  bool get weeklyNutritionReports => pro;
  bool get futureRender => pro;

  /// AI meal logs per day (manual logging is always unlimited).
  int get aiMealsPerDay => pro ? 15 : 3;

  /// Coach messages: 5 total on free/grace, 20 per month on Pro.
  int get chatAllowance => pro ? 20 : 5;
  bool get chatAllowanceIsMonthly => pro;
}
