import 'package:attractor_geo/src/geo_permission.dart';

/// Everything a screen needs to explain honestly why the track is, or is not,
/// being written.
class GeoTrackingStatus {
  const GeoTrackingStatus({
    required this.isTracking,
    required this.permission,
    required this.authFailed,
    required this.queuedPoints,
    required this.locationServicesEnabled,
  });

  factory GeoTrackingStatus.fromMap(Map<Object?, Object?> map) =>
      GeoTrackingStatus(
        isTracking: map['is_tracking']! as bool,
        permission: geoPermissionFromName(map['permission']! as String),
        authFailed: map['auth_failed']! as bool,
        queuedPoints: map['queued_points']! as int,
        locationServicesEnabled: map['location_services_enabled']! as bool,
      );

  /// Whether a tracking session is currently running.
  final bool isTracking;

  final GeoPermission permission;

  /// The backend rejected our credentials. Uploading is halted, collection
  /// continues, and fresh headers resume the drain.
  final bool authFailed;

  /// How many points are waiting to be uploaded.
  final int queuedPoints;

  /// Whether location is switched on device-wide.
  final bool locationServicesEnabled;
}
