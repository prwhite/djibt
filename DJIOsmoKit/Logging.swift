import OSLog

/// Centralised OSLog loggers for DJIOsmoKit.
///
/// All files in the framework use these directly — no extra import needed at each call site.
///
/// Filter in Xcode console:  `subsystem == "net.prehiti.payton.CamControl"`
/// Filter by category:       `category == "BLE.Conn"`
/// Filter errors only:       `level >= error`
///
/// From Terminal (device attached via USB or on same Wi-Fi):
/// ```bash
/// log stream --predicate 'subsystem == "net.prehiti.payton.CamControl"' --level debug
/// ```
enum OsmoLog {
    /// BLE scanning — OsmoBLEScanner
    static let scan       = Logger(subsystem: "net.prehiti.payton.CamControl", category: "BLE.Scan")
    /// Per-peripheral GATT connection — OsmoBLEConnection
    static let connection = Logger(subsystem: "net.prehiti.payton.CamControl", category: "BLE.Conn")
    /// Single camera model — OsmoCamera
    static let camera     = Logger(subsystem: "net.prehiti.payton.CamControl", category: "Camera")
    /// Multi-camera coordinator — OsmoCameraManager
    static let manager    = Logger(subsystem: "net.prehiti.payton.CamControl", category: "Manager")
    /// Frame parsing and building — FrameParser, FrameBuilder
    static let proto      = Logger(subsystem: "net.prehiti.payton.CamControl", category: "Protocol")
    /// GPS location services — OsmoLocationManager
    static let location   = Logger(subsystem: "net.prehiti.payton.CamControl", category: "Location")
}
