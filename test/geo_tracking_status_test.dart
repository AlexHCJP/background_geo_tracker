import 'package:background_geo_tracker/background_geo_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fromMap decodes a tracking status', () {
    final status = GeoTrackingStatus.fromMap(const <Object?, Object?>{
      'is_tracking': true,
      'collector_running': true,
      'permission': 'always',
      'auth_failed': false,
      'queued_points': 42,
      'location_services_enabled': true,
    });

    expect(status.isTracking, isTrue);
    expect(status.collectorRunning, isTrue);
    expect(status.permission, GeoPermission.always);
    expect(status.authFailed, isFalse);
    expect(status.queuedPoints, 42);
    expect(status.locationServicesEnabled, isTrue);
  });

  test('fromMap maps every permission name', () {
    GeoPermission decode(String name) =>
        GeoTrackingStatus.fromMap(<Object?, Object?>{
          'is_tracking': false,
          'permission': name,
          'auth_failed': false,
          'queued_points': 0,
          'location_services_enabled': true,
        }).permission;

    expect(decode('denied'), GeoPermission.denied);
    expect(decode('when_in_use'), GeoPermission.whenInUse);
    expect(decode('always'), GeoPermission.always);
    expect(decode('permanently_denied'), GeoPermission.permanentlyDenied);
  });

  test('fromMap falls back to denied for an unknown permission name', () {
    final status = GeoTrackingStatus.fromMap(const <Object?, Object?>{
      'is_tracking': false,
      'permission': 'something_new',
      'auth_failed': false,
      'queued_points': 0,
      'location_services_enabled': true,
    });

    expect(status.permission, GeoPermission.denied);
  });
}
