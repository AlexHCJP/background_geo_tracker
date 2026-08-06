import 'package:attractor_geo/src/geo_channel.dart';
import 'package:attractor_geo/src/geo_permission.dart';
import 'package:attractor_geo/src/geo_point.dart';
import 'package:attractor_geo/src/geo_tracking_status.dart';
import 'package:attractor_geo/src/geo_upload_config.dart';
import 'package:flutter/services.dart';

/// The Dart side of the tracker: configure it, start and stop sessions, and
/// watch what it is doing.
///
/// Collection and upload happen entirely in native code, so everything here
/// keeps working while this isolate is dead. The two streams exist only to
/// drive UI while the app is open.
class AttractorGeoController {
  AttractorGeoController({
    required MethodChannel methodChannel,
    required EventChannel pointsChannel,
    required EventChannel statusChannel,
  }) : _methods = methodChannel,
       _points = pointsChannel,
       _status = statusChannel;

  factory AttractorGeoController.standard() => AttractorGeoController(
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

  late final Stream<GeoTrackingStatus> statusChanges = _status
      .receiveBroadcastStream()
      .map(
        (event) => GeoTrackingStatus.fromMap(event as Map<Object?, Object?>),
      );
}
