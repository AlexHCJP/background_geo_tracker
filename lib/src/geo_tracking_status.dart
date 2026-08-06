import 'package:background_geo_tracker/src/geo_permission.dart';

/// Everything a screen needs to explain honestly why the track is, or is not,
/// being written.
class GeoTrackingStatus {
  /// Every field required: a status assembled with something left out would
  /// report a reassuring default for the one thing that is actually wrong.
  const GeoTrackingStatus({
    required this.isTracking,
    required this.permission,
    required this.authFailed,
    required this.queuedPoints,
    required this.locationServicesEnabled,
  });

  /// Decodes what both the `status` call and the status channel send — one
  /// shape, so a polled status and a pushed one cannot disagree.
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

  /// What the OS currently grants. Only [GeoPermission.always] keeps a session
  /// alive once the app is backgrounded.
  final GeoPermission permission;

  /// The backend rejected our credentials. Uploading is halted, collection
  /// continues, and fresh headers resume the drain.
  final bool authFailed;

  /// How many points are waiting to be uploaded.
  final int queuedPoints;

  /// Whether location is switched on device-wide.
  final bool locationServicesEnabled;
}
