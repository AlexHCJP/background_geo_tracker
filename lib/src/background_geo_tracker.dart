import 'package:background_geo_tracker/src/geo_channel.dart';
import 'package:background_geo_tracker/src/geo_permission.dart';
import 'package:background_geo_tracker/src/geo_point.dart';
import 'package:background_geo_tracker/src/geo_tracking_status.dart';
import 'package:background_geo_tracker/src/geo_upload_config.dart';
import 'package:flutter/services.dart';

/// The Dart side of the tracker: configure it, start and stop sessions, and
/// watch what it is doing.
///
/// Collection and upload happen entirely in native code, so everything here
/// keeps working while this isolate is dead. The two streams exist only to
/// drive UI while the app is open.
class BackgroundGeoTracker {
  /// Takes its three channels, so a test can drive the tracker without a
  /// platform under it. App code wants [BackgroundGeoTracker.standard].
  BackgroundGeoTracker({
    required MethodChannel methodChannel,
    required EventChannel pointsChannel,
    required EventChannel statusChannel,
  }) : _methods = methodChannel,
       _points = pointsChannel,
       _status = statusChannel;

  /// Wired to the channels the native implementations actually listen on.
  factory BackgroundGeoTracker.standard() => BackgroundGeoTracker(
    methodChannel: geoMethodChannel,
    pointsChannel: geoPointsChannel,
    statusChannel: geoStatusChannel,
  );

  final MethodChannel _methods;
  final EventChannel _points;
  final EventChannel _status;

  /// Hands the native layer its URL, headers and policy. Safe to call again
  /// with fresh headers — that is how a session recovers from `authFailed`.
  Future<void> configure(GeoUploadConfig config) =>
      _methods.invokeMethod<void>('configure', config.toMap());

  /// Begins a tracking session. The session survives app restarts because the
  /// native layer persists this state, not Dart.
  Future<void> start() => _methods.invokeMethod<void>('start');

  /// Ends the session and shuts the collector down for real — no notification,
  /// no wake-ups, no battery drain. Queued points survive and go out on the
  /// next session.
  Future<void> stop() => _methods.invokeMethod<void>('stop');

  /// Ends the session and forgets everything that belonged to whoever was
  /// signed in: the stored credentials and every queued point.
  ///
  /// [stop] is not enough on its own. The headers live natively in encrypted
  /// storage precisely so the uploader can work with no Dart isolate alive,
  /// and the queue outlives a session by design — so after a sign-out both
  /// would still be there for whoever signs in next on this device, and a
  /// drain already scheduled by the OS would upload one user's track under
  /// another's credentials.
  ///
  /// Deliberately kept out of [stop]: ending a session is routine and its
  /// queue is worth keeping, while this throws data away.
  Future<void> reset() => _methods.invokeMethod<void>('reset');

  /// Where the device is now, read once.
  ///
  /// [points] is a stream of *changes*: a fix reaches it only once the device
  /// has moved `distanceFilterMeters`, so a listener that subscribes while the
  /// phone sits on a desk can wait minutes for its first one — and whatever
  /// was collected before it subscribed is gone, because collection does not
  /// wait for a listener. A map has nothing to centre on for all that time.
  /// This is the "where am I" that stream cannot answer.
  ///
  /// Hands back the platform's own cached fix when that fix is recent, which
  /// costs nothing and returns at once; otherwise asks the OS for a fresh one
  /// and waits up to [timeout], falling back to a stale cached fix rather than
  /// to nothing. Null when the permission has not been granted, when location
  /// services are off, and when nothing arrives in time.
  ///
  /// A read, not a recording: the point is neither queued for upload nor
  /// pushed onto [points], so asking never adds to the track.
  Future<GeoPoint?> currentPosition({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final map = await _methods.invokeMapMethod<Object?, Object?>(
      'currentPosition',
      <String, Object?>{'timeout_seconds': timeout.inSeconds},
    );
    return map == null ? null : GeoPoint.fromMap(map);
  }

  /// The current state, read once. [statusChanges] is what follows it; this is
  /// for the first paint, before anything has had a chance to change.
  Future<GeoTrackingStatus> status() async {
    final map = await _methods.invokeMapMethod<Object?, Object?>('status');
    return GeoTrackingStatus.fromMap(map!);
  }

  /// Escalates one step: no permission asks for foreground, foreground asks
  /// for background. Asking for background outright is shown by iOS as
  /// "allow once" with no upgrade path.
  Future<GeoPermission> requestPermission() async {
    final name = await _methods.invokeMethod<String>('requestPermission');
    return geoPermissionFromName(name!);
  }

  /// Opens this app's page in the system settings. The only way out of
  /// [GeoPermission.permanentlyDenied], where no prompt can be shown any more.
  Future<void> openSystemSettings() =>
      _methods.invokeMethod<void>('openSystemSettings');

  /// Live points, for drawing a map or a debug readout. Points are uploaded
  /// natively whether or not anyone listens here.
  ///
  /// Built once and reused: `receiveBroadcastStream` mints a fresh stream per
  /// call, and each one re-runs the native `onListen`. The native event bus
  /// holds a single sink, so a second stream would silently steal the first
  /// one's events.
  late final Stream<GeoPoint> points = _points.receiveBroadcastStream().map(
    (event) => GeoPoint.fromMap(event as Map<Object?, Object?>),
  );

  /// Every transition the native layer reports: a session started or ended, a
  /// permission dialog answered, permission revoked mid-session, a credential
  /// the backend refused.
  ///
  /// Built once and reused, for the same reason as [points].
  late final Stream<GeoTrackingStatus> statusChanges = _status
      .receiveBroadcastStream()
      .map(
        (event) => GeoTrackingStatus.fromMap(event as Map<Object?, Object?>),
      );
}
