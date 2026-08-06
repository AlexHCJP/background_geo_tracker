import 'package:attractor_geo/attractor_geo.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  GeoUploadConfig standard() => GeoUploadConfig.standard(
    baseUrl: 'https://api.attractor.school',
    path: '/v1/tracking/points',
    headers: const <String, String>{'Authorization': 'Bearer token'},
    notificationTitle: 'Tracking',
    notificationBody: 'Recording your route',
  );

  test('standard carries the tuned defaults from the design', () {
    final config = standard();

    expect(config.distanceFilterMeters, 20);
    expect(config.minIntervalSeconds, 10);
    expect(config.batchSize, 50);
    expect(config.uploadIntervalSeconds, 60);
    expect(config.queueMaxPoints, 20000);
    expect(config.queueMaxAgeDays, 7);
  });

  test('toMap uses the wire keys the native layer reads', () {
    expect(standard().toMap(), <String, Object?>{
      'base_url': 'https://api.attractor.school',
      'path': '/v1/tracking/points',
      'headers': <String, String>{'Authorization': 'Bearer token'},
      'distance_filter_meters': 20,
      'min_interval_seconds': 10,
      'batch_size': 50,
      'upload_interval_seconds': 60,
      'queue_max_points': 20000,
      'queue_max_age_days': 7,
      'notification_title': 'Tracking',
      'notification_body': 'Recording your route',
    });
  });
}
