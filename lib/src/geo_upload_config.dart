/// How the native tracker collects points and where it sends them.
///
/// The package knows nothing about any particular backend — the URL, the
/// headers and the batching policy all arrive from the app.
class GeoUploadConfig {
  /// Every knob stated outright, for an app that has a reason to disagree with
  /// the defaults. [GeoUploadConfig.standard] is the one to reach for first.
  factory GeoUploadConfig({
    required String sessionId,
    required String url,
    required Map<String, String> headers,
    required int distanceFilterMeters,
    required int minIntervalSeconds,
    required int batchSize,
    required int uploadIntervalSeconds,
    required int queueMaxPoints,
    required int queueMaxAgeDays,
    required String notificationTitle,
    required String notificationBody,
  }) {
    final normalizedSessionId = sessionId.trim();
    if (normalizedSessionId.isEmpty) {
      throw ArgumentError.value(sessionId, 'sessionId', 'must not be empty');
    }

    final endpoint = Uri.tryParse(url.trim());
    if (endpoint == null ||
        endpoint.scheme != 'https' ||
        endpoint.host.isEmpty ||
        endpoint.hasFragment) {
      throw ArgumentError.value(
        url,
        'url',
        'must be an absolute HTTPS URL without a fragment',
      );
    }
    if (headers.keys.any((name) => name.trim().isEmpty)) {
      throw ArgumentError.value(headers, 'headers', 'names must not be empty');
    }
    if (distanceFilterMeters < 0) {
      throw ArgumentError.value(
        distanceFilterMeters,
        'distanceFilterMeters',
        'must be zero or greater',
      );
    }
    _requirePositive(minIntervalSeconds, 'minIntervalSeconds');
    _requirePositive(batchSize, 'batchSize');
    _requirePositive(uploadIntervalSeconds, 'uploadIntervalSeconds');
    _requirePositive(queueMaxPoints, 'queueMaxPoints');
    _requirePositive(queueMaxAgeDays, 'queueMaxAgeDays');
    if (notificationTitle.trim().isEmpty || notificationBody.trim().isEmpty) {
      throw ArgumentError(
        'notificationTitle and notificationBody must not be empty',
      );
    }

    return GeoUploadConfig._(
      sessionId: normalizedSessionId,
      url: endpoint.toString(),
      headers: Map<String, String>.unmodifiable(headers),
      distanceFilterMeters: distanceFilterMeters,
      minIntervalSeconds: minIntervalSeconds,
      batchSize: batchSize,
      uploadIntervalSeconds: uploadIntervalSeconds,
      queueMaxPoints: queueMaxPoints,
      queueMaxAgeDays: queueMaxAgeDays,
      notificationTitle: notificationTitle.trim(),
      notificationBody: notificationBody.trim(),
    );
  }

  const GeoUploadConfig._({
    required this.sessionId,
    required this.url,
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

  /// The collection and batching defaults the design settled on, tuned for a
  /// route track that is useful without draining the battery — with every one
  /// of them open to being overridden.
  ///
  /// The defaults live here and nowhere else, so an app that disagrees with
  /// one of them says so in one word rather than restating the other five.
  ///
  /// [batchSize] is the one worth understanding before changing, because it
  /// does two jobs: it is how many points a request carries, *and* how many
  /// have to be queued before the arrival of a point triggers a send on its
  /// own. Setting it to 1 therefore means "post every fix the moment it is
  /// recorded" — which is the freshest a position can be, and also one HTTP
  /// request per fix. Behind a 20 m filter that is a request every 20 m
  /// walked, and a backlog drains one point per round trip.
  factory GeoUploadConfig.standard({
    required String sessionId,
    required String url,
    required Map<String, String> headers,
    required String notificationTitle,
    required String notificationBody,
    int distanceFilterMeters = 20,
    int minIntervalSeconds = 10,
    int batchSize = 50,
    int uploadIntervalSeconds = 60,
    int queueMaxPoints = 20000,
    int queueMaxAgeDays = 7,
  }) => GeoUploadConfig(
    sessionId: sessionId,
    url: url,
    headers: headers,
    distanceFilterMeters: distanceFilterMeters,
    minIntervalSeconds: minIntervalSeconds,
    batchSize: batchSize,
    uploadIntervalSeconds: uploadIntervalSeconds,
    queueMaxPoints: queueMaxPoints,
    queueMaxAgeDays: queueMaxAgeDays,
    notificationTitle: notificationTitle,
    notificationBody: notificationBody,
  );

  /// Backend-issued identifier of the one live-sharing session these points
  /// belong to. It is persisted with every row, not merely with the current
  /// configuration, so an offline tail can never be mistaken for a later
  /// session on the same device.
  final String sessionId;

  /// The endpoint the batches are posted to, whole — for example
  /// `https://api.example.com/geo/v1/points`. The native uploader POSTs a JSON
  /// array of points there.
  ///
  /// One string rather than an origin and a path to join: the uploader has no
  /// use for the two halves apart, and splitting them only creates a way to be
  /// wrong. Whether the join needs a slash between them, and which side owns
  /// it, is a question the caller already answered when it wrote the address
  /// down — asking it again here means every caller re-answers it, and the one
  /// that gets it wrong finds out as a silent 404 in a background uploader.
  ///
  /// Must be `https` on iOS unless the host is local: App Transport Security
  /// polices URLSession, and a plain-HTTP endpoint fails with nothing to see
  /// from inside the app.
  final String url;

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
    'session_id': sessionId,
    'url': url,
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

void _requirePositive(int value, String name) {
  if (value <= 0) {
    throw ArgumentError.value(value, name, 'must be greater than zero');
  }
}
