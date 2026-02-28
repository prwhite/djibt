import DJIOsmoKit
import Foundation
import Observation
import UIKit

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

    // MARK: - Screen Lock

    var screenLockDisabled: Bool = false {
        didSet { UIApplication.shared.isIdleTimerDisabled = screenLockDisabled }
    }

    // MARK: - Representative State

    /// The mode reported by the first connected camera, used to drive the control bar UI.
    var currentMode: CameraMode? {
        manager.enabledConnectedCameras.first?.status.mode
    }

    /// True if any connected camera is currently recording.
    var isAnyRecording: Bool {
        manager.enabledConnectedCameras.contains { $0.status.recordingStatus.isRecording }
    }

    // MARK: - Global Actions

    func shutterAll() {
        Task { await manager.shutterAll() }
    }

    func stopAll() {
        Task { await manager.stopAll() }
    }

    func switchModeAll(_ mode: CameraMode) {
        Task { await manager.switchModeAll(mode) }
    }

    func sleepAll() {
        Task { await manager.sleepAll() }
    }

    func reconnectAll() {
        Task { await manager.reconnectAll() }
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
