import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:forme/app/router.dart';
import 'package:forme/domain/access.dart';
import 'package:forme/services/device_services.dart';
import 'package:forme/services/photo_service.dart';
import 'package:forme/services/purchases_service.dart';
import 'package:image/image.dart' as img;

void main() {
  group('photo pipeline', () {
    Uint8List jpeg(int w, int h, {bool exif = true}) {
      final im = img.Image(width: w, height: h);
      img.fill(im, color: img.ColorRgb8(200, 120, 90));
      if (exif) {
        im.exif.imageIfd['Make'] = img.IfdValueAscii('PhoneCo');
        im.exif.gpsIfd['GPSLatitude'] = img.IfdValueRational(51, 1);
      }
      return img.encodeJpg(im);
    }

    test('downscales, strips EXIF/GPS', () {
      final out = PhotoService.processJpeg(jpeg(3000, 2000), 1024, null);
      final d = img.decodeJpg(out)!;
      expect(d.width, 1024);
      expect(d.exif.isEmpty, isTrue);
    });

    test('portrait keeps aspect and small images are untouched in size', () {
      final d = img.decodeJpg(
        PhotoService.processJpeg(jpeg(1000, 3000), 2048, null),
      )!;
      expect((d.width, d.height), (683, 2048));
      final s = img.decodeJpg(
        PhotoService.processJpeg(jpeg(400, 300), 1024, null),
      )!;
      expect((s.width, s.height), (400, 300));
    });

    test('face blur changes only the face region', () {
      final im = img.Image(width: 200, height: 200);
      for (var y = 0; y < 200; y++) {
        for (var x = 0; x < 200; x++) {
          im.setPixelRgb(
            x,
            y,
            (x * 7) % 256,
            (y * 5) % 256,
            ((x + y) * 3) % 256,
          );
        }
      }
      final src = img.encodeJpg(im, quality: 100);
      final plain = img.decodeJpg(PhotoService.processJpeg(src, 1024, null))!;
      final blurred = img.decodeJpg(
        PhotoService.processJpeg(
          src,
          1024,
          const Rect.fromLTWH(0.25, 0.0, 0.5, 0.4),
        ),
      )!;
      num diff(int x, int y) =>
          (plain.getPixel(x, y).r - blurred.getPixel(x, y).r).abs();
      expect(diff(100, 20) + diff(80, 40) + diff(120, 60), greaterThan(20));
      expect(diff(10, 190), lessThan(12));
    });

    test('rejects non-images', () {
      expect(
        () =>
            PhotoService.processJpeg(Uint8List.fromList([1, 2, 3]), 1024, null),
        throwsFormatException,
      );
    });
  });

  group('purchases', () {
    test('placements map to §7 offerings', () {
      expect(PlacementX.parse('onboarding').offeringId, 'onboarding');
      expect(PlacementX.parse('winback').offeringId, 'winback');
      expect(PlacementX.parse('weekly_entry').offeringId, 'weekly_entry');
      expect(PlacementX.parse('cap_meal'), Placement.cap);
      expect(PlacementX.parse('trial_end'), Placement.trialEnd);
      expect(PlacementX.parse(null).offeringId, 'settings');
      expect(Placement.cap.offeringId, 'settings');
      expect(Placement.trialEnd.offeringId, 'settings');
    });

    test('annual shows a per-month anchor', () {
      const t = Tile(
        id: 'a',
        period: Period.annual,
        price: r'$79.99',
        priceValue: 79.99,
        currency: 'USD',
      );
      expect(t.perMonth, r'$6.67/mo');
      const m = Tile(
        id: 'm',
        period: Period.monthly,
        price: r'$12.99',
        priceValue: 12.99,
        currency: 'USD',
      );
      expect(m.perMonth, isNull);
    });

    test('fake store: offerings per placement, purchase → trial pro', () async {
      final f = FakePurchasesService(now: () => DateTime(2026, 10, 21));
      expect((await f.tiles(Placement.onboarding)).first.period, Period.annual);
      expect((await f.tiles(Placement.settings)).map((t) => t.period), [
        Period.annual,
        Period.monthly,
        Period.weekly,
      ]);
      expect(
        (await f.tiles(Placement.weeklyEntry)).single.period,
        Period.weekly,
      );
      expect((await f.tiles(Placement.winback)).single.introPrice, r'$39.99');
      final r = await f.purchase((await f.tiles(Placement.onboarding)).first);
      expect(r.entitlement.pro && r.entitlement.trial, isTrue);
      expect(r.entitlement.expiresAt, DateTime(2026, 10, 28));
      expect((await f.restore()).pro, isTrue);
      await f.logOut();
      expect((await f.refresh()).tierAt(DateTime(2026, 10, 21)), Tier.free);
    });
  });

  group('deep links', () {
    test('known links route; unknown are ignored', () {
      expect(deepLinkToLocation('forme://checkin'), '/checkin');
      expect(
        deepLinkToLocation('forme://paywall?placement=winback'),
        '/paywall?placement=winback',
      );
      expect(deepLinkToLocation('forme://settings/subscription'), '/settings');
      expect(deepLinkToLocation('forme://today'), '/today');
      expect(deepLinkToLocation('https://evil.example/x'), isNull);
      expect(deepLinkToLocation('forme://nowhere'), isNull);
    });
  });

  group('check-in reminder slot', () {
    test('converts local Sunday hour to the UTC weekday-hour slot', () {
      expect(checkinReminderSlot(9, Duration.zero), '0-09');
      expect(
        checkinReminderSlot(9, const Duration(hours: 5, minutes: 30)),
        '0-03',
      );
      expect(
        checkinReminderSlot(1, const Duration(hours: 3)),
        '6-22',
      ); // Saturday UTC
      expect(
        checkinReminderSlot(22, const Duration(hours: -5)),
        '1-03',
      ); // Monday UTC
    });
  });
}
