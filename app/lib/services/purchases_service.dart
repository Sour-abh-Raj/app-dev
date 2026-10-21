import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/config.dart';
import '../domain/access.dart';

/// Paywall placements → RevenueCat offering identifiers (§7).
enum Placement { onboarding, settings, winback, weeklyEntry, trialEnd, cap }

extension PlacementX on Placement {
  String get offeringId => switch (this) {
    Placement.onboarding => 'onboarding',
    Placement.settings => 'settings',
    Placement.winback => 'winback',
    Placement.weeklyEntry => 'weekly_entry',
    // Trial-end and cap upsells show the full settings offering.
    Placement.trialEnd => 'settings',
    Placement.cap => 'settings',
  };

  static Placement parse(String? s) => switch (s) {
    'onboarding' => Placement.onboarding,
    'winback' => Placement.winback,
    'weekly_entry' => Placement.weeklyEntry,
    'trial_end' => Placement.trialEnd,
    _ when (s ?? '').startsWith('cap') => Placement.cap,
    _ => Placement.settings,
  };
}

enum Period { weekly, monthly, annual }

/// One purchasable option as the paywall renders it.
class Tile {
  const Tile({
    required this.id,
    required this.period,
    required this.price,
    required this.priceValue,
    required this.currency,
    this.trialDays,
    this.introPrice,
    this.native,
  });

  final String id;
  final Period period;
  final String price; // localized, e.g. "$79.99"
  final double priceValue;
  final String currency;
  final int? trialDays;
  final String? introPrice; // winback: "$39.99 first year"
  final Object? native; // RevenueCat Package

  /// Annual per-month anchor ("$6.67/mo").
  String? get perMonth => period == Period.annual
      ? '${_symbol(price)}${(priceValue / 12).toStringAsFixed(2)}/mo'
      : null;

  static String _symbol(String price) =>
      price.replaceAll(RegExp(r'[\d.,\s]'), '');
}

class PurchaseOutcome {
  const PurchaseOutcome({required this.entitlement, required this.cancelled});
  final Entitlement entitlement;
  final bool cancelled;
}

abstract class PurchasesService {
  Future<void> configure();
  Future<void> logIn(String uid);
  Future<void> logOut();
  Future<List<Tile>> tiles(Placement placement);
  Future<PurchaseOutcome> purchase(Tile tile);
  Future<Entitlement> restore();
  Future<Entitlement> refresh();
  Stream<Entitlement> get updates;
  Future<void> presentStoreRedemption({String? code});
  Future<void> manageSubscription();
}

Entitlement entitlementFromCustomerInfo(CustomerInfo info, DateTime now) {
  final e = info.entitlements.all['pro'];
  final active = info.entitlements.active['pro'];
  return Entitlement(
    pro: active != null,
    trial: active?.periodType == PeriodType.trial,
    expiresAt: DateTime.tryParse(
      active?.expirationDate ?? e?.expirationDate ?? '',
    ),
    productId: e?.productIdentifier,
    billingIssue: (active?.billingIssueDetectedAt ?? '').isNotEmpty,
    willRenew: active?.willRenew ?? false,
    everSubscribed: e != null,
    promo: active?.store == Store.promotional,
    fetchedAt: now,
  );
}

/// RevenueCat is the only purchase path (no raw StoreKit/Billing).
class RevenueCatService implements PurchasesService {
  final _updates = StreamController<Entitlement>.broadcast();

  @override
  Stream<Entitlement> get updates => _updates.stream;

  @override
  Future<void> configure() async {
    if (kDebugMode) await Purchases.setLogLevel(LogLevel.debug);
    await Purchases.configure(PurchasesConfiguration(AppConfig.revenueCatKey));
    Purchases.addCustomerInfoUpdateListener(
      (info) => _updates.add(entitlementFromCustomerInfo(info, DateTime.now())),
    );
  }

  @override
  Future<void> logIn(String uid) async {
    final r = await Purchases.logIn(uid);
    _updates.add(entitlementFromCustomerInfo(r.customerInfo, DateTime.now()));
  }

  @override
  Future<void> logOut() async {
    try {
      await Purchases.logOut();
    } on PlatformException {
      // Already anonymous.
    }
  }

  @override
  Future<List<Tile>> tiles(Placement placement) async {
    final offerings = await Purchases.getOfferings();
    final o = offerings.getOffering(placement.offeringId) ?? offerings.current;
    if (o == null) return const [];
    return [
      for (final p in o.availablePackages)
        if (_period(p.packageType) != null)
          Tile(
            id: p.identifier,
            period: _period(p.packageType)!,
            price: p.storeProduct.priceString,
            priceValue: p.storeProduct.price,
            currency: p.storeProduct.currencyCode,
            trialDays: _trialDays(p.storeProduct),
            introPrice:
                p.storeProduct.introductoryPrice != null &&
                    p.storeProduct.introductoryPrice!.price > 0
                ? p.storeProduct.introductoryPrice!.priceString
                : null,
            native: p,
          ),
    ];
  }

  static Period? _period(PackageType t) => switch (t) {
    PackageType.weekly => Period.weekly,
    PackageType.monthly => Period.monthly,
    PackageType.annual => Period.annual,
    _ => null,
  };

  static int? _trialDays(StoreProduct p) {
    final intro = p.introductoryPrice;
    if (intro == null || intro.price != 0) return null;
    final n = intro.periodNumberOfUnits * intro.cycles;
    return switch (intro.periodUnit) {
      PeriodUnit.day => n,
      PeriodUnit.week => n * 7,
      PeriodUnit.month => n * 30,
      _ => null,
    };
  }

  @override
  Future<PurchaseOutcome> purchase(Tile tile) async {
    try {
      final r = await Purchases.purchase(
        PurchaseParams.package(tile.native! as Package),
      );
      final e = entitlementFromCustomerInfo(r.customerInfo, DateTime.now());
      _updates.add(e);
      return PurchaseOutcome(entitlement: e, cancelled: false);
    } on PlatformException catch (e) {
      if (PurchasesErrorHelper.getErrorCode(e) ==
          PurchasesErrorCode.purchaseCancelledError) {
        return PurchaseOutcome(entitlement: await refresh(), cancelled: true);
      }
      rethrow;
    }
  }

  @override
  Future<Entitlement> restore() async {
    final e = entitlementFromCustomerInfo(
      await Purchases.restorePurchases(),
      DateTime.now(),
    );
    _updates.add(e);
    return e;
  }

  @override
  Future<Entitlement> refresh() async {
    final e = entitlementFromCustomerInfo(
      await Purchases.getCustomerInfo(),
      DateTime.now(),
    );
    _updates.add(e);
    return e;
  }

  @override
  Future<void> presentStoreRedemption({String? code}) async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      // Apple offer codes redeem in the system sheet (App Store Connect codes).
      await Purchases.presentCodeRedemptionSheet();
    } else {
      // Play promo codes redeem in the Play Store (they grant free trials only).
      final uri = Uri.parse(
        'https://play.google.com/redeem${code == null ? '' : '?code=$code'}',
      );
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Future<void> manageSubscription() async {
    final info = await Purchases.getCustomerInfo();
    final url =
        info.managementURL ??
        (defaultTargetPlatform == TargetPlatform.iOS
            ? 'https://apps.apple.com/account/subscriptions'
            : 'https://play.google.com/store/account/subscriptions');
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }
}

/// Debug-only store for the offline demo and tests. Never used in release.
class FakePurchasesService implements PurchasesService {
  FakePurchasesService({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  Entitlement _state = const Entitlement();
  final _updates = StreamController<Entitlement>.broadcast();
  final purchased = <String>[];

  @override
  Stream<Entitlement> get updates => _updates.stream;

  void set(Entitlement e) {
    _state = e;
    _updates.add(e);
  }

  @override
  Future<void> configure() async {}

  @override
  Future<void> logIn(String uid) async => _updates.add(_state);

  @override
  Future<void> logOut() async => set(const Entitlement());

  @override
  Future<List<Tile>> tiles(Placement placement) async {
    const weekly = Tile(
      id: 'weekly',
      period: Period.weekly,
      price: r'$4.99',
      priceValue: 4.99,
      currency: 'USD',
      trialDays: 3,
    );
    const monthly = Tile(
      id: 'monthly',
      period: Period.monthly,
      price: r'$12.99',
      priceValue: 12.99,
      currency: 'USD',
      trialDays: 7,
    );
    const annual = Tile(
      id: 'annual',
      period: Period.annual,
      price: r'$79.99',
      priceValue: 79.99,
      currency: 'USD',
      trialDays: 7,
    );
    const winback = Tile(
      id: 'annual_winback',
      period: Period.annual,
      price: r'$79.99',
      priceValue: 79.99,
      currency: 'USD',
      introPrice: r'$39.99',
    );
    return switch (placement) {
      Placement.onboarding => const [annual, monthly],
      Placement.winback => const [winback],
      Placement.weeklyEntry => const [weekly],
      _ => const [annual, monthly, weekly],
    };
  }

  @override
  Future<PurchaseOutcome> purchase(Tile tile) async {
    assert(!kReleaseMode, 'FakePurchasesService must never run in release');
    purchased.add(tile.id);
    final now = _now();
    set(
      Entitlement(
        pro: true,
        trial: tile.trialDays != null,
        expiresAt: now.add(Duration(days: tile.trialDays ?? 365)),
        productId: tile.id,
        willRenew: true,
        everSubscribed: true,
        fetchedAt: now,
      ),
    );
    return PurchaseOutcome(entitlement: _state, cancelled: false);
  }

  @override
  Future<Entitlement> restore() async => _state;

  @override
  Future<Entitlement> refresh() async => _state;

  @override
  Future<void> presentStoreRedemption({String? code}) async {}

  @override
  Future<void> manageSubscription() async {}
}
