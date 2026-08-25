import 'package:background_geo_tracker/background_geo_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  GeoUploadConfig standard() => GeoUploadConfig.standard(
    sessionId: 'consent-42',
    url: 'https://api.attractor.school/v1/tracking/points',
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
      'session_id': 'consent-42',
      'url': 'https://api.attractor.school/v1/tracking/points',
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

  test('rejects unsafe or nonsensical configurations', () {
    expect(
      () => GeoUploadConfig.standard(
        sessionId: '',
        url: 'http://api.example.com/points',
        headers: const <String, String>{},
        notificationTitle: 'Tracking',
        notificationBody: 'Recording',
      ),
      throwsArgumentError,
    );
    expect(
      () => GeoUploadConfig.standard(
        sessionId: 'consent-42',
        url: 'https://api.example.com/points',
        headers: const <String, String>{},
        notificationTitle: 'Tracking',
        notificationBody: 'Recording',
        batchSize: 0,
      ),
      throwsArgumentError,
    );
  });
}
