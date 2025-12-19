import SwiftUI
import SwiftData

struct EditServerSheet: View {
    let server: Server

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allServers: [Server]

    @State private var name: String = ""

    private var nameHasChanges: Bool {
        let currentName = server.name ?? ""
        return name != currentName
    }

    private var isDuplicateName: Bool {
        guard !name.isEmpty else { return false }
        return allServers.contains { $0.name == name && $0.id != server.id }
    }

    private var canSave: Bool {
        nameHasChanges && !isDuplicateName
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Edit Server")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(20)

            GroupBox {
                HStack(alignment: .center, spacing: 12) {
                    Text("Name")
                        .frame(width: 80, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    TextField(String(localized: "Optional"), text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(8)
            } label: {
                Text("Display Name")
                    .font(.headline)
            }
            .padding(20)

            Spacer()

            Divider()

            VStack(spacing: 8) {
                if isDuplicateName {
                    Text("A server with this name already exists")
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                HStack(spacing: 12) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .keyboardShortcut(.escape)

                    Spacer()

                    Button("Save Changes") {
                        server.name = name.isEmpty ? nil : name
                        try? modelContext.save()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                    .disabled(!canSave)
                }
            }
            .padding(20)
        }
        .frame(width: 450, height: 220)
        .onAppear {
            name = server.name ?? ""
        }
    }
}
