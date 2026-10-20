import SwiftUI
import PanelKit

struct AuthView: View {
    @StateObject private var store = Store()
    @StateObject private var auth = AuthManager()
    @State private var message: String?
    @State private var showAddSecret = false
    @State private var export: ExportRequest?
    @State private var authing = false
    @State private var pointer = HoverPointer()
    @StateObject private var ring = RingModel()
    /// The last deleted account and where it was, while its Undo is up.
    @State private var undo: (account: Account, index: Int, token: UUID)?

    nonisolated private static let space = "authList"
    private var accent: Color { .panelAccent }

    var body: some View {
        VStack(spacing: 0) {
            if !auth.isUnlocked {
                lockedView
            } else {
                contentView
            }
        }
        .onAppear {
            log("AuthView.onAppear")
            AppDelegate.instance?.isAuthVisible = true
            startRing()
            // Esc closes the ring or the export card before it closes the panel.
            AppDelegate.escapeHandler = {
                if ring.state != nil { ring.close(); return true }
                if export != nil { closeExport(); return true }
                return false
            }
        }
        .onDisappear {
            log("AuthView.onDisappear")
            AppDelegate.instance?.isAuthVisible = false
            ring.stop()
            AppDelegate.escapeHandler = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .popoverWillClose)) { _ in
            log("AuthView.popoverWillClose")
            export = nil
            ring.close()
            undo = nil
            auth.lock()
        }
        // The export card sits in the panel, over a dimmed tab, instead of a
        // sheet with its own window frame.
        .overlay {
            ZStack {
                if export != nil {
                    Color.black.opacity(0.35)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: closeExport)
                        .transition(.opacity)
                }
                if let request = export {
                    ExportAccountsView(request: request, onDone: closeExport)
                        .transition(.scale(scale: 0.88, anchor: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.84), value: export?.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .popoverDidShow)) { _ in
            log("AuthView.popoverDidShow isUnlocked=\(auth.isUnlocked)")
            if auth.isUnlocked { auth.lock() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .authTabActivated)) { _ in
            log("AuthView.authTabActivated")
            if !auth.isUnlocked {
                auth.lock()
                auth.unlock()
            }
        }
    }

    private var lockedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 34))
                .foregroundColor(accent)
            VStack(spacing: 6) {
                Text("Authenticator Locked")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Text("Authenticate to view your codes.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }

            if let err = auth.lastError {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundColor(.orange.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            Button(action: { auth.unlock() }) {
                HStack(spacing: 6) {
                    if authing {
                        ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "touchid")
                    }
                    Text(authing ? "Authenticating…" : (auth.lastError != nil ? "Try Again" : "Unlock with Touch ID"))
                        .fontWeight(.semibold)
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .foregroundColor(accent)
                .background(Capsule().fill(accent.opacity(0.12)))
                .overlay(Capsule().stroke(accent.opacity(0.25), lineWidth: 0.5))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(authing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .onReceive(NotificationCenter.default.publisher(for: .biometricWillBegin)) { _ in authing = true }
        .onReceive(NotificationCenter.default.publisher(for: .biometricDidEnd)) { _ in authing = false }
        .onAppear { log("AuthView.lockedView.onAppear") }
    }

    private var contentView: some View {
        VStack(spacing: 6) {
            header

            if store.accounts.isEmpty {
                emptyState
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(store.accounts) { account in
                                AccountRow(account: account, now: context.date)
                                    .hoverFrame(account.id, in: pointer, space: Self.space)
                                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: store.accounts.map(\.id))
                    }
                    .coordinateSpace(.named(Self.space))
                    .background(PointerProbe(pointer: pointer))
                    .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, _ in ring.close() }
                    .overlay(alignment: .topLeading) {
                        if let state = ring.state {
                            ActionRing(state: state, onPick: ring.pick, onHighlight: ring.highlight,
                           onConfirm: ring.confirm, onCancelConfirm: ring.cancelConfirm)
                                .transition(.opacity.combined(with: .scale(scale: 0.7)))
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if undo != nil { undoPill }
                    }
                }
            }

            if let msg = message {
                Text(msg)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.bottom, 4)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.shield")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
            Text("Authenticator")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.6))
            Spacer()
            HStack(spacing: 6) {
                Menu {
                    Button {
                        showAddSecret = true
                    } label: {
                        Label("Add secret key", systemImage: "key.fill")
                    }
                    Divider()
                    Button("Scan QR from screen\u{2026}") { importFromScreen() }
                    Button("Scan QR from image\u{2026}") { importFromImage() }
                    if SimAuthImport.isAvailable() {
                        Divider()
                        Button("Import from SimAuth") { importFromSimAuth() }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .help("Add account")

                if !store.accounts.isEmpty {
                    Button(action: { exportAccounts(store.accounts) }) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .help("Export accounts as a QR code")
                }

                if auth.biometricsAvailable {
                    Button(action: { auth.lock() }) {
                        Image(systemName: "lock")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .help("Lock")
                }
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.04))
                .frame(height: 0.5)
                .padding(.horizontal, 8)
        }
        .sheet(isPresented: $showAddSecret) {
            AddSecretView(store: store, message: $message)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "key.horizontal")
                .font(.system(size: 22))
                .foregroundColor(.white.opacity(0.12))
            Text("No accounts yet")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.3))
            Text("Tap + to add a secret key\nor scan a QR code")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.2))
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    private func setMessage(_ text: String) {
        message = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if message == text { message = nil }
        }
    }

    private func addFromStrings(_ strings: [String]) {
        var accounts: [Account] = []
        
        for string in strings {
            // Check if it's a migration URL first
            if string.lowercased().hasPrefix("otpauth-migration://") {
                if let migrationAccounts = MigrationHandler.parseMigrationURL(string) {
                    accounts.append(contentsOf: migrationAccounts)
                    continue
                }
            }
            
            // Otherwise treat as regular otpauth URL
            if let account = Account.from(uri: string) {
                accounts.append(account)
            }
        }
        
        guard !accounts.isEmpty else {
            setMessage("No valid accounts found.")
            return
        }
        
        let added = store.addMany(accounts)
        if added > 0 {
            setMessage("Imported \(added) account(s).")
        } else {
            setMessage("Already imported.")
        }
    }

    private func importFromScreen() {
        // A screenshot of another app's window is blank without Screen Recording
        // permission. Request it (one-time), and since the grant needs a relaunch,
        // tell the user to reopen rather than silently capturing a black frame.
        guard QRImport.hasScreenAccess else {
            QRImport.requestScreenAccess()
            setMessage("Allow Screen Recording for Oxine in System Settings, then reopen Oxine to scan from the screen.")
            return
        }
        let strings = QRImport.captureScreenRegion()
        if strings.isEmpty {
            setMessage("No QR code found in that selection.")
        } else {
            addFromStrings(strings)
        }
    }

    private func importFromImage() {
        let strings = QRImport.pickImageAndDecode()
        addFromStrings(strings)
    }

    private func closeExport() { export = nil }

    // MARK: Right-click ring

    private func startRing() {
        ring.target = {
            guard let point = pointer.location, let id = pointer.row(at: point) else { return nil }
            return (id, point, pointer.viewport)
        }
        ring.choices = { id in
            guard store.accounts.contains(where: { $0.id == id }) else { return [] }
            return [
                RingChoice(slot: .upLeft, icon: "doc.on.doc", title: "Copy code"),
                RingChoice(slot: .upRight, icon: "square.and.arrow.up", title: "Export…"),
                RingChoice(slot: .down, icon: "trash", title: "Delete", danger: true),
            ]
        }
        ring.perform = { slot, id in
            guard let account = store.accounts.first(where: { $0.id == id }) else { return }
            switch slot {
            case .upLeft:
                guard let code = account.totp?.code(at: Date()) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                setMessage("Copied")
            case .upRight:
                exportAccounts([account])
            case .down:
                delete(account)
            }
        }
        ring.start()
    }

    /// Deleting an account loses its secret, so Undo stays up for a while.
    private func delete(_ account: Account) {
        guard let index = withAnimation(.spring(response: 0.34, dampingFraction: 0.88), { store.remove(account) }) else { return }
        let token = UUID()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { undo = (account, index, token) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            if undo?.token == token { withAnimation(.easeOut(duration: 0.2)) { undo = nil } }
        }
    }

    private var undoPill: some View {
        HStack(spacing: 10) {
            Text("Deleted")
                .foregroundColor(.white.opacity(0.85))
            Button("Undo") {
                guard let last = undo else { return }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    store.restore(last.account, at: last.index)
                    undo = nil
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(Color.panelAccent)
            .fontWeight(.semibold)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .frame(height: 32)
        .glassEffect(.regular, in: Capsule())
        .padding(.bottom, 10)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// The export shows raw secrets, so it asks for Touch ID again even though
    /// the codes are already unlocked.
    private func exportAccounts(_ accounts: [Account]) {
        confirmWithBiometrics(reason: "show your authenticator secrets for export") { ok in
            if ok { export = ExportRequest(accounts: accounts) }
        }
    }

    private func importFromSimAuth() {
        do {
            let accounts = try SimAuthImport.loadAccounts()
            let added = store.addMany(accounts)
            setMessage("Imported \(added) of \(accounts.count) from SimAuth.")
        } catch {
            setMessage("\(error)")
        }
    }
}

/// One account: click copies its code. Right-click opens the ring.
struct AccountRow: View {
    let account: Account
    let now: Date
    @State private var copied = false

    var body: some View {
        let totp = account.totp
        let code = totp?.code(at: now) ?? "------"
        let remaining = totp?.secondsRemaining(at: now) ?? 0
        let progress = totp?.progress(at: now) ?? 0

        Button(action: { copy(code) }) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.issuer.isEmpty ? account.account : account.issuer)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                    if !account.issuer.isEmpty && !account.account.isEmpty {
                        Text(account.account)
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.35))
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(formatted(code))
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(copied ? Color(red: 0.3, green: 0.85, blue: 0.5) : .white.opacity(0.9))
                CountdownRing(progress: progress, remaining: remaining)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(copied ? 0.06 : 0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(.white.opacity(0.04), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied!" : "Click to copy")
    }

    private func formatted(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let mid = code.index(code.startIndex, offsetBy: 3)
        return "\(code[..<mid]) \(code[mid...])"
    }

    private func copy(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

struct CountdownRing: View {
    let progress: Double
    let remaining: Int

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.1), lineWidth: 3)
            Circle()
                .trim(from: 0, to: 1 - progress)
                .stroke(remaining <= 5 ? Color.red.opacity(0.7) : Color.panelAccent,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(remaining)")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(width: 24, height: 24)
    }
}

struct AddSecretView: View {
    @ObservedObject var store: Store
    @Binding var message: String?
    @State private var secretInput = ""
    @State private var issuerInput = ""
    @State private var accountInput = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Text("Add Account")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .padding(.top, 12)

            VStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Secret key (base32)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                    TextField("JBSWY3DPEHPK3PXP", text: $secretInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.white.opacity(0.05))
                        )
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Issuer")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                    TextField("GitHub", text: $issuerInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.white.opacity(0.05))
                        )
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Account")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                    TextField("user@example.com", text: $accountInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.white.opacity(0.05))
                        )
                }
            }
            .padding(.horizontal, 16)

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))

                Button("Add") {
                    let trimmed = secretInput.trimmingCharacters(in: .whitespaces)
                    guard Base32.isValid(trimmed) else {
                        message = "Invalid secret key"
                        dismiss()
                        return
                    }
                    let account = Account(
                        issuer: issuerInput.trimmingCharacters(in: .whitespaces),
                        account: accountInput.trimmingCharacters(in: .whitespaces),
                        secret: trimmed.uppercased()
                    )
                    if store.add(account) {
                        message = "Added \(account.label)"
                    } else {
                        message = "Duplicate account"
                    }
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color.panelAccent)
                .disabled(!Base32.isValid(secretInput.trimmingCharacters(in: .whitespaces)))
            }
            .padding(.bottom, 12)
        }
        .frame(width: 280)
        .background(Color(red: 0.08, green: 0.08, blue: 0.1))
        .cornerRadius(14)
    }
}
