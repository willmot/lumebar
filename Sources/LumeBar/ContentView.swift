import SwiftUI

struct ContentView: View {
    @ObservedObject var client: LumeClient
    @ObservedObject var thumbnails: VNCThumbnailStore
    @Binding var noDisplay: Bool
    @Binding var vncDisabled: Bool

    @State private var pollingTask: Task<Void, Never>?

    var body: some View {
        GlassEffectContainer {
            VStack(spacing: 12) {
                header

                if let error = client.errorMessage {
                    ErrorBanner(
                        title: client.serviceReachable == false ? "Can't reach the Lume service" : "Something went wrong",
                        message: error,
                        retry: { Task { await client.fetchVms() } }
                    )
                }

                if client.vms.isEmpty {
                    if !client.isLoading && client.serviceReachable == true {
                        EmptyStateView()
                    }
                } else {
                    VStack(spacing: 8) {
                        ForEach(client.vms) { vm in
                            VMRow(vm: vm, client: client, thumbnails: thumbnails, noDisplay: $noDisplay, vncDisabled: $vncDisabled)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                footer
            }
            .padding(14)
            .glassEffect(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .onAppear {
            thumbnails.beginSnapshotSession()
            startPolling()
        }
        .onDisappear {
            pollingTask?.cancel()
            pollingTask = nil
            thumbnails.stopAll(keepImages: true)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("MenubarIcon", bundle: .module)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Lume")
                    .font(.system(size: 15, weight: .semibold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(serviceColor)
                        .frame(width: 7, height: 7)
                    Text(serviceSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                Task { await client.fetchVms() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .rotationEffect(.degrees(client.isLoading ? 360 : 0))
                    .animation(
                        client.isLoading ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                        value: client.isLoading
                    )
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .help("Refresh")
            .accessibilityLabel("Refresh")
            .keyboardShortcut("r")
        }
    }

    private var serviceColor: Color {
        switch client.serviceReachable {
        case .some(true): .green
        case .some(false): .red
        case .none: .secondary
        }
    }

    private var serviceSummary: String {
        let address = client.serviceAddress
        switch client.serviceReachable {
        case .none:
            return "\(address) · Connecting…"
        case .some(false):
            return "\(address) · Not connected"
        case .some(true):
            let total = client.vms.count
            guard total > 0 else { return "\(address) · No VMs" }
            let running = client.vms.filter(\.isRunning).count
            let vmLabel = total == 1 ? "1 VM" : "\(total) VMs"
            return "\(address) · \(vmLabel) · \(running) running"
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Toggle("Start headless", isOn: $noDisplay)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
                .help("Start VMs without opening a display window (--display none)")

            Toggle("VNC off", isOn: $vncDisabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
                .help("Start VMs with --vnc disabled. Avoids the macOS 27.0 VNC crash and closes the VNC port.")

            Spacer()

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .accessibilityLabel("Settings")

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .keyboardShortcut("q")
        }
        .foregroundStyle(.secondary)
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task {
            await client.fetchVms()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { break }
                if !client.isLoading {
                    await client.fetchVms()
                }
            }
        }
    }
}

private struct ErrorBanner: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Button("Try Again", action: retry)
                        .controlSize(.small)
                    SettingsLink {
                        Text("Open Settings…")
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.red.opacity(0.35))
        )
    }
}

private struct EmptyStateView: View {
    private let command = "lume create my-vm --os macos --ipsw latest"

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
                .frame(width: 52, height: 52)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text("No virtual machines")
                .font(.system(size: 14, weight: .semibold))

            Text("Create one in Terminal. It shows up here automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy command")
                .accessibilityLabel("Copy command")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

private struct VMRow: View {
    let vm: LumeVM
    @ObservedObject var client: LumeClient
    @ObservedObject var thumbnails: VNCThumbnailStore
    @ObservedObject private var settings = ScreenSharingSettings.shared
    @Binding var noDisplay: Bool
    @Binding var vncDisabled: Bool

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .binary
        return formatter
    }()

    private var isBusy: Bool { client.isActionInFlight(vmName: vm.name) }

    private var endpoint: ScreenSharingEndpoint? {
        settings.endpoint(for: vm, details: client.details[vm.name])
    }

    private var thumbnailTaskID: String {
        "\(vm.name)-\(vm.isRunning)-\(endpoint?.key ?? "none")-\(settings.revision)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                osBadge

                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                actions
            }

            if vm.isProvisioning {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(.orange)
                    .controlSize(.small)
            }

            if vm.isRunning {
                DetailsView(vm: vm, client: client, thumbnails: thumbnails)
            }
        }
        .padding(10)
        .glassEffect(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contextMenu { contextMenu }
        .task(id: "\(vm.name)-\(vm.isRunning)") {
            if vm.isRunning {
                await client.fetchDetails(for: vm)
            }
        }
        .task(id: thumbnailTaskID) {
            if vm.isRunning, let endpoint {
                thumbnails.start(vmName: vm.name, endpoint: endpoint)
            } else {
                thumbnails.stop(vmName: vm.name)
            }
        }
        .onChange(of: settings.revision) {
            thumbnails.invalidate(vmName: vm.name)
        }
    }

    private var statusColor: Color {
        if vm.isRunning { return .green }
        if vm.isProvisioning { return .orange }
        return .secondary
    }

    private var osBadge: some View {
        let isLinux = vm.os?.lowercased() == "linux"
        return Image(systemName: isLinux ? "terminal" : "desktopcomputer")
            .font(.system(size: 15))
            .foregroundStyle(statusColor)
            .frame(width: 32, height: 32)
            .background(statusColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let os = vm.os, !os.isEmpty {
            parts.append(os.lowercased() == "macos" ? "macOS" : os.capitalized)
        }
        if let cpu = vm.cpuCount { parts.append("\(cpu) CPU") }
        if let memory = vm.memorySize { parts.append(Self.byteFormatter.string(fromByteCount: memory)) }

        let ip = client.details[vm.name]?.ipAddress ?? vm.ipAddress
        if vm.isRunning, let ip, !ip.isEmpty {
            parts.append(ip)
        } else if !vm.isRunning && !vm.isProvisioning {
            parts.append(vm.stateDescription)
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var actions: some View {
        if vm.isProvisioning {
            Text(vm.provisioningDescription)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(.orange.opacity(0.14), in: Capsule())
        } else if isBusy {
            ProgressView()
                .controlSize(.small)
                .frame(width: 24, height: 24)
        } else if vm.isRunning {
            ScreenSharingButton(vm: vm, client: client)

            Button {
                Task { await client.stop(vm: vm) }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11))
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .help("Stop \(vm.name)")
            .accessibilityLabel("Stop \(vm.name)")
        } else {
            Button {
                Task { await client.run(vm: vm, noDisplay: noDisplay, vncDisabled: vncDisabled) }
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .help(noDisplay ? "Start \(vm.name) headless" : "Start \(vm.name)")
            .accessibilityLabel("Start \(vm.name)")
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if vm.isRunning {
            Button("Open Screen Sharing") {
                Task { await client.openScreenSharing(vm: vm) }
            }
            Picker("Screen Sharing Source", selection: Binding(
                get: { settings.preference(for: vm.name) },
                set: { settings.setPreference($0, for: vm.name) }
            )) {
                ForEach(ScreenSharingPreference.allCases) { Text($0.title).tag($0) }
            }
            Button(settings.guestLogin(for: vm.name) == nil ? "Set Screen Sharing Login…" : "Edit Screen Sharing Login…") {
                settings.promptForGuestLogin(vmName: vm.name)
            }
            Button("Stop") {
                Task { await client.stop(vm: vm) }
            }
        } else if !vm.isProvisioning {
            Button("Start") {
                Task { await client.run(vm: vm, noDisplay: noDisplay, vncDisabled: vncDisabled) }
            }
            Button(noDisplay ? "Start with Display" : "Start Headless") {
                Task { await client.run(vm: vm, noDisplay: !noDisplay, vncDisabled: vncDisabled) }
            }
        }

        Divider()

        Button("Copy Name") {
            copy(vm.name)
        }
        if let ip = client.details[vm.name]?.ipAddress ?? vm.ipAddress, !ip.isEmpty {
            Button("Copy IP Address") {
                copy(ip)
            }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct DetailsView: View {
    let vm: LumeVM
    @ObservedObject var client: LumeClient
    @ObservedObject var thumbnails: VNCThumbnailStore
    @ObservedObject private var settings = ScreenSharingSettings.shared
    @State private var isStatsExpanded = false
    @State private var isHoveringThumbnail = false
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .binary
        return formatter
    }()

    var body: some View {
        let rows = rowsForDetails()

        VStack(alignment: .leading, spacing: 8) {
            if hasScreenPreview {
                thumbnailView
            }

            if let error = client.detailsError[vm.name] {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.red)
            }

            if hasExtraDetails(rows) {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        isStatsExpanded.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                                .rotationEffect(.degrees(isStatsExpanded ? 90 : 0))
                                .animation(.snappy(duration: 0.18), value: isStatsExpanded)
                            Text("Details")
                                .font(.caption.weight(.semibold))
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    if isStatsExpanded {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                            detailRows(rows)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
    }

    /// Only reserve space for a preview when there is a screen to show or one is loading.
    /// Without one, the Screen Sharing button in the VM row is the way to connect.
    private var hasScreenPreview: Bool {
        if thumbnails.image(for: vm.name) != nil { return true }
        guard let endpoint = settings.endpoint(for: vm, details: client.details[vm.name]) else { return false }
        return !(endpoint.kind == .guest && endpoint.canSnapshot == false)
    }

    private var thumbnailView: some View {
        let image = thumbnails.image(for: vm.name)
        let thumbnailAspect: CGFloat = 4.0 / 3.0
        let endpoint = settings.endpoint(for: vm, details: client.details[vm.name])
        let isScreenSharingReady = endpoint != nil
        let needsGuestLogin = endpoint?.kind == .guest && endpoint?.canSnapshot == false

        return ZStack(alignment: .bottomTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.black.opacity(0.25))

                if let image {
                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable()
                        .scaledToFit()
                } else if needsGuestLogin {
                    Label("Screen Sharing · double-click to open", systemImage: "rectangle.on.rectangle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if endpoint == nil {
                    Text("No screen available")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(thumbnails.status(for: vm.name) ?? "Waiting for video…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if (image != nil || needsGuestLogin) && isScreenSharingReady && isHoveringThumbnail {
                Text("Double-click to open")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .foregroundStyle(.white)
                    .padding(8)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: image == nil ? 64 : nil)
        .aspectRatio(image == nil ? nil : thumbnailAspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHoveringThumbnail = hovering }
        }
        .onTapGesture(count: 2) {
            guard isScreenSharingReady else { return }
            Task { await client.openScreenSharing(vm: vm) }
        }
        .help(isScreenSharingReady ? "Double-click to open Screen Sharing" : "Waiting for connection details")
    }

    @ViewBuilder
    private func detailRows(_ rows: [(String, String?)]) -> some View {
        ForEach(rows, id: \.0) { row in
            if let value = sanitized(row.1) {
                GridRow {
                    Text(row.0)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .textSelection(.enabled)
                }
                .font(.caption)
            }
        }
    }

    private func sanitized(_ value: String?) -> String? {
        guard var value else { return nil }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == "—" { return nil }
        return value
    }

    private func rowsForDetails() -> [(String, String?)] {
        if let details = client.details[vm.name] {
            return [
                ("IP", details.ipAddress),
                ("CPU", formatCount(details.cpuCount)),
                ("Memory", formatBytes(details.memorySize)),
                ("Disk", formatDisk(details.diskSize)),
                ("OS", details.os),
                ("Storage", details.storage),
                ("Display", details.display),
                ("Created", details.createdAt)
            ]
        }

        return [
            ("CPU", formatCount(vm.cpuCount)),
            ("Memory", formatBytes(vm.memorySize)),
            ("Disk", formatDisk(vm.diskSize)),
            ("OS", vm.os)
        ]
    }

    private func hasExtraDetails(_ rows: [(String, String?)]) -> Bool {
        rows.contains { row in
            sanitized(row.1) != nil && row.0 != "OS"
        }
    }

    private func formatBytes(_ bytes: Int64?) -> String? {
        guard let bytes else { return nil }
        return Self.byteFormatter.string(fromByteCount: bytes)
    }

    private func formatDisk(_ disk: DiskSize?) -> String? {
        guard let disk else { return nil }
        let total = formatBytes(disk.total)
        let allocated = formatBytes(disk.allocated)
        if let total, let allocated {
            return "\(total) (allocated \(allocated))"
        }
        return total ?? allocated
    }

    private func formatCount(_ value: Int?) -> String? {
        guard let value else { return nil }
        return "\(value)"
    }
}

private struct ScreenSharingButton: View {
    let vm: LumeVM
    @ObservedObject var client: LumeClient
    @ObservedObject private var settings = ScreenSharingSettings.shared

    var body: some View {
        let isReady = settings.endpoint(for: vm, details: client.details[vm.name]) != nil

        return Button {
            Task { await client.openScreenSharing(vm: vm) }
        } label: {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 11))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.small)
        .disabled(!isReady)
        .help(isReady ? "Open Screen Sharing" : "Waiting for connection details")
        .accessibilityLabel("Open Screen Sharing")
    }
}
