import DJIOsmoKit
import SwiftUI

#if DEBUG
#Preview("Camera List") {
    let manager = OsmoCameraManager.makePreview()
    NavigationStack {
        CameraListView(manager: manager)
    }
    .environment(manager)   // child views (SettingsView etc.) read from environment
}
#endif

/// Main screen: list of all paired cameras grouped by enabled/disabled status,
/// with global controls anchored to the bottom for thumb reachability.
struct CameraListView: View {

    @State private var viewModel: CameraListViewModel
    @State private var showSettings = false
    @State private var contentWidth: CGFloat = 0

    init(manager: OsmoCameraManager) {
        _viewModel = State(wrappedValue: CameraListViewModel(manager: manager))
    }

    var body: some View {
        cameraList
        .background {
            GeometryReader { geo in
                Color.clear
                    .onChange(of: geo.size.width, initial: true) { _, w in contentWidth = w }
            }
        }
        .navigationTitle("Cameras")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.showAddCamera()
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    viewModel.screenLockDisabled.toggle()
                    viewModel.showToast(viewModel.screenLockDisabled
                        ? "Screen sleep disabled"
                        : "Screen sleep enabled")
                } label: {
                    Image(systemName: viewModel.screenLockDisabled ? "lock.open.display" : "lock.display")
                        .foregroundStyle(viewModel.screenLockDisabled ? .yellow : .secondary)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            GlobalControlsView(viewModel: viewModel, availableWidth: contentWidth)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
        .overlay(alignment: .bottom) {
            if let toast = viewModel.toastMessage {
                Text(toast)
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 96)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut, value: viewModel.toastMessage)
            }
        }
        .animation(.easeInOut, value: viewModel.toastMessage)
        .sheet(isPresented: Binding(
            get: { viewModel.isAddingCamera },
            set: { if !$0 { viewModel.dismissAddCamera() } }
        )) {
            AddCameraView(viewModel: viewModel)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    // MARK: - Camera List

    @ViewBuilder
    private var cameraList: some View {
        if viewModel.enabledCameras.isEmpty && viewModel.disabledCameras.isEmpty {
            emptyState
        } else {
            List {
                Section("Active") {
                    ForEach(viewModel.enabledCameras) { camera in
                        cameraRow(camera, enabled: true)
                    }
                }
                Section("Inactive") {
                    ForEach(viewModel.disabledCameras) { camera in
                        cameraRow(camera, enabled: false)
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    @ViewBuilder
    private func cameraRow(_ camera: OsmoCamera, enabled: Bool) -> some View {
        NavigationLink {
            CameraDetailView(camera: camera, viewModel: viewModel)
        } label: {
            CameraRowView(camera: camera)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button(role: .destructive) {
                viewModel.removeCamera(camera)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    viewModel.toggleEnabled(camera)
                }
            } label: {
                Label(enabled ? "Disable" : "Enable",
                      systemImage: enabled ? "pause.circle" : "play.circle")
            }
            .tint(enabled ? .orange : .green)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Cameras", systemImage: "camera")
        } description: {
            Text("Tap + to pair your first DJI Osmo camera.")
        } actions: {
            Button("Add Camera") { viewModel.showAddCamera() }
                .buttonStyle(.borderedProminent)
        }
    }
}
