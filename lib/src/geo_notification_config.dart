/// How loudly the OS is allowed to deliver the collector's notification.
///
/// Two values, not Android's five. The notification is a legal requirement of
/// running a `location` foreground service, not something the app has news to
/// tell — the choice worth offering is between "visible and silent" and
/// "visible in the shade with the rest", and the three above that are for
/// alarms.
enum GeoNotificationImportance {
  /// No sound, no heads-up banner, and Android may collapse it into the
  /// silent section of the shade. The default, and what a session that runs
  /// for hours should use.
  low,

  /// The ordinary level: makes a sound the first time and sits with normal
  /// notifications. For an app whose whole purpose is the session, and which
  /// wants the user to notice it started.
  normal,
}

/// What the Android foreground-service notification looks like.
///
/// Android requires this notification to be visible for the entire session,
/// which makes it the most-seen surface this package has — and, until now, the
/// least controllable: the channel was called "Location tracking" in English
/// whatever the app's language, and the status bar showed a stock Android
/// pin rather than the host's own mark.
///
/// **Android only.** iOS shows no notification of its own for a location
/// session, so every field here is ignored there.
class GeoNotificationConfig {
  /// Every knob stated outright. [GeoNotificationConfig.standard] is the one
  /// to reach for first.
  const GeoNotificationConfig({
    required this.title,
    required this.body,
    required this.channelName,
    required this.smallIcon,
    required this.importance,
    required this.tapOpensApp,
  });

  /// The three strings a host must decide are required; the rest have answers
  /// that are right until somebody has a reason to disagree.
  ///
  /// [title], [body] and [channelName] are user-visible copy, so the package
  /// cannot supply them: it has no locale, and a default in the wrong language
  /// is worse than a compile error.
  factory GeoNotificationConfig.standard({
    required String title,
    required String body,
    required String channelName,
    String? smallIcon,
    GeoNotificationImportance importance = GeoNotificationImportance.low,
    bool tapOpensApp = true,
  }) => GeoNotificationConfig(
    title: title,
    body: body,
    channelName: channelName,
    smallIcon: smallIcon ?? '',
    importance: importance,
    tapOpensApp: tapOpensApp,
  );

  /// The bold first line.
  final String title;

  /// The line under [title].
  final String body;

  /// What the channel is called in Android's notification settings — the
  /// wording the user reads when deciding whether to silence this app.
  ///
  /// Localise it. It sits in the system UI next to the app's other channels,
  /// and an English string among translated ones is the tell that a screen
  /// belongs to a library rather than to the app.
  ///
  /// Android applies a rename on the next channel update, but **not** a change
  /// of [importance]: once a channel exists, only the user can move it. A
  /// build that changes its mind about importance needs a fresh install to
  /// show it.
  final String channelName;

  /// The name of a drawable in the *host app's* resources — `'ic_stat_route'`
  /// for `res/drawable/ic_stat_route.xml`. Empty means "whatever the platform
  /// has", which is a stock Android pin.
  ///
  /// A name rather than a resource id because ids are generated per build and
  /// a Dart layer has no way to hold one. The native side looks it up in
  /// `drawable` and then in `mipmap`, and falls back — with a line in the log —
  /// when neither has it, because a notification that fails to build takes the
  /// whole foreground service down with it.
  ///
  /// Android draws this as a white silhouette on the status bar, so a full
  /// colour launcher icon arrives as a featureless blob. Use a monochrome
  /// glyph with transparency.
  final String smallIcon;

  /// How loudly the OS may deliver it. See [GeoNotificationImportance].
  final GeoNotificationImportance importance;

  /// Whether tapping the notification opens the app.
  ///
  /// True by default: the notification is the one permanent reminder that a
  /// session is running, and a tap that does nothing reads as a dead app. Set
  /// false for a host that would rather the notification be inert than have it
  /// launch its own start screen.
  final bool tapOpensApp;

  /// Flat, and prefixed, because the native config stores are flat key-value
  /// and stay that way. Merged into [GeoUploadConfig.toMap].
  ///
  /// `notification_title` and `notification_body` keep the names they had
  /// before this object existed: the wire did not change, only the Dart shape
  /// around it, so a native store written by an older build still reads.
  Map<String, Object?> toMap() => <String, Object?>{
    'notification_title': title,
    'notification_body': body,
    'notification_channel_name': channelName,
    'notification_small_icon': smallIcon,
    'notification_importance': importance.name,
    'notification_tap_opens_app': tapOpensApp,
  };
}
