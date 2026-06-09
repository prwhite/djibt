import CoreLocation

extension CLLocation {
    /// Single definition of "usable GPS fix". Core Location marks lat/lon
    /// invalid by setting `horizontalAccuracy` negative; a non-negative value
    /// means the coordinate is usable. This is the one place the rule lives —
    /// consumed by `OsmoLocationManager.fixState`/`accuracy`, the
    /// `pushGPSToAllCameras` early-return guard, and `GPSPushCommand`'s
    /// satellite-validity gate.
    var hasValidGPSFix: Bool { horizontalAccuracy >= 0 }
}
