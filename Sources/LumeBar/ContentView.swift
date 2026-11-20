import SwiftUI

struct ContentView: View {
    @ObservedObject var client: LumeClient
    @ObservedObject var thumbnails: VNCThumbnailStore
    @Binding var noDisplay: Bool
    @Binding var vncDisabled: Bool
    @State private var listHeight: CGFloat = 60

    var body: some View {
        GlassEffectContainer {
            VStack(spacing: 12) {
                header

                if let error = client.serviceError {
                    ErrorBanner(
                        title: "Lume service unavailable",
                        message: error,
                        actionTitle: "Try Again",
                        action: { Task { await client.fetchVms(startLocalService: true) } }
                    )
                } else if let error = client.actionError {
                    ErrorBanner(title: "VM action failed", message: error, actionTitle: "Dismiss",
                                action: client.dismissActionError)
                }

                if client.vms.isEmpty {
                    if client.serviceReachable == true {
                        EmptyStateView()
                    } else if client.isLoading || (client.isConfigured && client.serviceReachable == nil) {
                        ProgressView("Connecting to Lume…")
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(client.vms) { vm in
                                VMRow(vm: vm, client: client, thumbnails: thumbnails,
                                      noDisplay: noDisplay, vncDisabled: vncDisabled)
                            }
                        }
                        .padding(2)
                    }
                    .defaultScrollAnchor(.top)
                    .onScrollGeometryChange(for: CGFloat.self) { geometry in
                        min(420, max(56, geometry.contentSize.height))
                    } action: { _, height in
                        listHeight = height
                    }
                    .frame(height: listHeight)
                }

                Divider()

                footer
            }
            .padding(14)
            .glassEffect(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .task(id: client.serviceRevision) {
            await client.fetchVms(startLocalService: true)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await client.fetchVms()
            }
        }
        .onDisappear { thumbnails.stopAll() }
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
                Task { await client.fetchVms(startLocalService: true) }
            } label: {
                if client.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .disabled(client.isLoading)
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
            return client.isConfigured ? "\(address) · Connecting…" : "Set a service URL"
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
            Picker("Start VMs", selection: VMStartMode.selection(noDisplay: $noDisplay, vncDisabled: $vncDisabled)) {
                ForEach(VMStartMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .controlSize(.small)
            .fixedSize()

            Spacer()

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .accessibilityLabel("Settings")
            .keyboardShortcut(",")

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .keyboardShortcut("q")
        }
        .foregroundStyle(.secondary)
    }

}

private struct ErrorBanner: View {
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

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
                    .lineLimit(3)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Button(actionTitle, action: action)
                        .controlSize(.small)
                    if actionTitle == "Try Again" {
                        SettingsLink { Text("Open Settings…") }
                            .buttonStyle(.link)
                            .controlSize(.small)
                    }
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

            Text("Create a VM on the Lume host.")
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
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
    let noDisplay: Bool
    let vncDisabled: Bool
    @State private var canPreview = false

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .binary
        return formatter
    }()

    private var isBusy: Bool { client.vmActionsInFlight.contains(vm.id) }
    private var canAct: Bool { client.serviceReachable == true && !isBusy }
    private var service: URL? { client.baseURL }
    private var details: LumeVMDetails? { client.details[vm.id] }

    private struct PreviewRequest: Equatable {
        let active: Bool
        let revision: UUID
        let settingsRevision: Int
        let address: String?
        let vncURL: String?
        let macAddress: String?
    }

    private var previewRequest: PreviewRequest {
        PreviewRequest(active: vm.isRunning && client.serviceReachable == true,
                       revision: client.serviceRevision, settingsRevision: settings.revision,
                       address: ScreenSharingEndpoint.guestAddress(for: vm, details: details),
                       vncURL: details?.vncUrl ?? vm.vncUrl, macAddress: vm.macAddress)
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
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let addressLine {
                        Text(addressLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                actions

                Menu {
                    contextMenu
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Actions for \(vm.name)")
                .accessibilityLabel("Actions for \(vm.name)")
            }

            if vm.isProvisioning {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(.orange)
                    .controlSize(.small)
            }

            if vm.isRunning {
                DetailsView(vm: vm, client: client, thumbnails: thumbnails, canPreview: canPreview)
            }
        }
        .padding(10)
        .glassEffect(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contextMenu { contextMenu }
        .task(id: previewRequest) {
            thumbnails.stop(vm: vm.id)
            canPreview = false
            guard previewRequest.active, let service else { return }
            guard let endpoint = settings.endpoint(for: vm, details: details, service: service) else {
                await client.fetchDetails(for: vm)
                return
            }
            canPreview = endpoint.canSnapshot
            thumbnails.start(vm: vm.id, endpoint: endpoint)
        }
        .onDisappear { thumbnails.stop(vm: vm.id) }
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

        if !vm.isProvisioning { parts.append(vm.stateDescription) }
        if addressLine == nil, let storage = storageLabel { parts.append(storage) }
        return parts.joined(separator: " · ")
    }

    private var addressLine: String? {
        guard vm.isRunning, let ip = details?.ipAddress ?? vm.ipAddress, !ip.isEmpty else { return nil }
        return storageLabel.map { "\(ip) · \($0)" } ?? ip
    }

    private var storageLabel: String? {
        guard let storage = vm.storage, !storage.isEmpty, storage != "default" else { return nil }
        return storage
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
            .disabled(!canAct)
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
            .disabled(!canAct)
            .help((noDisplay || vncDisabled) ? "Start \(vm.name) headless" : "Start \(vm.name)")
            .accessibilityLabel("Start \(vm.name)")
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if vm.isRunning, let service {
            Button("Open Screen Sharing") {
                Task { await client.openScreenSharing(vm: vm) }
            }
            .disabled(!canAct)
            Picker("Screen Sharing Source", selection: Binding(
                get: { settings.preference(for: vm, service: service) },
                set: { settings.setPreference($0, for: vm, service: service) }
            )) {
                ForEach(ScreenSharingPreference.allCases) { Text($0.title).tag($0) }
            }
            if ScreenSharingEndpoint.resolve(vm: vm, details: details, preference: .guest, guestLogin: nil) != nil,
               let address = ScreenSharingEndpoint.guestAddress(for: vm, details: details) {
                Button("Screen Sharing Login…") {
                    settings.promptForGuestLogin(vm: vm, service: service, address: address)
                }
                .disabled(!canAct)
            }
            Button("Stop") {
                Task { await client.stop(vm: vm) }
            }
            .disabled(!canAct)
        } else if !vm.isProvisioning {
            Button("Start") {
                Task { await client.run(vm: vm, noDisplay: noDisplay, vncDisabled: vncDisabled) }
            }
            .disabled(!canAct)
            if !vncDisabled {
                Button(noDisplay ? "Start with Display" : "Start Headless") {
                    Task { await client.run(vm: vm, noDisplay: !noDisplay, vncDisabled: false) }
                }
                .disabled(!canAct)
            }
        }

        Divider()

        Button("Copy Name") {
            copy(vm.name)
        }
        if let ip = client.details[vm.id]?.ipAddress ?? vm.ipAddress, !ip.isEmpty {
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
    let canPreview: Bool
    @State private var isStatsExpanded = false
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .binary
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if canPreview { thumbnailView }

            DisclosureGroup("Details", isExpanded: $isStatsExpanded) {
                if let error = client.detailsError[vm.id] {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    detailRows(rowsForDetails())
                }
                .padding(.top, 5)
            }
            .font(.caption)
            .task(id: isStatsExpanded) {
                if isStatsExpanded { await client.fetchDetails(for: vm) }
            }
        }
    }

    private var thumbnailView: some View {
        Group {
            if let image = thumbnails.images[vm.id] {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 145)
                    .clipShape(.rect(cornerRadius: 8))
                    .frame(maxWidth: .infinity)
            } else {
                Group {
                    if let error = thumbnails.errors[vm.id] {
                        Text(error).font(.caption)
                    } else {
                        ProgressView("Loading preview…").controlSize(.small).font(.caption)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(.quaternary, in: .rect(cornerRadius: 8))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { Task { await client.openScreenSharing(vm: vm) } }
        .help("Double-click to open Screen Sharing")
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
        if let details = client.details[vm.id] {
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
    var body: some View {
        let isReady = client.serviceReachable == true

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
        .help(isReady ? "Open Screen Sharing for \(vm.name)" : "Lume service unavailable")
        .accessibilityLabel("Open Screen Sharing for \(vm.name)")
    }
}
