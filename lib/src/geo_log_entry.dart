/// How loud one log entry is. Bare enum: the mapping onto the app's own
/// logger belongs where the entries are read, not here.
enum GeoLogLevel {
  /// It happened and it went as intended. Most of the log is this.
  info,

  /// It did not happen, and the reason is ordinary — a permission not granted,
  /// a batch held back for a retry. Not a fault, but the answer to "why is
  /// there no track".
  warning,

  /// Something failed.
  error,
}

/// Decodes the wire name.
///
/// Anything unrecognised comes back as [GeoLogLevel.info] rather than
/// throwing. A native side newer than this build is a reason to read the
/// message, not a reason to lose the whole batch it arrived in.
GeoLogLevel geoLogLevelFromName(String name) => switch (name) {
  'warning' => GeoLogLevel.warning,
  'error' => GeoLogLevel.error,
  _ => GeoLogLevel.info,
};

/// One line the native tracker wrote while nothing was watching.
///
/// The native log is an outbox, not an archive: entries live there only until
/// something drains them, and [id] is the cursor that makes draining safe —
/// see `BackgroundGeoTracker.readLog`.
class GeoLogEntry {
  /// Every field required: an entry assembled with something left out would
  /// read as a complete record of a moment it only partly describes.
  const GeoLogEntry({
    required this.id,
    required this.at,
    required this.level,
    required this.event,
    required this.message,
  });

  /// Decodes one entry as the native side sends it.
  factory GeoLogEntry.fromMap(Map<Object?, Object?> map) => GeoLogEntry(
    id: map['id']! as int,
    at: DateTime.fromMillisecondsSinceEpoch(map['at_millis']! as int),
    level: geoLogLevelFromName(map['level']! as String),
    event: map['event']! as String,
    message: map['message']! as String,
  );

  /// Monotonic, assigned natively. Also the drain cursor.
  final int id;

  /// When the native side wrote it, not when Dart read it — the gap between
  /// the two is often the whole point.
  final DateTime at;

  /// How loud it is, and what the reader should make of it.
  final GeoLogLevel level;

  /// A stable machine tag: `fix.rejected`, `upload.result`, `session.start`.
  /// Kept apart from [message] so a reader can filter without parsing prose.
  final String event;

  /// The human line, carrying the numbers.
  final String message;
}
