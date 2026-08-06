import 'package:background_geo_tracker/background_geo_tracker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('school.attractor/geo');
  const pointsChannel = EventChannel('school.attractor/geo/points');
  const statusChannel = EventChannel('school.attractor/geo/status');

  late List<MethodCall> calls;

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

  setUp(() {
    calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'status' => statusPayload,
            'requestPermission' => 'when_in_use',
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
      baseUrl: 'https://api.attractor.school',
      path: '/v1/tracking/points',
      headers: const <String, String>{'Authorization': 'Bearer token'},
      notificationTitle: 'Tracking',
      notificationBody: 'Recording your route',
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

  test('requestPermission decodes the returned permission name', () async {
    expect(await controller().requestPermission(), GeoPermission.whenInUse);
  });

  test('points is built once, not re-subscribed on every access', () {
    final geo = controller();

    expect(identical(geo.points, geo.points), isTrue);
    expect(identical(geo.statusChanges, geo.statusChanges), isTrue);
  });
}
