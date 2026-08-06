import Foundation

/// Carries points and status from the tracker to whichever plugin instance is
/// attached. With no engine attached the events are dropped — collection and
/// upload do not depend on anyone listening.
enum GeoEventBus {
    static var onPoint: (([String: Any]) -> Void)?
    static var onStatus: (([String: Any]) -> Void)?

    static func emitPoint(_ point: [String: Any]) {
        guard let sink = onPoint else { return }
        DispatchQueue.main.async { sink(point) }
    }

    static func emitStatus(_ status: [String: Any]) {
        guard let sink = onStatus else { return }
        DispatchQueue.main.async { sink(status) }
    }
}
