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
                Text(isEditing ? "编辑用量数据源" : "新增用量数据源")
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
                        Text("名称")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("例如：Nexus 中转", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("统计 URL")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("https://.../key-query 或 .../api-stats", text: $statsURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))

                        HStack(spacing: 8) {
                            Text("自动识别类型")
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
                        SecureField("请输入 Token", text: $token)
                            .textFieldStyle(.roundedBorder)
                        Text("将安全存储在 macOS 钥匙串")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    Toggle("启用", isOn: $isEnabled)

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
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button(isEditing ? "保存" : "新增") {
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
            validationMessage = "Token 不能为空"
            return
        }

        onSave(candidate, trimmedToken)
        dismiss()
    }
}
