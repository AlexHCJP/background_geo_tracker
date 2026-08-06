import 'package:flutter/services.dart';

/// Channel names shared with the native implementations. Changing one here
/// means changing it in Kotlin and Swift too.
const MethodChannel geoMethodChannel = MethodChannel('school.attractor/geo');

const EventChannel geoPointsChannel = EventChannel(
  'school.attractor/geo/points',
);

const EventChannel geoStatusChannel = EventChannel(
  'school.attractor/geo/status',
);
