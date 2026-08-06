import CoreLocation
import Flutter
import UIKit

public class AttractorGeoPlugin: NSObject, FlutterPlugin {
    private let config = GeoConfigStore()

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = AttractorGeoPlugin()

        let methods = FlutterMethodChannel(
            name: "school.attractor/geo",
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(instance, channel: methods)

        FlutterEventChannel(
            name: "school.attractor/geo/points",
            binaryMessenger: registrar.messenger()
        ).setStreamHandler(
            GeoStreamHandler(
                attach: { GeoEventBus.onPoint = $0 },
                detach: { GeoEventBus.onPoint = nil }
            )
        )

        FlutterEventChannel(
            name: "school.attractor/geo/status",
            binaryMessenger: registrar.messenger()
        ).setStreamHandler(
            GeoStreamHandler(
                attach: { GeoEventBus.onStatus = $0 },
                detach: { GeoEventBus.onStatus = nil }
            )
        )

        // Needed for the relaunch path below.
        registrar.addApplicationDelegate(instance)

        GeoTracker.shared.onQueueGrew = {
            Uploader.shared.drainIfNeeded(force: false)
        }
    }

    /// iOS relaunches the app in the background when a significant location
    /// change arrives after the process died. Resuming here is what makes the
    /// session survive eviction — Dart is not involved and may never run.
    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any] = [:]
    ) -> Bool {
        if launchOptions[.location] != nil || config.isTracking {
            GeoTracker.shared.resumeIfTracking()
            Uploader.shared.startPeriodicDrain()
        }
        return true
    }

    public func handle(
        _ call: FlutterMethodCall, result: @escaping FlutterResult
    ) {
        switch call.method {
        case "configure":
            guard let arguments = call.arguments as? [String: Any] else {
                result(
                    FlutterError(
                        code: "bad_arguments",
                        message: "configure expects a map",
                        details: nil
                    )
                )
                return
            }
            config.save(arguments)
            result(nil)

        case "start":
            GeoTracker.shared.start()
            Uploader.shared.startPeriodicDrain()
            result(nil)

        case "stop":
            GeoTracker.shared.stop()
            Uploader.shared.stopPeriodicDrain()
            result(nil)

        case "reset":
            // Order matters: the uploader is stopped before the queue is
            // emptied so a drain in flight cannot re-read rows on their way
            // out, and the tracker is stopped last because stopping is what
            // publishes the fresh status.
            Uploader.shared.reset()
            PointQueue.shared?.clear()
            config.clear()
            GeoTracker.shared.stop()
            result(nil)

        case "status":
            result(GeoTracker.shared.statusMap())

        case "requestPermission":
            // The returned name is the state *before* the prompt is answered,
            // matching Android. The authoritative update arrives on the status
            // stream via `locationManagerDidChangeAuthorization`.
            GeoTracker.shared.requestNextPermission()
            result(GeoTracker.shared.permissionName())

        case "openSystemSettings":
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

/// Bridges an `EventChannel` onto a `GeoEventBus` slot.
private final class GeoStreamHandler: NSObject, FlutterStreamHandler {
    private let attach: (@escaping ([String: Any]) -> Void) -> Void
    private let detach: () -> Void

    init(
        attach: @escaping (@escaping ([String: Any]) -> Void) -> Void,
        detach: @escaping () -> Void
    ) {
        self.attach = attach
        self.detach = detach
    }

    func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        attach { events($0) }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        detach()
        return nil
    }
}
