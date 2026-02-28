import DJIOsmoKit
import Foundation
import Observation

/// View model for `CameraListView`.
///
/// Thin wrapper over `OsmoCameraManager` that exposes derived state for the list view.
@Observable
@MainActor
final class CameraListViewModel {

    private let manager: OsmoCameraManager

    var enabledCameras: [OsmoCamera] { manager.enabledCameras }
    var disabledCameras: [OsmoCamera] { manager.disabledCameras }
    var isScanning: Bool { manager.isScanning }
    var isAddingCamera: Bool = false

    init(manager: OsmoCameraManager = .shared) {
        self.manager = manager
    }

    // MARK: - Global Actions

    func recordAll() {
        Task { await manager.recordAll() }
    }

    func stopAll() {
        Task { await manager.stopAll() }
    }

    func photoAll() {
        Task { await manager.photoAll() }
    }

    func sleepAll() {
        Task { await manager.sleepAll() }
    }

    func wakeAll() {
        Task { await manager.wakeAll() }
    }

    func wakeCamera(_ camera: OsmoCamera) {
        Task { await manager.wakeCamera(camera) }
    }

    // MARK: - Camera Actions

    func toggleEnabled(_ camera: OsmoCamera) {
        camera.isEnabled.toggle()
        if camera.isEnabled {
            // Treat re-enabling as an explicit user retry — reset the retry counter so a
            // previously-failed camera gets a fresh set of attempts.
            Task { await manager.retryCamera(camera) }
        } else {
            camera.forceDisconnect()
        }
    }

    /// Fire-and-forget retry (for use in button actions).
    func retryCamera(_ camera: OsmoCamera) {
        Task { await manager.retryCamera(camera) }
    }

    /// Awaitable retry (for use in async contexts like forceReconnect).
    func retryCameraAsync(_ camera: OsmoCamera) async {
        await manager.retryCamera(camera)
    }

    func removeCamera(_ camera: OsmoCamera) {
        manager.removeCamera(camera)
    }

    func showAddCamera() {
        manager.startScanning()
        isAddingCamera = true
    }

    func dismissAddCamera() {
        manager.stopScanning()
        isAddingCamera = false
    }

    func pairCamera(_ discovered: DiscoveredCamera) {
        manager.addCamera(discovered)
        dismissAddCamera()
    }
}
