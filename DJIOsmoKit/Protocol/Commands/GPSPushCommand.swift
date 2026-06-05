import CoreLocation
import Foundation

/// Builds GPS data push frames (CmdSet 0x00, CmdID 0x17).
///
/// Feeds iPhone GPS coordinates to a connected camera so video footage gets
/// accurate geotags. This is a fire-and-forget command (cmdType 0x00) --
/// the camera does not send a response.
///
/// Payload: 48 bytes, all fields little-endian.
enum GPSPushCommand {

    static let cmdSet: UInt8 = 0x00
    static let cmdID: UInt8  = 0x17

    /// Build a complete GPS push frame from a `CLLocation`.
    ///
    /// - Parameters:
    ///   - location: The current device location from Core Location.
    ///   - seq: The sequence number for this frame.
    /// - Returns: The fully built DJI protocol frame ready to write to BLE.
    static func build(location: CLLocation, seq: UInt16) -> Data {
        var payload = Data(count: 48)

        // -- Timestamp in DJI format (UTC) --
        var cal = Calendar(identifier: .gregorian)
        // Keep GPS timestamps stable and locale-independent; camera local-time sync is not exposed here.
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let comps = cal.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: location.timestamp
        )
        let year = comps.year ?? 0
        let month = comps.month ?? 0
        let day = comps.day ?? 0
        let ymd = Int32(year * 10000 + month * 100 + day)

        let hour = comps.hour ?? 0
        let minute = comps.minute ?? 0
        let second = comps.second ?? 0
        let hms = Int32(hour * 10000 + minute * 100 + second)
        payload.writeLE(ymd, at: 0)
        payload.writeLE(hms, at: 4)

        // -- Position (scaled integers) --
        payload.writeLE(Int32(clamping: Int64(location.coordinate.longitude * 1e7)), at: 8)
        payload.writeLE(Int32(clamping: Int64(location.coordinate.latitude * 1e7)), at: 12)
        payload.writeLE(Int32(clamping: Int64(location.altitude * 1000)), at: 16)  // millimetres

        // -- Speed decomposition using course --
        let speedMS = max(location.speed, 0)  // m/s; negative means invalid
        let courseRad = location.course >= 0
            ? location.course * .pi / 180.0
            : 0
        let northCMS = Float(speedMS * cos(courseRad) * 100)  // cm/s
        let eastCMS  = Float(speedMS * sin(courseRad) * 100)  // cm/s
        payload.writeLE(northCMS, at: 20)
        payload.writeLE(eastCMS, at: 24)
        payload.writeLE(Float(0), at: 28)  // speed_to_downward (unused)

        // -- Accuracy --
        let vAcc = UInt32(max(location.verticalAccuracy, 0) * 1000)     // mm
        let hAcc = UInt32(max(location.horizontalAccuracy, 0) * 1000)   // mm
        let sAcc: UInt32 = location.speedAccuracy >= 0
            ? UInt32(location.speedAccuracy * 100) : 0                  // cm/s
        payload.writeLE(vAcc, at: 32)
        payload.writeLE(hAcc, at: 36)
        payload.writeLE(sAcc, at: 40)
        payload.writeLE(UInt32(8), at: 44)  // fake satellite_number; CLLocation does not provide this

        return FrameBuilder.build(OutgoingFrame(
            cmdType: 0x00,  // fire-and-forget, no response expected
            seq: seq,
            cmdSet: cmdSet,
            cmdID: cmdID,
            payload: payload
        ))
    }
}
