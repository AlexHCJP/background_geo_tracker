import 'package:background_geo_tracker/background_geo_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  GeoUploadConfig standard() => GeoUploadConfig.standard(
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

  test('the send threshold defaults to the batch size', () {
    // Two jobs used to live in `batchSize`, and the default keeps the old
    // behaviour for anyone who has not thought about the difference.
    expect(standard().sendAfterPoints, 50);
    expect(standard().toMap()['send_after_points'], 50);
  });

  test('a threshold of one sends every fix without shrinking the batch', () {
    // What a live-position screen needs: post the moment a point exists, but
    // let a backlog leave fifty at a time rather than one round trip each.
    final config = GeoUploadConfig.standard(
      url: 'https://example.com/points',
      headers: const <String, String>{},
      notification: GeoNotificationConfig.standard(
        title: 'Tracking',
        body: 'Recording your route',
        channelName: 'Location tracking',
      ),
      sendAfterPoints: 1,
    );

    expect(config.sendAfterPoints, 1);
    expect(config.batchSize, 50);
    expect(config.toMap()['send_after_points'], 1);
    expect(config.toMap()['batch_size'], 50);
  });

  test('the notification config states what the user will see', () {
    final map = GeoUploadConfig.standard(
      url: 'https://example.com/points',
      headers: const <String, String>{},
      notification: GeoNotificationConfig.standard(
        title: 'Запись маршрута',
        body: 'Attractor записывает ваш маршрут',
        channelName: 'Запись маршрута',
        smallIcon: 'ic_stat_tracking',
        importance: GeoNotificationImportance.normal,
        tapOpensApp: false,
      ),
    ).toMap();

    expect(map['notification_title'], 'Запись маршрута');
    expect(map['notification_channel_name'], 'Запись маршрута');
    expect(map['notification_small_icon'], 'ic_stat_tracking');
    expect(map['notification_importance'], 'normal');
    expect(map['notification_tap_opens_app'], isFalse);
  });

  test('an unnamed icon travels as an empty string, not as a missing key', () {
    // The native side reads the key and falls back on its own; a key that
    // sometimes exists would make that two code paths instead of one.
    expect(
      standard().toMap()['notification_small_icon'],
      '',
    );
  });

  test('standard carries the motion defaults onto the wire', () {
    final map = standard().toMap();

    expect(map['motion_stop_timeout_seconds'], 300);
    expect(map['motion_stationary_radius_meters'], 150.0);
    expect(map['motion_elasticity_multiplier'], 1.0);
  });

  test('an overridden motion config replaces the defaults', () {
    final map = GeoUploadConfig.standard(
      url: 'https://example.com/points',
      headers: const <String, String>{},
      notification: GeoNotificationConfig.standard(
        title: 'Tracking',
        body: 'Recording your route',
        channelName: 'Location tracking',
      ),
      motion: GeoMotionConfig.standard(
        stopTimeoutSeconds: 60,
        stationaryRadiusMeters: 200,
        elasticityMultiplier: 0,
      ),
    ).toMap();

    expect(map['motion_stop_timeout_seconds'], 60);
    expect(map['motion_stationary_radius_meters'], 200.0);
    // Zero is a value, not a missing field: it means "no elasticity".
    expect(map['motion_elasticity_multiplier'], 0.0);
  });
}
