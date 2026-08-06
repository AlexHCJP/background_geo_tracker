/// The location permission, reduced to the four states our flow branches on.
/// The native layer folds each finer-grained OS status onto one of these.
enum GeoPermission {
  /// Not granted, but the system prompt can still be shown.
  denied,

  /// Granted for the foreground only — tracking works while the app is open
  /// and dies when it is backgrounded.
  whenInUse,

  /// Granted for background use — the only state where the design's guarantee
  /// actually holds.
  always,

  /// Refused with no way left to prompt. Enabling must send the user to the
  /// system settings.
  permanentlyDenied,
}

/// Decodes the name the native layers use on the wire.
///
/// Unknown names degrade to [GeoPermission.denied] rather than throwing — a
/// new OS state must not kill the status stream.
GeoPermission geoPermissionFromName(String name) => switch (name) {
  'when_in_use' => GeoPermission.whenInUse,
  'always' => GeoPermission.always,
  'permanently_denied' => GeoPermission.permanentlyDenied,
  _ => GeoPermission.denied,
};
