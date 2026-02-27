import OSLog

/// Centralised OSLog loggers for DJIOsmoKit.
///
/// All files in the framework use these directly — no extra import needed at each call site.
///
/// Filter in Xcode console:  `subsystem == "me.payton.OsmoMulti"`
/// Filter by category:       `category == "BLE.Conn"`
/// Filter errors only:       `level >= error`
///
/// From Terminal (device attached via USB or on same Wi-Fi):
/// ```bash
/// log stream --predicate 'subsystem == "me.payton.OsmoMulti"' --level debug
/// ```
enum OsmoLog {
    /// BLE scanning — OsmoBLEScanner
    static let scan       = Logger(subsystem: "me.payton.OsmoMulti", category: "BLE.Scan")
    /// Per-peripheral GATT connection — OsmoBLEConnection
    static let connection = Logger(subsystem: "me.payton.OsmoMulti", category: "BLE.Conn")
    /// Single camera model — OsmoCamera
    static let camera     = Logger(subsystem: "me.payton.OsmoMulti", category: "Camera")
    /// Multi-camera coordinator — OsmoCameraManager
    static let manager    = Logger(subsystem: "me.payton.OsmoMulti", category: "Manager")
    /// Frame parsing and building — FrameParser, FrameBuilder
    static let proto      = Logger(subsystem: "me.payton.OsmoMulti", category: "Protocol")
}
