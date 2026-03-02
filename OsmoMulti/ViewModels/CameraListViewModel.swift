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
        // Ensure idle timer matches the initial (disabled) state on fresh launch.
        // didSet does not fire during initialization, so set it explicitly.
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Screen Lock

    var screenLockDisabled: Bool = false {
        didSet { UIApplication.shared.isIdleTimerDisabled = screenLockDisabled }
    }

    // MARK: - Representative State

    /// The mode intent reported by the first connected camera, used to drive the global control bar.
    /// Maps each camera's native mode (e.g. `.panoVideo`) to its high-level intent (`.video`).
    var currentIntent: ModeIntent? {
        manager.enabledConnectedCameras.first?.status.mode?.intent
    }

    /// True if any connected camera is currently recording.
    var isAnyRecording: Bool {
        manager.enabledConnectedCameras.contains { $0.status.recordingStatus.isRecording }
    }

    // MARK: - Global Actions

    func shutterAll() {
        Task { await manager.shutterAll() }
    }

    func startAll() {
        Task { await manager.startAll() }
    }

    func stopAll() {
        Task { await manager.stopAll() }
    }

    func switchModeAll(_ intent: ModeIntent) {
        Task { await manager.switchModeAll(intent) }
    }

    func sleepAll() {
        Task { await manager.sleepAll() }
    }

    func reconnectAll() {
        Task { await manager.reconnectAll() }
    }

    // MARK: - Camera Actions

    func toggleEnabled(_ camera: OsmoCamera) {
        manager.toggleEnabled(camera)
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
        // Dismiss the sheet WITHOUT stopping the scan — addCamera's connection
        // needs the BLE stack stable. Scanning stops after connection completes.
        isAddingCamera = false
    }
}
