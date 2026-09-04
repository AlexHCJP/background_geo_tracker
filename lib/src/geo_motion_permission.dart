/// Whether the fast movement detector is available to this session.
///
/// Three states rather than two because [unavailable] and [denied] look the
/// same from the outside and lead to opposite actions: a device with no motion
/// hardware, or without Play Services, has nothing to prompt for, and offering
/// the prompt anyway produces a button that does nothing.
enum GeoMotionPermission {
  /// The detector is running. A stationary collector wakes within metres.
  granted,

  /// The user said no. The collector still wakes, on the geofence, after
  /// roughly 200 m — the first stretch of a walk is simply not recorded.
  denied,

  /// There is no detector to ask about: no motion coprocessor on iOS, no Play
  /// Services on Android.
  unavailable,
}

/// Decodes the name the native layers use on the wire.
///
/// Unknown names degrade to [GeoMotionPermission.unavailable] rather than
/// throwing — a new OS state must not kill the status stream, and must not be
/// mistaken for a refusal the app would then offer to fix.
GeoMotionPermission geoMotionPermissionFromName(String name) => switch (name) {
  'granted' => GeoMotionPermission.granted,
  'denied' => GeoMotionPermission.denied,
  _ => GeoMotionPermission.unavailable,
};
