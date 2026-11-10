import SwiftUI
import TermCore
import TermSSH

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(model.profiles) { profile in
                        NavigationLink {
                            ProfileEditor(profile: profile, apiKey: model.apiKey(for: profile), isNew: false)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                Text(profile.baseURL).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    NavigationLink("Add profile") {
                        ProfileEditor(profile: Profile(name: "", baseURL: "https://"), apiKey: "", isNew: true)
                    }
                } header: {
                    Text("API profiles")
                } footer: {
                    Text("OpenAI-compatible endpoints. Keys are stored in the Keychain on this device.")
                }

                Section {
                    ForEach(model.hosts) { host in
                        NavigationLink {
                            HostEditor(host: host, secret: model.hostSecret(for: host),
                                       passphrase: model.hostPassphrase(for: host), isNew: false)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.name)
                                Text(host.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    NavigationLink("Add host") {
                        HostEditor(host: SSHHost(name: "", host: "", username: ""), secret: "", passphrase: "", isNew: true)
                    }
                } header: {
                    Text("SSH hosts")
                } footer: {
                    Text("The agent runs commands on the selected host. Switch with the ⇄ menu or /host.")
                }

                Section("Agent") {
                    Picker("Tool approval", selection: binding(\.approvalMode)) {
                        Text("Ask first").tag(ApprovalMode.ask)
                        Text("Run automatically").tag(ApprovalMode.auto)
                    }
                    NavigationLink("System prompt") {
                        TextEditor(text: binding(\.systemPrompt))
                            .font(.system(.body, design: .monospaced))
                            .padding(8)
                            .navigationTitle("System prompt")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                }

                Section("Appearance") {
                    Picker("Theme", selection: binding(\.themeID)) {
                        ForEach(Theme.all) { theme in
                            Text(theme.name).tag(theme.id)
                        }
                    }
                    Stepper("Font size: \(Int(model.settings.fontSize))", value: binding(\.fontSize), in: 10...20, step: 1)
                }

                Section {
                    EmptyView()
                } footer: {
                    Text("Files the agent writes are in Files › On My iPhone › TermAI.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in model.update { $0[keyPath: keyPath] = value } })
    }
}

private struct ProfileEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var profile: Profile
    @State var apiKey: String
    let isNew: Bool
    @State private var modelsText = ""
    @State private var isFetching = false
    @State private var fetchMessage: String?

    private var modelIDs: [String] {
        var seen = Set<String>()
        return modelsText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private var canSave: Bool {
        !profile.name.trimmingCharacters(in: .whitespaces).isEmpty && URL(string: profile.baseURL)?.host != nil
    }

    var body: some View {
        Form {
            Section("Endpoint") {
                TextField("Name", text: $profile.name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Base URL, e.g. https://api.openai.com/v1", text: $profile.baseURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("API key", text: $apiKey)
            }

            Section {
                TextEditor(text: $modelsText)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 120)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button {
                    fetchModels()
                } label: {
                    HStack {
                        Text("Fetch from endpoint")
                        if isFetching { Spacer(); ProgressView() }
                    }
                }
                .disabled(isFetching || !canSave)
                if let fetchMessage {
                    Text(fetchMessage).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Model IDs")
            } footer: {
                Text("One per line.")
            }

            if !modelIDs.isEmpty {
                Section {
                    Picker("Default model", selection: Binding(
                        get: { profile.defaultModel.flatMap { modelIDs.contains($0) ? $0 : nil } ?? modelIDs[0] },
                        set: { profile.defaultModel = $0 })) {
                        ForEach(modelIDs, id: \.self) { Text($0).tag($0) }
                    }
                }
            }

            if !isNew {
                Section {
                    Button("Delete profile", role: .destructive) {
                        model.deleteProfile(profile)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(isNew ? "New profile" : profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    var saved = profile
                    saved.name = saved.name.trimmingCharacters(in: .whitespaces)
                    saved.baseURL = saved.baseURL.trimmingCharacters(in: .whitespaces)
                    saved.models = modelIDs
                    if let chosen = saved.defaultModel, !modelIDs.contains(chosen) { saved.defaultModel = nil }
                    model.saveProfile(saved, apiKey: apiKey)
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
        .onAppear {
            if modelsText.isEmpty { modelsText = profile.models.joined(separator: "\n") }
        }
    }

    private func fetchModels() {
        isFetching = true
        fetchMessage = nil
        let baseURL = profile.baseURL
        let key = apiKey
        Task {
            do {
                let fetched = try await OpenAIClient().listModels(baseURL: baseURL, apiKey: key)
                let existing = Set(modelIDs)
                let added = fetched.filter { !existing.contains($0) }
                modelsText = (modelIDs + added).joined(separator: "\n")
                fetchMessage = "\(fetched.count) models found, \(added.count) added."
            } catch {
                fetchMessage = "Failed: \(error.localizedDescription)"
            }
            isFetching = false
        }
    }
}

private struct HostEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var host: SSHHost
    @State var secret: String
    @State var passphrase: String
    let isNew: Bool

    private var canSave: Bool {
        ![host.name, host.host, host.username].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            && (1...65_535).contains(host.port)
    }

    var body: some View {
        Form {
            Section("Server") {
                TextField("Name, e.g. web1", text: $host.name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Hostname or IP", text: $host.host)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Port", value: $host.port, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                TextField("Username", text: $host.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }

            Section {
                Picker("Method", selection: $host.auth) {
                    Text("Password").tag(SSHHost.Auth.password)
                    Text("Private key").tag(SSHHost.Auth.privateKey)
                }
                .pickerStyle(.segmented)
                .onChange(of: host.auth) {
                    secret = ""
                    passphrase = ""
                }
                if host.auth == .password {
                    SecureField("Password", text: $secret)
                } else {
                    TextEditor(text: $secret)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(minHeight: 120)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Passphrase (if the key has one)", text: $passphrase)
                }
            } header: {
                Text("Authentication")
            } footer: {
                Text(host.auth == .password
                     ? "Stored in the Keychain on this device."
                     : "Paste an Ed25519 or RSA private key in OpenSSH format (-----BEGIN OPENSSH PRIVATE KEY-----). Stored in the Keychain on this device.")
            }

            if let key = host.trustedHostKey {
                Section {
                    Text(SSHKeys.fingerprint(ofOpenSSHKey: key)).font(.system(.caption, design: .monospaced))
                    Button("Forget host key", role: .destructive) { host.trustedHostKey = nil }
                } header: {
                    Text("Trusted host key")
                } footer: {
                    Text("Recorded on first connection. Connections are refused if the server presents a different key.")
                }
            }

            if !isNew {
                Section {
                    Button("Delete host", role: .destructive) {
                        model.deleteHost(host)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(isNew ? "New host" : host.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    var saved = host
                    saved.name = saved.name.trimmingCharacters(in: .whitespaces)
                    saved.host = saved.host.trimmingCharacters(in: .whitespaces)
                    saved.username = saved.username.trimmingCharacters(in: .whitespaces)
                    model.saveHost(saved, secret: secret, passphrase: passphrase)
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
    }
}
