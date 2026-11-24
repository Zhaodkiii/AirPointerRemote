import SwiftUI
import WebKit
import rootshellVNC

struct SystemDesktopHome: View {
    @ObservedObject var connection: PhoneConnection
    @State private var mirror = false

    private struct LoginTarget: Identifiable {
        let computer: DesktopComputer
        let autoConnect: Bool
        var id: DesktopComputer.ID { computer.id }
    }

    @StateObject private var discovery = DesktopDiscovery()
    @AppStorage("desktop.computers") private var stored = Data()
    @State private var address = ""
    @State private var manual = false
    @State private var selection: LoginTarget?
    @FocusState private var addressFocused: Bool

    private var computers: [DesktopComputer] {
        (try? JSONDecoder().decode([DesktopComputer].self, from: stored)) ?? []
    }
    private var nearby: [DesktopComputer] {
        discovery.nearby.filter { device in !computers.contains { $0.id == device.id } }
    }
    private func write(_ items: [DesktopComputer]) {
        if let data = try? JSONEncoder().encode(items) { stored = data }
    }
    private func row(_ item: DesktopComputer, saved: Bool) -> some View {
        Button { selection = LoginTarget(computer: item, autoConnect: true) } label: {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.subheadline.weight(.semibold))
                    if saved {
                        Text("Saved Mac").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Available on the local network").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if saved {
                Button("Remove Saved Mac", systemImage: "trash", role: .destructive) {
                    DesktopCredentials.remove(for: item)
                    write(computers.filter { $0.id != item.id })
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Desktop Mode", selection: $mirror) {
                Text("iPhone Desktop").tag(false)
                Text("Mirror Mac Screen").tag(true)
            }.pickerStyle(.segmented)
            if !mirror {
                Text("Sign in as the current Mac user to control a private, iPhone-sized desktop. The Mac display goes dark until you disconnect.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if !computers.isEmpty {
                Text("My Macs").font(.headline).accessibilityAddTraits(.isHeader)
                ForEach(computers) { row($0, saved: true) }
            }
            if !nearby.isEmpty || computers.isEmpty {
                Text("Macs on Your Network").font(.headline).accessibilityAddTraits(.isHeader)
                if nearby.isEmpty {
                    Text(discovery.status).font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(nearby) { row($0, saved: false) }
            }
            DisclosureGroup("Enter an Address", isExpanded: $manual) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("IP address, mac.local, or vnc:// address", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.go)
                        .focused($addressFocused)
                        .onSubmit(connectByAddress)
                    Button("Continue", action: connectByAddress).buttonStyle(.borderedProminent)
                        .disabled(DesktopComputer.parse(address) == nil)
                }.padding(.top, 8)
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            DisclosureGroup("Set Up Screen Sharing on Your Mac") {
                Text("On your Mac, open System Settings → General → Sharing and turn on Screen Sharing. Allow your Mac account in the service settings. For a VNC password, enable password control there. Connect both devices to the same trusted network.")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.top, 8)
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .fullScreenCover(item: $selection) { target in
            DesktopLogin(connection: connection, computer: target.computer, adaptive: !mirror, autoConnect: target.autoConnect) {
                write([target.computer] + computers.filter { $0.id != target.id })
            }
        }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }

    private func connectByAddress() {
        guard let item = DesktopComputer.parse(address) else { return }
        addressFocused = false
        selection = LoginTarget(computer: item, autoConnect: true)
    }
}

private struct DesktopLogin: View {
    let connection: PhoneConnection
    let computer: DesktopComputer
    let adaptive: Bool
    let autoConnect: Bool
    let remember: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @StateObject private var session = DesktopSession()
    @AppStorage("linked.autoPictureInPicture") private var automaticPiP = true
    @State private var highPerformance = HighPerformanceDesktop()
    @Environment(\.displayScale) private var displayScale
    @State private var account = true
    @State private var username = ""
    @State private var password = ""
    @State private var attempted = false
    @State private var didLoad = false
    @State private var storageFailed = false

    @FocusState private var field: Field?
    private enum Field { case username, password }

    private var connecting: Bool { adaptive ? highPerformance.connecting : session.web != nil && !session.connected }
    private var canConnect: Bool {
        !connecting && !password.isEmpty && (!account || !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        NavigationStack {
            Group {
                if adaptive && highPerformance.ready {
                    RemoteDesktopView(session: highPerformance.session, isFullScreen: true)
                        .ignoresSafeArea()
                        .toolbar(.hidden, for: .navigationBar)
                        .overlay(alignment: .topTrailing) {
                            HStack {
                                Button {
                                    highPerformance.pictureInPicture.start()
                                } label: {
                                    Image(systemName: "pip.enter").frame(width: 44, height: 44)
                                        .background(.regularMaterial, in: Circle())
                                }
                                .accessibilityLabel("Picture in Picture")
                                .disabled(!highPerformance.pictureInPicture.possible || highPerformance.pictureInPicture.active)
                                Button {
                                    highPerformance.stop()
                                    dismiss()
                                } label: {
                                    Image(systemName: "xmark").frame(width: 44, height: 44)
                                        .background(.regularMaterial, in: Circle())
                                }
                                .accessibilityLabel("Disconnect")
                            }
                            .padding(.trailing, 8)
                        }
                        .onAppear { highPerformance.pictureInPicture.attach(to: highPerformance, automatic: automaticPiP) }
                        .alert("Picture in Picture couldn’t start", isPresented: Binding(get: { highPerformance.pictureInPicture.failed }, set: { highPerformance.pictureInPicture.failed = $0 })) {
                            Button("OK", role: .cancel) {}
                        }
                } else if !adaptive && session.connected {
                    DesktopWorkspace(connection: connection, computer: computer, adaptive: false, session: session) {
                        session.stop()
                        dismiss()
                    }
                    .toolbar(.hidden, for: .navigationBar)
                } else {
                    Form {
                        Section {
                            if !adaptive {
                                Picker("Authentication", selection: $account) {
                                    Text("Mac Account").tag(true)
                                    Text("VNC Password").tag(false)
                                }
                                .pickerStyle(.segmented)
                                .onChange(of: account) { _, _ in password = "" }

                            }
                            if account {
                                TextField("Mac Username", text: $username)
                                    .textContentType(.username)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .focused($field, equals: .username)
                                    .submitLabel(.next).onSubmit { field = .password }
                            }
                            SecureField(account ? "Mac Login Password" : "Screen Sharing VNC Password", text: $password)
                                .textContentType(.password)
                                .focused($field, equals: .password)
                                .submitLabel(.go).onSubmit(connect)
                        } footer: {
                            if adaptive {
                                Text("Use the account currently signed in on the Mac.")
                            } else {
                                Text(account ? "Use the account allowed in your Mac’s Screen Sharing settings." : "Use the dedicated VNC password configured on your Mac.")
                            }
                        }.disabled(connecting)

                        Section {
                            Label("Successful sign-ins are saved in this iPhone’s Keychain.", systemImage: "key")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if attempted && !connecting {
                            Text(adaptive ? highPerformance.error ?? "" : session.status).font(.subheadline).foregroundStyle(.secondary)
                                .listRowBackground(Color.clear)
                            if !adaptive, !session.authenticationRejected, let saved = DesktopCredentials.load(for: computer) {
                                Button("Reconnect with Saved Sign-in") {
                                    account = saved.account
                                    username = saved.username
                                    begin(saved)
                                }
                            }
                        }
                        Button(action: connect) {
                            HStack(spacing: 8) {
                                if connecting { ProgressView().controlSize(.small) }
                                Text(connecting ? "Connecting…" : "Connect")
                            }.frame(maxWidth: .infinity, minHeight: 28)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canConnect)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }

                }
            }.navigationTitle(computer.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { session.stop(); dismiss() }
            } }
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            if autoConnect, let saved = DesktopCredentials.load(for: computer), !adaptive || saved.account {
                account = saved.account
                username = saved.username
                begin(saved)
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear.onChange(of: geometry.size, initial: true) { _, size in
                    if adaptive && !highPerformance.ready { highPerformance.resize(size, scale: displayScale) }
                }
            }.ignoresSafeArea()
        }
        .onDisappear { highPerformance.stop(); session.stop() }
        .onChange(of: session.authenticationRejected) { _, rejected in
            if rejected { password = ""; field = .password }
        }
        .alert("Couldn’t Save Sign-in", isPresented: $storageFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You can use this connection. The next sign-in may require your password again.")
        }
        .onChange(of: phase) { _, value in
            if value == .active { highPerformance.pictureInPicture.foregrounded(); session.pictureInPicture.foregrounded() }
            if value == .background {
                if adaptive && highPerformance.ready {
                    highPerformance.pictureInPicture.enteredBackground()
                } else { highPerformance.stop() }
                if !adaptive {
                    if session.connected { session.pictureInPicture.enteredBackground() }
                    else { session.stop() }
                }
                password = ""
                attempted = false
            }
        }
    }
    private func connect() {
        guard canConnect else { return }
        begin(DesktopCredentials(username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password, account: account))
    }

    private func begin(_ credentials: DesktopCredentials) {
        field = nil
        attempted = true
        let didConnect = {
            storageFailed = !credentials.save(for: computer)
            remember()
            password = ""
        }
        if adaptive {
            highPerformance.start(computer, credentials: credentials, connected: didConnect)
        } else {
            session.start(computer, username: credentials.username, password: credentials.password,
                          account: credentials.account, onConnected: didConnect)
        }
    }
}
