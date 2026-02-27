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

    func sleepAll() {
        Task { await manager.sleepAll() }
    }

    func wakeAll() {
        Task { await manager.wakeAll() }
    }

    // MARK: - Camera Actions

    func toggleEnabled(_ camera: OsmoCamera) {
        camera.isEnabled.toggle()
        if camera.isEnabled {
            Task { await manager.connect(camera: camera) }
        } else {
            camera.forceDisconnect()
        }
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
