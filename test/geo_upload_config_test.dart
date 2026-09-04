import 'package:background_geo_tracker/background_geo_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  GeoUploadConfig standard() => GeoUploadConfig.standard(
    sessionId: 'consent-42',
    url: 'https://api.attractor.school/v1/tracking/points',
    headers: const <String, String>{'Authorization': 'Bearer token'},
    notification: GeoNotificationConfig.standard(
      title: 'Tracking',
      body: 'Recording your route',
      channelName: 'Location tracking',
    ),
  );

  test('standard carries the tuned defaults from the design', () {
    final config = standard();

    expect(config.distanceFilterMeters, 20);
    expect(config.minIntervalSeconds, 10);
    expect(config.batchSize, 50);
    expect(config.uploadIntervalSeconds, 60);
    expect(config.queueMaxPoints, 20000);
    expect(config.queueMaxAgeDays, 7);
    expect(config.filter.accuracyThresholdMeters, 100);
    expect(config.filter.minDisplacementMeters, 1);
    expect(config.filter.maxImpliedSpeedMps, 60);
    expect(config.filter.kalmanProcessNoiseMps, 3);
  });

  test('toMap uses the wire keys the native layer reads', () {
    expect(standard().toMap(), <String, Object?>{
      'session_id': 'consent-42',
      'url': 'https://api.attractor.school/v1/tracking/points',
      'headers': <String, String>{'Authorization': 'Bearer token'},
      'distance_filter_meters': 20,
      'min_interval_seconds': 10,
      'batch_size': 50,
      'send_after_points': 50,
      'upload_interval_seconds': 60,
      'queue_max_points': 20000,
      'queue_max_age_days': 7,
      'notification_title': 'Tracking',
      'notification_body': 'Recording your route',
      'notification_channel_name': 'Location tracking',
      'notification_small_icon': '',
      'notification_importance': 'low',
      'notification_tap_opens_app': true,
      // Flat and prefixed rather than a nested map: the native config stores
      // are flat key-value, and keeping the wire that shape means neither of
      // them has to learn to walk a tree.
      'filter_accuracy_threshold_meters': 100.0,
      'filter_min_displacement_meters': 1.0,
      'filter_max_implied_speed_mps': 60.0,
      'filter_kalman_process_noise_mps': 3.0,
      'motion_stop_timeout_seconds': 300,
      'motion_stationary_radius_meters': 150.0,
      'motion_elasticity_multiplier': 1.0,
    });
  });
}
