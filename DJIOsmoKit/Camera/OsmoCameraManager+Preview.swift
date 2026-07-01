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

        // 1. Connected, recording video, healthy battery, excellent signal
        let cam1 = OsmoCamera(name: "Osmo Action 5 Pro", isEnabled: true)
        cam1.connectionState = .connected
        cam1.lastSeenDate = Date()
        cam1.rssi = -48
        cam1.rssiHistory = [-52, -50, -48, -49, -47, -48, -50, -48, -47, -48]
        cam1.status = CameraStatus(
            mode: .video,
            recordingStatus: .recording,
            recordingSeconds: 142,
            batteryPercentage: 87,
            powerMode: .normal,
            rawMode: CameraMode.video.rawValue,
            videoResolution: .res4K_16_9,
            frameRate: .fps30,
            stabilizationMode: .rs,
            rawStabilization: CameraStatus.StabilizationMode.rs.rawValue,
            photoRatio: nil,
            remainingPhotoCount: 0,
            remainingStorageMB: 28_672,
            remainingRecordTimeSec: 5_420,
            temperatureWarning: 0,
            unmapped: [:]
        )

        // 2. Connected, photo mode, critically low battery, good signal
        let cam2 = OsmoCamera(name: "Osmo Action 4", isEnabled: true)
        cam2.connectionState = .connected
        cam2.lastSeenDate = Date()
        cam2.rssi = -62
        cam2.rssiHistory = [-58, -60, -63, -65, -62, -64, -61, -63, -62, -62]
        cam2.status = CameraStatus(
            mode: .photo,
            recordingStatus: .liveView,
            recordingSeconds: 0,
            batteryPercentage: 14,
            powerMode: .normal,
            rawMode: CameraMode.photo.rawValue,
            videoResolution: nil,
            frameRate: nil,
            stabilizationMode: nil,
            rawStabilization: 0,
            photoRatio: .ratio4_3,
            remainingPhotoCount: 245,
            remainingStorageMB: 512,
            remainingRecordTimeSec: 0,
            temperatureWarning: 0,
            unmapped: [:]
        )

        // 3. Connected but stale — last frame 5 s ago (triggers orange subtitle), fair signal
        let cam3 = OsmoCamera(name: "Osmo Action 3", isEnabled: true)
        cam3.connectionState = .connected
        cam3.lastSeenDate = Date(timeIntervalSinceNow: -5)
        cam3.rssi = -75
        cam3.rssiHistory = [-72, -74, -78, -76, -80, -77, -75, -73, -76, -75]
        cam3.status = CameraStatus(
            mode: .video,
            recordingStatus: .liveView,
            recordingSeconds: 0,
            batteryPercentage: 55,
            powerMode: .normal,
            rawMode: CameraMode.video.rawValue,
            videoResolution: .res1080p,
            frameRate: .fps60,
            stabilizationMode: .hs,
            rawStabilization: CameraStatus.StabilizationMode.hs.rawValue,
            photoRatio: nil,
            remainingPhotoCount: 0,
            remainingStorageMB: 3_200,
            remainingRecordTimeSec: 1_800,
            temperatureWarning: 0,
            unmapped: [:]
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
            powerMode: .sleep,
            rawMode: CameraMode.video.rawValue,
            videoResolution: .res4K_16_9,
            frameRate: .fps24,
            stabilizationMode: .off,
            rawStabilization: CameraStatus.StabilizationMode.off.rawValue,
            photoRatio: nil,
            remainingPhotoCount: 0,
            remainingStorageMB: 15_360,
            remainingRecordTimeSec: 3_600,
            temperatureWarning: 1,
            unmapped: [:]
        )

        // 6. Connected 360 camera in panoramic video mode, weak signal
        let cam6 = OsmoCamera(name: "Osmo 360", isEnabled: true)
        cam6.connectionState = .connected
        cam6.lastSeenDate = Date()
        cam6.rssi = -88
        cam6.rssiHistory = [-85, -87, -90, -92, -88, -91, -89, -87, -90, -88]
        cam6.isPanoCamera = true
        cam6.productName = "DJI-ACTION4"
        cam6.sdkVersion = "SDK-v1.1 DEBUG AC203-03.04.80.15"
        cam6.modeName = "Panoramic Video"
        cam6.modeParameters = "8K 30fps"
        cam6.status = CameraStatus(
            mode: .panoVideo,
            recordingStatus: .liveView,
            recordingSeconds: 0,
            batteryPercentage: 73,
            powerMode: .normal,
            rawMode: CameraMode.panoVideo.rawValue,
            videoResolution: .res360,
            frameRate: .fps30,
            stabilizationMode: .off,
            rawStabilization: CameraStatus.StabilizationMode.off.rawValue,
            photoRatio: nil,
            remainingPhotoCount: 0,
            remainingStorageMB: 45_056,
            remainingRecordTimeSec: 7_200,
            temperatureWarning: 0,
            unmapped: [:]
        )

        // 8. Connected, reporting resolution + fps codes this build can't map (simulates
        //    a newer model like the Action 6) — exercises the "Unk" row chip and the
        //    self-hiding "Unrecognized Codes" diagnostics section.
        let cam8 = OsmoCamera(name: "Osmo Action 6", isEnabled: true)
        cam8.connectionState = .connected
        cam8.lastSeenDate = Date()
        cam8.rssi = -55
        cam8.rssiHistory = [-56, -55, -54, -55, -57, -55, -54, -55, -56, -55]
        cam8.status = CameraStatus(
            mode: .video,
            recordingStatus: .liveView,
            recordingSeconds: 0,
            batteryPercentage: 88,
            powerMode: .normal,
            rawMode: CameraMode.video.rawValue,
            videoResolution: nil,
            frameRate: nil,
            stabilizationMode: .rs,
            rawStabilization: CameraStatus.StabilizationMode.rs.rawValue,
            photoRatio: nil,
            remainingPhotoCount: 0,
            remainingStorageMB: 61_440,
            remainingRecordTimeSec: 7_200,
            temperatureWarning: 0,
            unmapped: [.resolution: 0x2A, .frameRate: 0x14]
        )
        cam8.diagnosticUnknowns.merge(cam8.status.unmapped)

        // 7. Disabled (shown in Inactive section)
        let cam7 = OsmoCamera(name: "Osmo Action 4 (B)", isEnabled: false)
        cam7.connectionState = .disconnected

        return [cam1, cam2, cam3, cam4, cam5, cam6, cam8, cam7]
    }
}
#endif
