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

    /// Tracks the last known connection state per camera ID for haptic edge detection.
    private var lastConnectionStates: [UUID: ConnectionState] = [:]

    init(manager: OsmoCameraManager) {
        self.manager = manager
        // Ensure idle timer matches the initial (disabled) state on fresh launch.
        // didSet does not fire during initialization, so set it explicitly.
        UIApplication.shared.isIdleTimerDisabled = false

        // Observe connection state transitions for haptic feedback.
        startConnectionHapticObservation()
    }

    private func startConnectionHapticObservation() {
        // Poll camera states on a 0.5s timer to detect transitions.
        // withObservationTracking can't easily observe an array of @Observable objects,
        // so a lightweight timer is more robust.
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                self.checkConnectionTransitions()
            }
        }
    }

    private func checkConnectionTransitions() {
        let allCameras = manager.enabledCameras + manager.disabledCameras
        for camera in allCameras {
            let current = camera.connectionState
            let previous = lastConnectionStates[camera.id]
            if let previous, previous != current {
                if current == .connected {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } else if current == .failed {
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                }
            }
            lastConnectionStates[camera.id] = current
        }
    }

    // MARK: - Toast

    /// Message shown in the bottom toast overlay. Set to `nil` to dismiss.
    var toastMessage: String?
    private var toastDismissTask: Task<Void, Never>?

    /// Show a toast message for 3 seconds. Replaces any currently visible toast
    /// (so rapid failures don't stack up).
    func showToast(_ message: String) {
        toastDismissTask?.cancel()
        toastMessage = message
        toastDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self.toastMessage = nil
        }
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

    /// Global mode intents that all currently connected targets have not rejected this session.
    var availableIntents: [ModeIntent] {
        let targets = manager.enabledConnectedCameras
        guard !targets.isEmpty else { return ModeIntent.allCases }

        return ModeIntent.allCases.filter { intent in
            targets.allSatisfy { camera in
                guard CameraMode.supportsIntent(intent, isPano: camera.isPanoCamera) else {
                    return false
                }
                let mode = CameraMode.nativeMode(for: intent,
                                                 isPano: camera.isPanoCamera,
                                                 currentMode: camera.status.mode)
                return !camera.unsupportedModes.contains(mode)
            }
        }
    }

    /// True if any connected camera is currently recording.
    var isAnyRecording: Bool {
        manager.enabledConnectedCameras.contains { $0.status.recordingStatus.isRecording }
    }

    // MARK: - Global Actions

    func shutterAll() {
        Task {
            let failed = await manager.shutterAll()
            if failed > 0 { showToast("Shutter failed on \(failed) camera(s)") }
        }
    }

    func startAll() {
        Task {
            let failed = await manager.startAll()
            if failed > 0 { showToast("Record start failed on \(failed) camera(s)") }
        }
    }

    func stopAll() {
        Task {
            let failed = await manager.stopAll()
            if failed > 0 { showToast("Record stop failed on \(failed) camera(s)") }
        }
    }

    func switchModeAll(_ intent: ModeIntent) {
        Task {
            let failed = await manager.switchModeAll(intent)
            if failed > 0 { showToast("Mode switch failed on \(failed) camera(s)") }
        }
    }

    func sleepAll() {
        Task {
            let failed = await manager.sleepAll()
            if failed > 0 { showToast("Sleep failed on \(failed) camera(s)") }
        }
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
