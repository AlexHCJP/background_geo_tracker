import 'package:background_geo_tracker/src/geo_permission.dart';

/// Everything a screen needs to explain honestly why the track is, or is not,
/// being written.
class GeoTrackingStatus {
  /// Every field required: a status assembled with something left out would
  /// report a reassuring default for the one thing that is actually wrong.
  const GeoTrackingStatus({
    required this.isTracking,
    required this.collectorRunning,
    required this.permission,
    required this.authFailed,
    required this.queuedPoints,
    required this.locationServicesEnabled,
    required this.uploadUrl,
    required this.lastUpload,
  });

  /// Decodes what both the `status` call and the status channel send — one
  /// shape, so a polled status and a pushed one cannot disagree.
  ///
  /// [uploadUrl] and [lastUpload] fall back rather than assert, because a
  /// platform that has not implemented them yet must still produce a usable
  /// status — everything else here is what keeps a session honest, and losing
  /// all of it to a missing diagnostic would be the wrong trade.
  factory GeoTrackingStatus.fromMap(Map<Object?, Object?> map) =>
      GeoTrackingStatus(
        isTracking: map['is_tracking']! as bool,
        collectorRunning: map['collector_running'] as bool? ?? false,
        permission: geoPermissionFromName(map['permission']! as String),
        authFailed: map['auth_failed']! as bool,
        queuedPoints: map['queued_points']! as int,
        locationServicesEnabled: map['location_services_enabled']! as bool,
        uploadUrl: map['upload_url'] as String? ?? '',
        lastUpload: map['last_upload'] as String? ?? 'unknown',
      );

  /// Whether a tracking session is currently running.
  final bool isTracking;

  /// Whether the native collector is alive right now. [isTracking] is the
  /// persisted user intent that survives process death; this is the runtime
  /// fact, so the UI can distinguish “will resume” from “currently sending”.
  final bool collectorRunning;

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

  /// The endpoint the native uploader currently holds — what it would actually
  /// POST to, not what the app believes it configured.
  ///
  /// Reported because those two can differ and nothing else can tell. The
  /// config is stored natively and outlives the process, so a session started
  /// under an older build keeps whatever it was given then; the app has no
  /// other way to notice, and the symptom — a growing queue on a collector
  /// that reports itself perfectly healthy — looks nothing like a wrong
  /// address. Empty means the uploader was never configured, and every drain
  /// it attempts fails before the request is built.
  final String uploadUrl;

  /// How the last drain attempt ended, in a few words: `ok`, `no url`,
  /// `http 500`, `network`, `auth`, and `never` before the first one.
  ///
  /// The uploader gives up at five different guards and, without this, does so
  /// in silence at every one of them — which makes "the queue is not draining"
  /// a question no log can answer.
  final String lastUpload;
}
