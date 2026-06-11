import Foundation

/// Phone-global GPS fix quality, derived in exactly one place
/// (`OsmoLocationManager.fixState`). Rendered gray / red / green by the
/// top-bar indicator, the Settings readout, and the watch relay.
///
/// Raw values are the wire format pushed to the watch via WCSession
/// (`gpsFix` key); keep them stable.
public enum GPSFixState: String {
    /// GPS push is not active. (gray)
    case off
    /// Active but no usable fix yet (e.g. indoors). (red)
    case noFix
    /// Active with a valid fix. (green)
    case good
}
