/// How the native tracker collects points and where it sends them.
///
/// The package knows nothing about any particular backend — the URL, the
/// headers and the batching policy all arrive from the app.
class GeoUploadConfig {
  /// Every knob stated outright, for an app that has a reason to disagree with
  /// the defaults. [GeoUploadConfig.standard] is the one to reach for first.
  const GeoUploadConfig({
    required this.baseUrl,
    required this.path,
    required this.headers,
    required this.distanceFilterMeters,
    required this.minIntervalSeconds,
    required this.batchSize,
    required this.uploadIntervalSeconds,
    required this.queueMaxPoints,
    required this.queueMaxAgeDays,
    required this.notificationTitle,
    required this.notificationBody,
  });

  /// The collection and batching defaults the design settled on. Tuned for a
  /// route track that is useful without draining the battery.
  factory GeoUploadConfig.standard({
    required String baseUrl,
    required String path,
    required Map<String, String> headers,
    required String notificationTitle,
    required String notificationBody,
  }) => GeoUploadConfig(
    baseUrl: baseUrl,
    path: path,
    headers: headers,
    distanceFilterMeters: 20,
    minIntervalSeconds: 10,
    batchSize: 50,
    uploadIntervalSeconds: 60,
    queueMaxPoints: 20000,
    queueMaxAgeDays: 7,
    notificationTitle: notificationTitle,
    notificationBody: notificationBody,
  );

  /// Origin the batches are posted to, with no trailing slash — for example
  /// `https://api.example.com`.
  final String baseUrl;

  /// Appended to [baseUrl] to form the endpoint, for example `/geo/v1/points`.
  /// The native uploader POSTs a JSON array of points there.
  final String path;

  /// Sent with every upload. Stored natively in encrypted storage, so the
  /// uploader keeps working with no Dart isolate alive.
  final Map<String, String> headers;

  /// Record a point after this much displacement.
  final int distanceFilterMeters;

  /// …but never more often than this, so a stationary phone stops generating
  /// noise.
  final int minIntervalSeconds;

  /// Upload once this many points are queued…
  final int batchSize;

  /// …or once this long has passed, whichever comes first.
  ///
  /// Honoured on both platforms while a session is running, by the collector
  /// itself — iOS on a timer, Android from the foreground service. Android's
  /// background scheduler cannot go below 15 minutes, so if the OS kills the
  /// collector with points still queued, that is how long the leftovers can
  /// wait for the fallback drain.
  final int uploadIntervalSeconds;

  /// Ceiling on queued points. Oldest are evicted first, so a long offline
  /// stretch cannot grow the database without bound.
  final int queueMaxPoints;

  /// Age ceiling, applied alongside [queueMaxPoints]. A point older than this
  /// is dropped even when there is room left for it — a week-old position is
  /// not worth uploading.
  final int queueMaxAgeDays;

  /// Title of the Android foreground-service notification, which the OS
  /// requires to be visible for the whole session.
  final String notificationTitle;

  /// Body line under [notificationTitle]. iOS shows no notification of its
  /// own, so both are Android-only.
  final String notificationBody;

  /// The form the method channel carries to the native side. snake_case
  /// because Kotlin and Swift read these keys by name.
  Map<String, Object?> toMap() => <String, Object?>{
    'base_url': baseUrl,
    'path': path,
    'headers': headers,
    'distance_filter_meters': distanceFilterMeters,
    'min_interval_seconds': minIntervalSeconds,
    'batch_size': batchSize,
    'upload_interval_seconds': uploadIntervalSeconds,
    'queue_max_points': queueMaxPoints,
    'queue_max_age_days': queueMaxAgeDays,
    'notification_title': notificationTitle,
    'notification_body': notificationBody,
  };
}
