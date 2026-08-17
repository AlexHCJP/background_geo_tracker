// Runs inside a real app on a real device, so unlike the unit tests these
// exercise the actual Kotlin and Swift implementations across the platform
// channel.
//
// That is the point: a method name that disagrees between Dart and native, or
// a payload key the native side spells differently, is invisible to every
// other test in this package and fails loudly here.
//
// Neither test needs a location permission — both stay on the read-only and
// configuration paths, so they can run unattended.

import 'package:background_geo_tracker/background_geo_tracker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('status round-trips through the native plugin', (tester) async {
    final geo = BackgroundGeoTracker.standard();

    final status = await geo.status();

    // The values matter less than the fact that the call reached native code
    // and decoded: a wrong channel name, an unimplemented method or a missing
    // status key all fail on this line.
    expect(status.isTracking, isFalse);
    expect(status.authFailed, isFalse);
    expect(status.queuedPoints, isNonNegative);
  });

  testWidgets('configure is accepted by the native layer', (tester) async {
    final geo = BackgroundGeoTracker.standard();

    await geo.configure(
      GeoUploadConfig.standard(
        url: 'https://example.invalid/v1/tracking/points',
        headers: const <String, String>{'Authorization': 'Bearer test'},
        notificationTitle: 'Tracking',
        notificationBody: 'Recording your route',
      ),
    );

    // Returning without a PlatformException means every key the native side
    // reads was present and of the type it expected — the failure mode that
    // a bad cast in the config store produces.
    final status = await geo.status();
    expect(status.isTracking, isFalse);
  });
}
