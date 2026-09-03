import 'package:background_geo_tracker/background_geo_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fromMap decodes a tracking status', () {
    final status = GeoTrackingStatus.fromMap(const <Object?, Object?>{
      'is_tracking': true,
      'permission': 'always',
      'auth_failed': false,
      'queued_points': 42,
      'location_services_enabled': true,
    });

    expect(status.isTracking, isTrue);
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

  test('fromMap decodes the motion state', () {
    final status = GeoTrackingStatus.fromMap(const <Object?, Object?>{
      'is_tracking': true,
      'permission': 'always',
      'auth_failed': false,
      'queued_points': 0,
      'location_services_enabled': true,
      'is_moving': false,
      'motion_permission': 'granted',
    });

    expect(status.isMoving, isFalse);
    expect(status.motionPermission, GeoMotionPermission.granted);
  });

  test('a platform that does not report motion still produces a status', () {
    // The fallbacks are the harmless reading, as everywhere else here: a build
    // that cannot answer has not thereby discovered that the collector is
    // asleep, and it has no detector to ask permission for.
    final status = GeoTrackingStatus.fromMap(const <Object?, Object?>{
      'is_tracking': true,
      'permission': 'always',
      'auth_failed': false,
      'queued_points': 0,
      'location_services_enabled': true,
    });

    expect(status.isMoving, isTrue);
    expect(status.motionPermission, GeoMotionPermission.unavailable);
  });

  test('an unknown motion permission name degrades to unavailable', () {
    // Not `denied`: denied is a state the UI offers to fix by prompting, and
    // prompting on a name we failed to understand would be a dialog nobody
    // can act on.
    expect(
      geoMotionPermissionFromName('something_new'),
      GeoMotionPermission.unavailable,
    );
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
