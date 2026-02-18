import SwiftUI

struct UsageSourceSheet: View {
    @Environment(\.dismiss) private var dismiss

    let source: UsageSource?
    let initialToken: String
    let onSave: (UsageSource, String) -> Void

    @State private var name: String = ""
    @State private var statsURL: String = ""
    @State private var token: String = ""
    @State private var isEnabled: Bool = true

    @State private var validationMessage: String?

    private var isEditing: Bool {
        source != nil
    }

    private var inferredKind: UsageSourceKind {
        UsageSourceKind.inferred(from: statsURL)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEditing ? "Edit Usage Source" : "Add Usage Source")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Name")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("e.g., Nexus Relay", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Stats URL")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("https://.../key-query or .../api-stats", text: $statsURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))

                        HStack(spacing: 8) {
                            Text("Detected Type")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(inferredKind.displayName)
                                .font(.caption)
                                .fontWeight(.medium)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.primary.opacity(0.08))
                                .clipShape(Capsule())
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Token / API Key")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        SecureField("Enter token", text: $token)
                            .textFieldStyle(.roundedBorder)
                        Text("Stored in macOS Keychain")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    Toggle("Enabled", isOn: $isEnabled)

                    if let validationMessage, !validationMessage.isEmpty {
                        Text(validationMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button(isEditing ? "Save" : "Add") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(20)
        }
        .frame(width: 580, height: 520)
        .onAppear {
            if let source {
                name = source.name
                statsURL = source.statsURL
                isEnabled = source.isEnabled
                token = initialToken
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = statsURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)

        var candidate = UsageSource(
            id: source?.id ?? UUID(),
            name: trimmedName,
            statsURL: trimmedURL,
            kind: UsageSourceKind.inferred(from: trimmedURL),
            isEnabled: isEnabled,
            createdAt: source?.createdAt ?? Date(),
            updatedAt: Date()
        )
        candidate.refreshKind()

        let errors = candidate.validate()
        if !errors.isEmpty {
            validationMessage = errors.joined(separator: "\n")
            return
        }

        if trimmedToken.isEmpty {
            validationMessage = "Token is required"
            return
        }

        onSave(candidate, trimmedToken)
        dismiss()
    }
}
