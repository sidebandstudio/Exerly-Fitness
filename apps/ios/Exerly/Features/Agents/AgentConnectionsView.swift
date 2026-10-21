import ExerlyCore
import SwiftUI
import UIKit

struct AgentConnectionsView: View {
    @StateObject private var model: AgentConnectionsModel
    @State private var creating = false
    @State private var revoking: AccessToken?
    @AccessibilityFocusState private var errorFocused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    init(api: AccountAPI, hasPassword: Bool) {
        _model = StateObject(wrappedValue: AgentConnectionsModel(api: api, hasPassword: hasPassword))
    }

    var body: some View {
        ExList {
            Section {
                ExCard(accent: true) {
                    Text(model.tokens.isEmpty ? "Bring your own agent" : "\(model.tokens.count) connected").font(.exH2)
                    Button { creating = true } label: {
                        if typeSize.isAccessibilitySize {
                            Text("Connect an agent")
                        } else {
                            Label("Connect an agent", systemImage: "plus")
                        }
                    }
                        .buttonStyle(ExActionStyle()).accessibilityIdentifier("agents.create")
                    Text("Choose what an agent can read or change.")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            }
            Section("Connection details") {
                if let endpoint = AgentConnectionInfo.endpoint {
                    Text("MCP endpoint").font(.subheadline.weight(.semibold))
                    Text(endpoint.absoluteString).font(.footnote).textSelection(.enabled)
                    Button("Copy endpoint", systemImage: "doc.on.doc") {
                        UIPasteboard.general.url = endpoint
                    }
                } else {
                    Text("The connection endpoint is unavailable in this build.").foregroundStyle(.secondary)
                }
                Text("Add this endpoint to your agent's MCP settings, then use the access token as its Bearer token. Anyone with that token has the permissions you select.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if model.isLoading || !model.tokens.isEmpty {
            Section("Active access") {
                if model.isLoading { ProgressView("Loading agents…") }
                ForEach(model.tokens) { token in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(token.name).font(.headline)
                        Text(permission(token)).font(.subheadline)
                        Text(token.prefix + "…").font(.caption.monospaced()).foregroundStyle(.secondary)
                        if let last = token.lastUsedAt {
                            Text("Last used \(last.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        } else { Text("Not used yet").font(.caption).foregroundStyle(.secondary) }
                        if let expiry = token.expiresAt {
                            Text("Expires \(expiry.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        } else { Text("No expiry").font(.caption).foregroundStyle(.secondary) }
                        Button("Revoke access", role: .destructive) { revoking = token }
                            .accessibilityLabel("Revoke access for \(token.name)")
                            .accessibilityIdentifier("agents.revoke.\(token.id)")
                    }.padding(.vertical, 4)
                }
            }
            }
            if let error = model.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.exError).accessibilityFocused($errorFocused)
                    Button("Try again") { Task { await model.refresh() } }
                }
            }
        }
        .navigationTitle("Connected agents").navigationBarTitleDisplayMode(.inline)
        .exListStyle()
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
        .onChange(of: model.error) { _, value in errorFocused = value != nil }
        .sheet(isPresented: $creating, onDismiss: { model.clearSecret() }, content: {
            NewAgentConnectionView(model: model)
        })
        .alert("Revoke \(revoking?.name ?? "agent") access?", isPresented: Binding(
            get: { revoking != nil }, set: { if !$0 { revoking = nil } })) {
            Button("Cancel", role: .cancel) { revoking = nil }
            Button("Revoke access", role: .destructive) {
                guard let token = revoking else { return }
                revoking = nil
                Task { await model.revoke(token) }
            }
        } message: {
            Text("This token will stop working immediately. Saved records and previous suggestions stay in your account.")
        }
    }

    private func permission(_ token: AccessToken) -> String {
        if token.scopes.contains(.write) { return "Direct write · can change records" }
        if token.scopes.contains(.propose) { return "Read and propose · you review changes" }
        return "Read only"
    }
}

private struct NewAgentConnectionView: View {
    @ObservedObject var model: AgentConnectionsModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var name = ""
    @State private var permission = AgentConnectionsModel.Permission.propose
    @State private var expiry = 30
    @State private var confirmingWrite = false
    @State private var password = ""
    @State private var pendingApple: AccountConfirmation?
    @State private var revealing = false
    @State private var copied = false
    @FocusState private var nameFocused: Bool
    @FocusState private var passwordFocused: Bool
    @AccessibilityFocusState private var errorFocused: Bool

    var body: some View {
        NavigationStack {
            ExForm {
                if let created = model.created {
                    Section("Access token created") {
                        Text(created.token.name).font(.headline)
                        Text("Copy this token now. You cannot retrieve it after closing this screen.")
                        if revealing {
                            Text(created.secret).font(.body.monospaced()).textSelection(.enabled).privacySensitive()
                        } else {
                            Text("Token hidden").font(.body.monospaced()).foregroundStyle(.secondary)
                        }
                        Button(revealing ? "Hide token" : "Show token", systemImage: revealing ? "eye.slash" : "eye") {
                            revealing.toggle()
                        }
                        Button(copied ? "Token copied" : "Copy token", systemImage: copied ? "checkmark" : "doc.on.doc") {
                            UIPasteboard.general.setItems([["public.utf8-plain-text": created.secret]],
                                options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
                            copied = true
                        }.accessibilityIdentifier("agents.copyToken")
                        Text("The copied token stays on this device's clipboard for 10 minutes. Paste it into the agent you trust.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section {
                        Button("Done") { close() }.accessibilityIdentifier("agents.tokenDone")
                    }
                } else {
                    Section {
                        ExCard(accent: true) {
                            Text("Agent name").font(.exBodyMedium)
                            TextField("For example, Training coach", text: $name, axis: .vertical)
                                .lineLimit(1...3).font(.exBody).textInputAutocapitalization(.words)
                                .focused($nameFocused).submitLabel(.done).onSubmit { nameFocused = false }
                                .onChange(of: name) { _, value in
                                    // Let a long name wrap, but treat Return as Done.
                                    // Multiline fields can insert it instead of submitting.
                                    if value.rangeOfCharacter(from: .newlines) != nil {
                                        name = value.components(separatedBy: .newlines).joined(separator: " ")
                                            .trimmingCharacters(in: .whitespacesAndNewlines)
                                        nameFocused = false
                                    }
                                }
                                .padding(ExSpacing.content)
                                .background(Color.exSurface2, in: RoundedRectangle(cornerRadius: ExRadius.control))
                                .accessibilityLabel("Agent name").accessibilityIdentifier("agents.name")
                            Text("Name the agent so you can recognize its access later.").font(.exCaption).foregroundStyle(Color.exTextSecondary)
                        }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                    }
                    Section("Permissions") {
                        Menu {
                            Picker("Access", selection: $permission) {
                                ForEach(AgentConnectionsModel.Permission.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                Text(permission.rawValue).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.up.chevron.down").font(.caption)
                            }
                            .padding(.vertical, 4)
                        }
                        .accessibilityLabel("Access, \(permission.rawValue)")
                        .accessibilityIdentifier("agents.permission")
                        Text(permissionDescription).font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Expiry") {
                        Picker("Expires after", selection: $expiry) {
                            Text("7 days").tag(7)
                            Text("30 days").tag(30)
                            Text("90 days").tag(90)
                        }
                    }
                    Section {
                        if model.confirmsWithApple {
                            AppleAuthorizationButton { payload in
                                guard !model.isBusy, !nameMissing else { return }
                                pendingApple = .apple(identityToken: payload.identityToken, rawNonce: payload.rawNonce,
                                                      authorizationCode: nil)
                                if permission == .write { confirmingWrite = true } else { create() }
                            }
                            .disabled(model.isBusy || nameMissing)
                        } else {
                            // A visible label: a filled password field shows nothing
                            // in screenshots, and the placeholder is gone once typed.
                            VStack(alignment: .leading, spacing: ExSpacing.small) {
                                Text("Password").font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                                    .accessibilityHidden(true)
                                SecureField("Password", text: $password,
                                            prompt: Text("Your sign-in password").foregroundStyle(Color.exTextSecondary))
                                    .textContentType(.password)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .focused($passwordFocused).submitLabel(.done)
                                    .onSubmit { passwordFocused = false }
                                    .padding(ExSpacing.content)
                                    .background(Color.exSurface2, in: RoundedRectangle(cornerRadius: ExRadius.control))
                                    .accessibilityIdentifier("agents.password")
                            }
                        }
                        if model.isBusy { ProgressView("Creating access…") }
                        if !model.confirmsWithApple {
                            Button("Create access token") {
                                if permission == .write { confirmingWrite = true } else { create() }
                            }
                            .disabled(model.isBusy || nameMissing || password.isEmpty)
                            .accessibilityIdentifier("agents.confirmCreate").buttonStyle(ExActionStyle())
                        }
                    } header: {
                        Text("Confirm it’s you")
                    } footer: {
                        Text(model.confirmsWithApple
                             ? "The token keeps working after you sign out, so Sign in with Apple again to create it."
                             : "The token keeps working after you sign out, so enter the password you sign in with.")
                    }
                }
                if let error = model.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.exError).accessibilityFocused($errorFocused)
                    }
                }
            }
            .navigationTitle(model.created == nil ? "Connect an agent" : "Save your token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { nameFocused = false; passwordFocused = false }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.created == nil ? "Cancel" : "Close") { close() }
                }
            }
            .onChange(of: model.error) { _, value in errorFocused = value != nil }
            .onChange(of: scenePhase) { _, phase in if phase != .active { revealing = false } }
            .onDisappear { model.clearSecret() }
            .alert("Allow direct changes?", isPresented: $confirmingWrite) {
                Button("Cancel", role: .cancel) { pendingApple = nil }
                Button("Allow direct write", role: .destructive) { create() }
            } message: {
                Text("This agent can create, edit and delete your records without asking you to review a suggestion first. Choose Read and propose if you want to approve changes.")
            }
        }
    }

    private var permissionDescription: String {
        switch permission {
        case .propose: "Recommended. The agent can read your records and file suggestions. You decide whether to apply them."
        case .read: "The agent can read your records but cannot file suggestions or change data."
        case .write: "Advanced. The agent can change and delete records directly, without your review."
        }
    }

    private var nameMissing: Bool { name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func create() {
        passwordFocused = false
        let confirmation = pendingApple ?? .password(password)
        pendingApple = nil
        Task {
            let created = await model.create(name: name, permission: permission, expiresInDays: expiry,
                                             confirmation: confirmation)
            if !created, case .password = confirmation { password = "" }
        }
    }

    private func close() { model.clearSecret(); dismiss() }
}

private enum AgentConnectionInfo {
    static var endpoint: URL? {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["EXERLY_API_BASE_URL"], let url = URL(string: raw) {
            return url.appendingPathComponent("mcp")
        }
        #endif
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "EXERLY_API_BASE_URL") as? String,
              let url = URL(string: raw), ["https", "http"].contains(url.scheme ?? "") else { return nil }
        return url.appendingPathComponent("mcp")
    }
}
