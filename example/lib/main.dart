import 'package:background_geo_tracker/background_geo_tracker.dart';
import 'package:flutter/material.dart';

/// Replace with any endpoint that captures request bodies — the real one does
/// not exist yet.
const String _url = 'https://example.invalid/v1/tracking/points';

void main() => runApp(const HarnessApp());

class HarnessApp extends StatelessWidget {
  const HarnessApp({super.key});

  @override
  Widget build(BuildContext context) =>
      const MaterialApp(home: HarnessScreen());
}

class HarnessScreen extends StatefulWidget {
  const HarnessScreen({super.key});

  @override
  State<HarnessScreen> createState() => _HarnessScreenState();
}

class _HarnessScreenState extends State<HarnessScreen> {
  final BackgroundGeoTracker _geo = BackgroundGeoTracker.standard();
  final List<GeoPoint> _points = <GeoPoint>[];
  GeoTrackingStatus? _status;

  @override
  void initState() {
    super.initState();
    _geo.points.listen((point) {
      setState(() {
        _points.insert(0, point);
        if (_points.length > 50) _points.removeLast();
      });
    });
    _geo.statusChanges.listen((status) => setState(() => _status = status));
    _refresh();
  }

  Future<void> _refresh() async {
    final status = await _geo.status();
    setState(() => _status = status);
  }

  Future<void> _configure() async {
    await _geo.configure(
      GeoUploadConfig.standard(
        sessionId: 'example-session',
        url: _url,
        headers: const <String, String>{'Authorization': 'Bearer harness'},
        notification: GeoNotificationConfig.standard(
          title: 'Attractor tracking',
          body: 'Recording your route',
          channelName: 'Route tracking',
        ),
      ),
    );
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return Scaffold(
      appBar: AppBar(title: const Text('background_geo_tracker harness')),
      body: Column(
        children: <Widget>[
          Wrap(
            spacing: 8,
            children: <Widget>[
              FilledButton(
                onPressed: () async {
                  await _geo.requestPermission();
                  await _refresh();
                },
                child: const Text('Permission'),
              ),
              FilledButton(
                onPressed: _configure,
                child: const Text('Configure'),
              ),
              FilledButton(
                onPressed: () async {
                  await _geo.start();
                  await _refresh();
                },
                child: const Text('Start'),
              ),
              FilledButton(
                onPressed: () async {
                  await _geo.stop();
                  await _refresh();
                },
                child: const Text('Stop'),
              ),
              FilledButton(
                onPressed: _geo.openSystemSettings,
                child: const Text('Settings'),
              ),
            ],
          ),
          if (status != null)
            ListTile(
              title: Text(
                'tracking: ${status.isTracking} · '
                'collector: ${status.collectorRunning} · '
                'permission: ${status.permission.name}',
              ),
              subtitle: Text(
                'queued: ${status.queuedPoints} · '
                'auth failed: ${status.authFailed} · '
                'services: ${status.locationServicesEnabled}',
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: _points.length,
              itemBuilder: (context, index) {
                final point = _points[index];
                return ListTile(
                  dense: true,
                  title: Text(
                    '${point.latitude.toStringAsFixed(5)}, '
                    '${point.longitude.toStringAsFixed(5)}',
                  ),
                  subtitle: Text(
                    '±${point.accuracy.toStringAsFixed(1)} m · '
                    '${point.recordedAt.toIso8601String()}',
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
