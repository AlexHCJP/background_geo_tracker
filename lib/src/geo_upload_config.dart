import 'package:background_geo_tracker/src/geo_filter_config.dart';
import 'package:background_geo_tracker/src/geo_motion_config.dart';
import 'package:background_geo_tracker/src/geo_notification_config.dart';

/// How the native tracker collects points and where it sends them.
///
/// The package knows nothing about any particular backend — the URL, the
/// headers and the batching policy all arrive from the app.
class GeoUploadConfig {
  /// Every knob stated outright, for an app that has a reason to disagree with
  /// the defaults. [GeoUploadConfig.standard] is the one to reach for first.
  const GeoUploadConfig({
    required this.url,
    required this.headers,
    required this.distanceFilterMeters,
    required this.minIntervalSeconds,
    required this.batchSize,
    required this.sendAfterPoints,
    required this.uploadIntervalSeconds,
    required this.queueMaxPoints,
    required this.queueMaxAgeDays,
    required this.filter,
    required this.motion,
    required this.notification,
  });

  /// The collection and batching defaults the design settled on, tuned for a
  /// route track that is useful without draining the battery — with every one
  /// of them open to being overridden.
  ///
  /// The defaults live here and nowhere else, so an app that disagrees with
  /// one of them says so in one word rather than restating the other five.
  ///
  /// [sendAfterPoints] is the one worth understanding before changing. It is
  /// how fresh the stored position is: at 1 a request leaves the moment a
  /// point exists, so the backend is never more than one fix behind; at
  /// [batchSize] a point waits for forty-nine more or for
  /// [uploadIntervalSeconds], whichever comes first.
  ///
  /// It used to be the same number as [batchSize], and that made freshness
  /// unaffordable: buying it meant shrinking the request too, so an hour
  /// offline drained as one round trip per point and a single failure among
  /// them put the whole queue on the retry backoff.
  factory GeoUploadConfig.standard({
    required String url,
    required Map<String, String> headers,
    required GeoNotificationConfig notification,
    int distanceFilterMeters = 20,
    int minIntervalSeconds = 10,
    int batchSize = 50,
    int? sendAfterPoints,
    int uploadIntervalSeconds = 60,
    int queueMaxPoints = 20000,
    int queueMaxAgeDays = 7,
    GeoFilterConfig? filter,
    GeoMotionConfig? motion,
  }) => GeoUploadConfig(
    url: url,
    headers: headers,
    distanceFilterMeters: distanceFilterMeters,
    minIntervalSeconds: minIntervalSeconds,
    batchSize: batchSize,
    // Defaults to the batch size, which is what this setting used to be
    // half of — so a caller who has not thought about the difference
    // keeps exactly the behaviour they had.
    sendAfterPoints: sendAfterPoints ?? batchSize,
    uploadIntervalSeconds: uploadIntervalSeconds,
    queueMaxPoints: queueMaxPoints,
    queueMaxAgeDays: queueMaxAgeDays,
    filter: filter ?? GeoFilterConfig.standard(),
    motion: motion ?? GeoMotionConfig.standard(),
    notification: notification,
  );

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

  /// Ceiling on how many points one request carries. Not a trigger — see
  /// [sendAfterPoints] for that.
  final int batchSize;

  /// How many points have to be queued before their arrival sends a request
  /// on its own.
  ///
  /// 1 means every fix posts as it is recorded, which is what a screen showing
  /// somebody's live position needs. It costs one request per fix while the
  /// device is moving — behind a 20 m filter, one per 20 m walked — and
  /// nothing at all while it stands still, because a stationary collector
  /// produces no points.
  ///
  /// Deliberately separate from [batchSize]: a low threshold buys freshness,
  /// a high batch keeps a backlog cheap, and the two questions have different
  /// right answers. A queue that built up offline still leaves [batchSize] at
  /// a time however low this is.
  final int sendAfterPoints;

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

  /// What the collector discards before a fix reaches the queue, and how hard
  /// it smooths what survives.
  ///
  /// Its own object rather than four more fields here, because these four are
  /// read and reasoned about together — a threshold means nothing without the
  /// other three beside it — and because everything else on this class is
  /// about *where points go*, while these are about *which points exist*.
  final GeoFilterConfig filter;

  /// When the collector may switch the GPS off, and how speed spaces points
  /// out while it is on.
  ///
  /// Its own object for the same reason [filter] is one: these three are read
  /// together and mean nothing apart, and everything else on this class is
  /// about where points go rather than when they are taken.
  final GeoMotionConfig motion;

  /// What the Android foreground-service notification says and looks like.
  ///
  /// Its own object for the same reason [filter] and [motion] are: the six
  /// fields are one decision about one surface. Android-only — iOS shows no
  /// notification for a location session and ignores all of it.
  ///
  /// Required with no default, unlike the other two, because half of it is
  /// user-visible copy: the package has no locale to write it in, and a
  /// plausible English default is how a library's own words end up shipping in
  /// somebody's Russian app.
  final GeoNotificationConfig notification;

  /// The form the method channel carries to the native side. snake_case
  /// because Kotlin and Swift read these keys by name.
  Map<String, Object?> toMap() => <String, Object?>{
    'url': url,
    'headers': headers,
    'distance_filter_meters': distanceFilterMeters,
    'min_interval_seconds': minIntervalSeconds,
    'batch_size': batchSize,
    'send_after_points': sendAfterPoints,
    'upload_interval_seconds': uploadIntervalSeconds,
    'queue_max_points': queueMaxPoints,
    'queue_max_age_days': queueMaxAgeDays,
    ...filter.toMap(),
    ...motion.toMap(),
    ...notification.toMap(),
  };
}
