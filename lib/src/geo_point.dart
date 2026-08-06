/// One recorded location fix, as pushed up from the native tracker.
///
/// Decoding only — the native layer builds the upload payload itself, so this
/// type never has to serialise back to the wire format.
class GeoPoint {
  /// Every field is required, the nullable ones included: "the platform had
  /// nothing to report" is a fact about the fix, and forgetting to pass it
  /// must not look the same as recording it.
  const GeoPoint({
    required this.id,
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.altitude,
    required this.speed,
    required this.heading,
    required this.recordedAt,
    required this.isMock,
    required this.batteryLevel,
  });

  /// Decodes one event off the points channel. The keys are the snake_case
  /// ones the native side sends, which are also the wire format's.
  factory GeoPoint.fromMap(Map<Object?, Object?> map) => GeoPoint(
    id: map['id']! as String,
    latitude: _double(map['lat'])!,
    longitude: _double(map['lon'])!,
    accuracy: _double(map['accuracy'])!,
    altitude: _double(map['altitude']),
    speed: _double(map['speed']),
    heading: _double(map['heading']),
    recordedAt: DateTime.parse(map['recorded_at']! as String).toUtc(),
    isMock: map['is_mock']! as bool,
    batteryLevel: _double(map['battery_level']),
  );

  /// UUID generated natively, so a retried batch can be de-duplicated by the
  /// backend instead of duplicating the track.
  final String id;

  /// Degrees, WGS 84.
  final double latitude;

  /// Degrees, WGS 84.
  final double longitude;

  /// Horizontal accuracy in metres.
  final double accuracy;

  /// Metres above sea level, or null when the platform has no fix for it.
  final double? altitude;

  /// Metres per second, or null when unavailable.
  final double? speed;

  /// Degrees clockwise from true north, or null when unavailable.
  final double? heading;

  /// Always UTC.
  final DateTime recordedAt;

  /// Whether the OS reported this fix as coming from a mock provider.
  final bool isMock;

  /// Fraction from 0.0 to 1.0 — not a percentage.
  final double? batteryLevel;
}

/// The platform codec sends whole numbers as `int`, so a bare `as double`
/// cast blows up on a whole-degree coordinate.
double? _double(Object? value) => (value as num?)?.toDouble();
