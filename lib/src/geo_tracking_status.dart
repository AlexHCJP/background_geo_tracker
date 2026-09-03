import 'package:background_geo_tracker/src/geo_motion_permission.dart';
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
    required this.uploadUrl,
    required this.lastUpload,
    required this.preciseLocation,
    required this.needsBackgroundRationale,
    required this.powerSaveMode,
    required this.ignoringBatteryOptimizations,
    required this.isMoving,
    required this.motionPermission,
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
        permission: geoPermissionFromName(map['permission']! as String),
        authFailed: map['auth_failed']! as bool,
        queuedPoints: map['queued_points']! as int,
        locationServicesEnabled: map['location_services_enabled']! as bool,
        uploadUrl: map['upload_url'] as String? ?? '',
        lastUpload: map['last_upload'] as String? ?? 'unknown',
        // The four below fall back the same way, and each falls back to the
        // *harmless* reading rather than the alarming one: a platform that
        // has not implemented a diagnostic has not thereby discovered a
        // problem, and a panel that warns about reduced accuracy on a build
        // that cannot measure it teaches the user to ignore the panel.
        preciseLocation: map['precise_location'] as bool? ?? true,
        needsBackgroundRationale:
            map['needs_background_rationale'] as bool? ?? false,
        powerSaveMode: map['power_save_mode'] as bool? ?? false,
        ignoringBatteryOptimizations:
            map['ignoring_battery_optimizations'] as bool? ?? true,
        // Both fall back the way the four above do, to the reading that
        // reports no problem: a platform that cannot answer has not found the
        // collector asleep, and has no detector to be refused.
        isMoving: map['is_moving'] as bool? ?? true,
        motionPermission: geoMotionPermissionFromName(
          map['motion_permission'] as String? ?? 'unavailable',
        ),
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

  /// Whether the OS is handing over real coordinates or a rough area.
  ///
  /// False is the permission failure that does not look like one. Both
  /// platforms let a user grant location while withholding precision — iOS 14
  /// as *Approximate*, Android 12 as the coarse half of the runtime prompt —
  /// and in both cases the permission reads as granted, points keep arriving,
  /// and every one of them is off by a kilometre or more. Nothing else in this
  /// status says so: [permission] is satisfied, [isTracking] is true, and the
  /// queue drains.
  final bool preciseLocation;

  /// Whether the app owes the user an explanation before sending them to
  /// system settings for background location.
  ///
  /// Android 11 removed "Allow all the time" from the runtime prompt: the only
  /// way there is the settings screen, and Google requires an educational
  /// screen first. True exactly while that step is the outstanding one — the
  /// foreground permission is granted, the background one is not, and the OS
  /// will not prompt for it. Always false on iOS, which prompts for `Always`
  /// itself and needs nothing explained on its behalf.
  final bool needsBackgroundRationale;

  /// Whether the device is in its battery saver mode.
  ///
  /// Not fatal on either platform, and not something the app can switch off —
  /// reported because it is the ordinary explanation for fixes arriving slower
  /// than [GeoUploadConfig.minIntervalSeconds] would suggest, and a session
  /// that looks throttled for no reason is one somebody will go looking for a
  /// bug in.
  final bool powerSaveMode;

  /// Whether Android will leave this app alone when the screen is off.
  ///
  /// False means the app sits under Doze's standard restrictions, which is
  /// where a background collector quietly loses its wake-ups. Always true on
  /// iOS, which has no equivalent exemption to grant.
  final bool ignoringBatteryOptimizations;

  /// Whether the collector is currently asking for fixes.
  ///
  /// False is not a fault: it means the device has stood inside
  /// [GeoMotionConfig.stationaryRadiusMeters] for longer than
  /// [GeoMotionConfig.stopTimeoutSeconds] and the GPS was switched off until
  /// it moves again. Worth showing, because it is the honest answer to "why
  /// has my position not changed" and the only field that gives it — a
  /// stationary session is tracking, permitted, and drawing nothing.
  final bool isMoving;

  /// Whether the fast movement detector is running.
  ///
  /// [GeoMotionPermission.denied] is the one that costs something visible: the
  /// collector then wakes only on the geofence, so the first ~200 m after
  /// leaving are missing from the track. That is a complaint ("the route
  /// starts two blocks from my house") whose cause is invisible everywhere
  /// else.
  final GeoMotionPermission motionPermission;
}
