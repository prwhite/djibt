import Foundation

/// Phone-global GPS fix quality, derived in exactly one place
/// (`OsmoLocationManager.fixState`). Rendered gray / blue / red / green by the
/// top-bar indicator, the Settings readout, the watch relay, and the Live
/// Activity.
///
/// Raw values are the wire format pushed to the watch via WCSession
/// (`gpsFix` key); keep them stable.
public enum GPSFixState: String {
    /// GPS push is not enabled by the user. (gray)
    case off
    /// Enabled (armed) but the location session is idled because no cameras
    /// are connected — it engages automatically when one returns. (blue)
    case standby
    /// Running but no usable fix yet (e.g. indoors). (red)
    case noFix
    /// Running with a valid fix. (green)
    case good
}
