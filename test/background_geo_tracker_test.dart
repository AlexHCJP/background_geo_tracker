import 'package:background_geo_tracker/background_geo_tracker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('school.attractor/geo');
  const pointsChannel = EventChannel('school.attractor/geo/points');
  const statusChannel = EventChannel('school.attractor/geo/status');

  late List<MethodCall> calls;

  /// What the platform answers `currentPosition` with. A field rather than a
  /// constant because "the platform has nothing" is half of that contract.
  late Map<Object?, Object?>? position;

  /// What the platform answers `readLog` with. A field for the same reason
  /// [position] is one: "the log is empty" is half of that contract.
  late List<Object?>? logEntries;

  BackgroundGeoTracker controller() => BackgroundGeoTracker(
    methodChannel: methodChannel,
    pointsChannel: pointsChannel,
    statusChannel: statusChannel,
  );

  const statusPayload = <Object?, Object?>{
    'is_tracking': true,
    'permission': 'always',
    'auth_failed': false,
    'queued_points': 7,
    'location_services_enabled': true,
  };

  const positionPayload = <Object?, Object?>{
    'id': 'a5f1',
    'lat': 55.751244,
    'lon': 37.618423,
    'accuracy': 12.0,
    'altitude': 156.0,
    'speed': null,
    'heading': null,
    'recorded_at': '2026-08-12T09:15:00.000Z',
    'is_mock': false,
    'battery_level': 0.62,
  };

  setUp(() {
    calls = <MethodCall>[];
    position = positionPayload;
    logEntries = <Object?>[
      <Object?, Object?>{
        'id': 7,
        'at_millis': 1756000000000,
        'level': 'error',
        'event': 'upload.result',
        'message': 'http 500 in 240ms',
      },
    ];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'status' => statusPayload,
            'requestPermission' => 'when_in_use',
            'currentPosition' => position,
            'readLog' => logEntries,
            _ => null,
          };
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
  });

  test('configure forwards the serialized config', () async {
    final config = GeoUploadConfig.standard(
      url: 'https://api.attractor.school/v1/tracking/points',
      headers: const <String, String>{'Authorization': 'Bearer token'},
      notification: GeoNotificationConfig.standard(
        title: 'Tracking',
        body: 'Recording your route',
        channelName: 'Location tracking',
      ),
    );

    await controller().configure(config);

    expect(calls.single.method, 'configure');
    expect(calls.single.arguments, config.toMap());
  });

  test('start and stop invoke their methods with no arguments', () async {
    final geo = controller();

    await geo.start();
    await geo.stop();

    expect(calls.map((call) => call.method), <String>['start', 'stop']);
    expect(calls.every((call) => call.arguments == null), isTrue);
  });

  test('reset is its own call, not a stop in disguise', () async {
    await controller().reset();

    expect(calls.single.method, 'reset');
    expect(calls.single.arguments, isNull);
  });

  test('status decodes the native payload', () async {
    final status = await controller().status();

    expect(status.isTracking, isTrue);
    expect(status.permission, GeoPermission.always);
    expect(status.queuedPoints, 7);
  });

  test('currentPosition decodes the fix and carries its timeout', () async {
    final point = await controller().currentPosition(
      timeout: const Duration(seconds: 4),
    );

    expect(calls.single.method, 'currentPosition');
    expect(calls.single.arguments, <String, Object?>{'timeout_seconds': 4});
    expect(point!.latitude, 55.751244);
    expect(point.recordedAt.isUtc, isTrue);
  });

  test('currentPosition is null when the platform has no fix', () async {
    position = null;

    expect(await controller().currentPosition(), isNull);
  });

  test('requestPermission decodes the returned permission name', () async {
    expect(await controller().requestPermission(), GeoPermission.whenInUse);
  });

  test('points is built once, not re-subscribed on every access', () {
    final geo = controller();

    expect(identical(geo.points, geo.points), isTrue);
    expect(identical(geo.statusChanges, geo.statusChanges), isTrue);
  });

  test('readLog decodes the entries and carries its limit', () async {
    final entries = await controller().readLog(limit: 250);

    expect(calls.single.method, 'readLog');
    expect(calls.single.arguments, <String, Object?>{'limit': 250});
    expect(entries.single.id, 7);
    expect(entries.single.level, GeoLogLevel.error);
    expect(entries.single.event, 'upload.result');
  });

  test('an empty log decodes as an empty list, not null', () async {
    logEntries = null;

    expect(await controller().readLog(), isEmpty);
  });

  test('dropLog carries the cursor under the wire key', () async {
    await controller().dropLog(untilId: 91);

    expect(calls.single.method, 'dropLog');
    expect(calls.single.arguments, <String, Object?>{'until_id': 91});
  });
}
