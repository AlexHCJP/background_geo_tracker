import 'package:background_geo_tracker/background_geo_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fromMap decodes a full point', () {
    final point = GeoPoint.fromMap(const <Object?, Object?>{
      'id': 'b7e4',
      'lat': 55.751244,
      'lon': 37.618423,
      'accuracy': 8.5,
      'altitude': 156.0,
      'speed': 4.2,
      'heading': 271.0,
      'recorded_at': '2026-08-02T10:15:03Z',
      'is_mock': false,
      'battery_level': 0.62,
    });

    expect(point.id, 'b7e4');
    expect(point.latitude, 55.751244);
    expect(point.longitude, 37.618423);
    expect(point.accuracy, 8.5);
    expect(point.altitude, 156.0);
    expect(point.speed, 4.2);
    expect(point.heading, 271.0);
    expect(point.recordedAt, DateTime.utc(2026, 8, 2, 10, 15, 3));
    expect(point.recordedAt.isUtc, isTrue);
    expect(point.isMock, isFalse);
    expect(point.batteryLevel, 0.62);
  });

  test('fromMap keeps optional sensor fields null when absent', () {
    final point = GeoPoint.fromMap(const <Object?, Object?>{
      'id': 'b7e4',
      'lat': 55.75,
      'lon': 37.61,
      'accuracy': 12.0,
      'altitude': null,
      'speed': null,
      'heading': null,
      'recorded_at': '2026-08-02T10:15:03Z',
      'is_mock': true,
      'battery_level': null,
    });

    expect(point.altitude, isNull);
    expect(point.speed, isNull);
    expect(point.heading, isNull);
    expect(point.batteryLevel, isNull);
    expect(point.isMock, isTrue);
  });

  test('fromMap widens integer channel values to double', () {
    final point = GeoPoint.fromMap(const <Object?, Object?>{
      'id': 'b7e4',
      'lat': 55,
      'lon': 37,
      'accuracy': 12,
      'altitude': null,
      'speed': null,
      'heading': null,
      'recorded_at': '2026-08-02T10:15:03Z',
      'is_mock': false,
      'battery_level': null,
    });

    expect(point.latitude, 55.0);
    expect(point.accuracy, 12.0);
  });
}
