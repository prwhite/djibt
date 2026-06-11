import Foundation

/// The BLE + protocol connection state of a single camera.
public enum ConnectionState: Equatable {
    /// No BLE connection exists.
    case disconnected
    /// Actively scanning for this camera's BLE advertisement.
    case scanning
    /// BLE connection established; awaiting GATT service discovery.
    case connecting
    /// Services discovered; performing DJI protocol handshake.
    case handshaking
    /// Fully connected and handshake completed. Camera is responsive.
    case connected
    /// Camera has entered low-power sleep. Commands must not be sent.
    case sleeping
    /// Connection lost; automatic reconnection is in progress.
    case reconnecting
    /// Maximum reconnection retries exceeded. Manual intervention required.
    case failed

    public var isUsable: Bool {
        self == .connected
    }

    /// Whether the camera has live, displayable status (signal/battery/sparklines
    /// shown un-dimmed). True for connected and sleeping (a known, recoverable
    /// state); false for reconnecting/disconnected/failed, where the UI freezes
    /// and dims the last-seen values.
    public var showsLiveStatus: Bool {
        self == .connected || self == .sleeping
    }

    public var displayLabel: String {
        switch self {
        case .disconnected:  return "Disconnected"
        case .scanning:      return "Scanning…"
        case .connecting:    return "Connecting…"
        case .handshaking:   return "Handshaking…"
        case .connected:     return "Connected"
        case .sleeping:      return "Sleeping"
        case .reconnecting:  return "Reconnecting…"
        case .failed:        return "Connection Failed"
        }
    }
}
