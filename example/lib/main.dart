import 'package:attractor_geo/attractor_geo.dart';
import 'package:flutter/material.dart';

/// Replace with any endpoint that captures request bodies — the real one does
/// not exist yet.
const String _baseUrl = 'https://example.invalid';
const String _path = '/v1/tracking/points';

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
  final AttractorGeoController _geo = AttractorGeoController.standard();
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
        baseUrl: _baseUrl,
        path: _path,
        headers: const <String, String>{'Authorization': 'Bearer harness'},
        notificationTitle: 'Attractor tracking',
        notificationBody: 'Recording your route',
      ),
    );
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return Scaffold(
      appBar: AppBar(title: const Text('attractor_geo harness')),
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
