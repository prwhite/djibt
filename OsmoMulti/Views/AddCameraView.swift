import DJIOsmoKit
import SwiftUI

/// Modal sheet for scanning and pairing a new DJI Osmo camera.
struct AddCameraView: View {

    let viewModel: CameraListViewModel
    @Environment(OsmoCameraManager.self) var manager
    @State private var discovered: [DiscoveredCamera] = []
    @State private var isScanning = true

    var body: some View {
        NavigationStack {
            Group {
                if isScanning && discovered.isEmpty {
                    scanningPlaceholder
                } else {
                    List(Array(discovered.enumerated()), id: \.offset) { _, camera in
                        Button {
                            manager.addCamera(camera)
                            viewModel.dismissAddCamera()
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(camera.advertisedName ?? "DJI Osmo Camera")
                                        .font(.body)
                                    Text("Signal: \(camera.rssi) dBm")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Camera")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(discovered.isEmpty ? "Cancel" : "Done") {
                        viewModel.dismissAddCamera()
                    }
                }
                if !discovered.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add All") {
                            for camera in discovered {
                                manager.addCamera(camera)
                            }
                            viewModel.dismissAddCamera()
                        }
                    }
                }
            }
        }
        .task {
            // Consume the OsmoBLEScanner discoveries stream to populate the list
            let scanner = OsmoBLEScanner()
            for await found in scanner.discoveries {
                if !discovered.contains(where: {
                    $0.peripheral.identifier == found.peripheral.identifier
                }) {
                    discovered.append(found)
                }
            }
        }
    }

    private var scanningPlaceholder: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Scanning for DJI Osmo cameras…")
                .foregroundStyle(.secondary)
            Text("Make sure your camera is powered on and not connected to another device.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
