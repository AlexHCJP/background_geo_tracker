import 'package:background_geo_tracker/background_geo_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fromMap decodes an entry off the wire', () {
    final entry = GeoLogEntry.fromMap(const <Object?, Object?>{
      'id': 42,
      'at_millis': 1756000000000,
      'level': 'warning',
      'event': 'upload.result',
      'message': 'http 422 in 180ms',
    });

    expect(entry.id, 42);
    expect(entry.at, DateTime.fromMillisecondsSinceEpoch(1756000000000));
    expect(entry.level, GeoLogLevel.warning);
    expect(entry.event, 'upload.result');
    expect(entry.message, 'http 422 in 180ms');
  });

  test('an unknown level decodes as info rather than throwing', () {
    // A native side that grows a level this build has never heard of must not
    // take the whole drain down with it: the message is still worth reading.
    final entry = GeoLogEntry.fromMap(const <Object?, Object?>{
      'id': 1,
      'at_millis': 0,
      'level': 'trace',
      'event': 'fix.accepted',
      'message': 'whatever',
    });

    expect(entry.level, GeoLogLevel.info);
  });
}
