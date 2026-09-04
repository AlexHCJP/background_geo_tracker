/// When the collector is allowed to switch the GPS off, and how far apart the
/// points are spaced while it is on.
///
/// A session used to keep location updates running from start to stop, so a
/// phone left on a desk for eight hours held the GPS for eight hours. These
/// three numbers are what ends that: two of them decide when the device counts
/// as standing still, the third spaces points out by speed so a motorway does
/// not cost a point every twenty metres.
class GeoMotionConfig {
  /// Every knob stated outright. [GeoMotionConfig.standard] is the one to
  /// reach for first.
  const GeoMotionConfig({
    required this.stopTimeoutSeconds,
    required this.stationaryRadiusMeters,
    required this.elasticityMultiplier,
  });

  /// The defaults the design settled on.
  factory GeoMotionConfig.standard({
    int stopTimeoutSeconds = 300,
    double stationaryRadiusMeters = 150,
    double elasticityMultiplier = 1,
  }) => GeoMotionConfig(
    stopTimeoutSeconds: stopTimeoutSeconds,
    stationaryRadiusMeters: stationaryRadiusMeters,
    elasticityMultiplier: elasticityMultiplier,
  );

  /// How long the device may stay inside [stationaryRadiusMeters] before the
  /// collector stops asking for fixes. `0` switches stop detection off: the
  /// GPS stays on for the whole session.
  ///
  /// Zero means *off*, not *stop immediately* — the same reading as
  /// [elasticityMultiplier], and for the same reason: taken literally it would
  /// switch the collector off on the second fix of every session. Off is what
  /// a live-position app wants and what a route recorder should never use: it
  /// is the difference between a phone that holds the GPS for eight hours on a
  /// desk and one that does not.
  ///
  /// Five minutes because it has to outlast a traffic light, a queue and a
  /// coffee, and because the cost of being wrong is asymmetric: a session that
  /// stops too eagerly loses the start of a walk, while one that stops too
  /// late loses a few minutes of battery.
  final int stopTimeoutSeconds;

  /// Doubles as the stillness threshold and as the radius of the geofence that
  /// wakes the collector.
  ///
  /// One number rather than two on purpose: it is the same distance stated
  /// from both sides — "has not gone further than this" and "count as gone
  /// once further than this" — and splitting it in two only creates a way to
  /// make them disagree. 150 m is the floor worth asking for; the OS answers a
  /// region exit at roughly 200 m whatever is requested.
  final double stationaryRadiusMeters;

  /// How hard the distance filter is stretched by speed. `0` switches
  /// stretching off entirely.
  ///
  /// Zero means *off*, not *zero metres*. Read literally in the formula it
  /// would mean recording every single fix — the exact opposite of what
  /// somebody switching elasticity off is asking for — so the native policies
  /// branch on it before they multiply.
  final double elasticityMultiplier;

  /// Flat, and prefixed, because the native config stores are flat key-value
  /// and stay that way. Merged into [GeoUploadConfig.toMap].
  Map<String, Object?> toMap() => <String, Object?>{
    'motion_stop_timeout_seconds': stopTimeoutSeconds,
    'motion_stationary_radius_meters': stationaryRadiusMeters,
    'motion_elasticity_multiplier': elasticityMultiplier,
  };
}
