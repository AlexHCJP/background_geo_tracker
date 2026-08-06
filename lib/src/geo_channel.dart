import 'package:flutter/services.dart';

/// Calls into the native tracker: `configure`, `start`, `stop`, `reset`,
/// `status`, `requestPermission` and `openSystemSettings`.
///
/// The name is shared with the native implementations. Changing it here means
/// changing it in Kotlin and Swift too, and the same holds for the two event
/// channels below.
const MethodChannel geoMethodChannel = MethodChannel('school.attractor/geo');

/// Carries each recorded fix up to Dart while the app is running. Points are
/// queued and uploaded natively whether or not anything listens here.
const EventChannel geoPointsChannel = EventChannel(
  'school.attractor/geo/points',
);

/// Carries status transitions: a session starting or ending, an answered
/// permission dialog, a credential the backend refused.
const EventChannel geoStatusChannel = EventChannel(
  'school.attractor/geo/status',
);
