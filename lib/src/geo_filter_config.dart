/// What the collector throws away before a fix reaches the queue, and how hard
/// it smooths what is left.
///
/// Every fix a location API hands over is a *claim*, not a measurement: a
/// cell-tower fallback claims to be a position the same way a satellite fix
/// does, and the only thing separating them is the accuracy radius attached.
/// Without a filter the queue takes both, and the position this device
/// publishes jumps a kilometre sideways whenever the phone loses sky.
///
/// The three rejections below are cheap and exact. The smoothing that follows
/// them is not a rejection at all — it moves an accepted point toward where
/// the previous ones say the device actually is, weighted by how much each
/// fix claims to be worth.
class GeoFilterConfig {
  /// Every knob stated outright. [GeoFilterConfig.standard] is the one to
  /// reach for first.
  const GeoFilterConfig({
    required this.accuracyThresholdMeters,
    required this.minDisplacementMeters,
    required this.maxImpliedSpeedMps,
    required this.kalmanProcessNoiseMps,
  });

  /// The defaults, tuned for a person carrying a phone.
  ///
  /// They are deliberately loose. A filter that is too eager does not announce
  /// itself — it produces a track with holes in it, which looks exactly like a
  /// collector that was asleep, and nothing in the status can tell the two
  /// apart. Every threshold here is set where a *human* could not have
  /// produced the reading, not where a good reading would be.
  factory GeoFilterConfig.standard({
    double accuracyThresholdMeters = 100,
    double minDisplacementMeters = 1,
    double maxImpliedSpeedMps = 60,
    double kalmanProcessNoiseMps = 3,
  }) => GeoFilterConfig(
    accuracyThresholdMeters: accuracyThresholdMeters,
    minDisplacementMeters: minDisplacementMeters,
    maxImpliedSpeedMps: maxImpliedSpeedMps,
    kalmanProcessNoiseMps: kalmanProcessNoiseMps,
  );

  /// Reject a fix whose own accuracy radius is worse than this, in metres.
  ///
  /// This is the cell-tower filter. A tower fix arrives claiming 1000–3000 m
  /// and is worthless for saying where somebody is; a GPS fix indoors claims
  /// 30–60 m and is worth keeping. 100 m sits between them with room on both
  /// sides.
  final double accuracyThresholdMeters;

  /// Reject a fix closer than this to the last accepted one, in metres.
  ///
  /// A stationary phone does not report one position — it reports a cloud of
  /// them, drifting by a few metres as satellites move. The distance filter
  /// suppresses most of that, but not the fixes the OS delivers for other
  /// reasons, and each one costs a row and an upload to say nothing new.
  final double minDisplacementMeters;

  /// Reject a fix that would imply travelling faster than this, in metres per
  /// second, measured against the last accepted fix.
  ///
  /// The teleport filter, and the only one that catches a *confident* lie: a
  /// bad fix can arrive claiming 20 m accuracy from 5 km away. No pedestrian
  /// or car covers that ground in the interval, so the claim refutes itself.
  /// 60 m/s is about 216 km/h — above any road, below a plane.
  final double maxImpliedSpeedMps;

  /// How fast the smoother is willing to believe the device is moving, in
  /// metres per second. Raise it to follow real movement more closely, lower
  /// it to hold a stationary position steadier.
  ///
  /// This is the process noise of the Kalman filter: the amount of positional
  /// uncertainty added per second of elapsed time. Set it far below real
  /// walking speed and the filter lags behind an actual walk; set it far above
  /// and it stops smoothing anything. 3 m/s is a brisk walk.
  final double kalmanProcessNoiseMps;

  /// Flat, and prefixed, because the native config stores are flat key-value
  /// and stay that way. Merged into [GeoUploadConfig.toMap].
  Map<String, Object?> toMap() => <String, Object?>{
    'filter_accuracy_threshold_meters': accuracyThresholdMeters,
    'filter_min_displacement_meters': minDisplacementMeters,
    'filter_max_implied_speed_mps': maxImpliedSpeedMps,
    'filter_kalman_process_noise_mps': kalmanProcessNoiseMps,
  };
}
