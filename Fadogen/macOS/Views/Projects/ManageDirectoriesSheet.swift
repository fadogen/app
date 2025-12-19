import SwiftUI
import SwiftData
import AppKit

struct ManageDirectoriesSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(AppServices.self) private var appServices
    @Query private var directories: [WatchedDirectory]

    var body: some View {
        NavigationStack {
            List {
                ForEach(directories) { directory in
                    HStack {
                        Button {
                            openDirectory(directory)
                        } label: {
                            HStack {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)

                                Text(directory.path)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button {
                            deleteDirectory(directory)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Watched Directories")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        addDirectory()
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
        }
        .frame(minWidth: 500, minHeight: 300)
    }

    private func addDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            // Check if directory with this path already exists
            let pathToCheck = url.path
            let descriptor = FetchDescriptor<WatchedDirectory>(predicate: #Predicate { $0.path == pathToCheck })
            if (try? modelContext.fetch(descriptor).first) != nil {
                // Directory already being watched - silently ignore
                return
            }

            let directory = WatchedDirectory(path: url.path)
            modelContext.insert(directory)
            try? modelContext.save()
        }
    }

    private func deleteDirectory(_ directory: WatchedDirectory) {
        // Detach all projects (deletes LocalProject entries - local-only, safe operation)
        appServices.directoryWatcher.detachAllProjects(for: directory)

        // Delete WatchedDirectory
        modelContext.delete(directory)
        try? modelContext.save()

        // Stop monitoring
        appServices.directoryWatcher.stopWatching(directory)
    }

    private func openDirectory(_ directory: WatchedDirectory) {
        let url = URL(fileURLWithPath: directory.path)
        NSWorkspace.shared.open(url)
    }
}
