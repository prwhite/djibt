#if DEBUG
import Foundation

// MARK: - Preview Factory

public extension OsmoCameraManager {

    /// Returns a pre-populated manager for use in `#Preview` blocks and `--preview-mode`
    /// device runs. Covers all distinct UI states shown in the camera list.
    static func makePreview() -> OsmoCameraManager {
        OsmoCameraManager(previewCameras: previewFixtureCameras())
    }

    private static func previewFixtureCameras() -> [OsmoCamera] {

        // 1. Connected, recording video, healthy battery
        let cam1 = OsmoCamera(name: "Osmo Action 5 Pro", isEnabled: true)
        cam1.connectionState = .connected
        cam1.lastSeenDate = Date()
        cam1.status = CameraStatus(
            mode: .video,
            recordingStatus: .recording,
            recordingSeconds: 142,
            batteryPercentage: 87,
            rawMode: CameraMode.video.rawValue
        )

        // 2. Connected, photo mode, critically low battery
        let cam2 = OsmoCamera(name: "Osmo Action 4", isEnabled: true)
        cam2.connectionState = .connected
        cam2.lastSeenDate = Date()
        cam2.status = CameraStatus(
            mode: .photo,
            recordingStatus: .liveView,
            recordingSeconds: 0,
            batteryPercentage: 14,
            rawMode: CameraMode.photo.rawValue
        )

        // 3. Connected but stale — last frame 5 s ago (triggers orange subtitle)
        let cam3 = OsmoCamera(name: "Osmo Action 3", isEnabled: true)
        cam3.connectionState = .connected
        cam3.lastSeenDate = Date(timeIntervalSinceNow: -5)
        cam3.status = CameraStatus(
            mode: .video,
            recordingStatus: .liveView,
            recordingSeconds: 0,
            batteryPercentage: 55,
            rawMode: CameraMode.video.rawValue
        )

        // 4. Reconnecting (yellow dot)
        let cam4 = OsmoCamera(name: "Osmo Action 3 (B)", isEnabled: true)
        cam4.connectionState = .reconnecting

        // 5. Sleeping (orange dot)
        let cam5 = OsmoCamera(name: "Osmo Action 3 (C)", isEnabled: true)
        cam5.connectionState = .sleeping
        cam5.lastSeenDate = Date(timeIntervalSinceNow: -30)
        cam5.status = CameraStatus(
            mode: .video,
            recordingStatus: .screenOff,
            recordingSeconds: 0,
            batteryPercentage: 62,
            rawMode: CameraMode.video.rawValue
        )

        // 6. Disabled (shown in Inactive section)
        let cam6 = OsmoCamera(name: "Osmo Action 4 (B)", isEnabled: false)
        cam6.connectionState = .disconnected

        return [cam1, cam2, cam3, cam4, cam5, cam6]
    }
}
#endif
