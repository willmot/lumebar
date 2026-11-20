import SwiftUI

enum VMStartMode: String, CaseIterable, Identifiable {
    case guestSharing
    case headless
    case display

    var id: Self { self }
    var title: String {
        switch self {
        case .guestSharing: "Headless without Lume VNC"
        case .headless: "Headless with Lume VNC"
        case .display: "With display"
        }
    }

    static func selection(noDisplay: Binding<Bool>, vncDisabled: Binding<Bool>) -> Binding<Self> {
        Binding(
            get: { vncDisabled.wrappedValue ? .guestSharing : (noDisplay.wrappedValue ? .headless : .display) },
            set: {
                noDisplay.wrappedValue = $0 != .display
                vncDisabled.wrappedValue = $0 == .guestSharing
            }
        )
    }
}

struct SettingsView: View {
    @ObservedObject var client: LumeClient
    @Binding var baseURL: String
    @Binding var noDisplay: Bool
    @Binding var vncDisabled: Bool

    @State private var draftURL = ""
    private let lumeDocs = URL(string: "https://cua.ai/docs/lume")!

    var body: some View {
        Form {
            Section("Lume Service") {
                TextField("Service URL", text: $draftURL)
                    .multilineTextAlignment(.trailing)
                    .onSubmit(saveAndTest)

                HStack {
                    Text(connectionStatus)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to Default") {
                        draftURL = LumeClient.defaultService
                        saveAndTest()
                    }
                    .disabled(draftURL == LumeClient.defaultService && baseURL == LumeClient.defaultService)
                    Button(draftURL == baseURL ? "Test Connection" : "Save and Test", action: saveAndTest)
                        .disabled(LumeClient.serviceURL(draftURL) == nil || (draftURL == baseURL && client.isLoading))
                }
                if let connectionHint {
                    Text(connectionHint)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Virtual Machines") {
                Picker("Start VMs", selection: VMStartMode.selection(noDisplay: $noDisplay, vncDisabled: $vncDisabled)) {
                    ForEach(VMStartMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                if vncDisabled {
                    Text("Enable Screen Sharing inside the guest to connect from LumeBar.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Local Lume CLI") {
                    if let path = LumeClient.findLumeExecutableURL()?.path {
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .textSelection(.enabled)
                    } else {
                        Text("Not found").foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("LumeBar \(appVersion)").foregroundStyle(.secondary)
                    Spacer()
                    Link("Lume documentation", destination: lumeDocs)
                }
                .font(.footnote)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear { draftURL = baseURL }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func saveAndTest() {
        guard let url = LumeClient.serviceURL(draftURL) else { return }
        draftURL = url.absoluteString
        baseURL = draftURL
        client.updateBaseURL(draftURL)
        Task { await client.fetchVms(startLocalService: true) }
    }

    private var connectionStatus: String {
        if LumeClient.serviceURL(draftURL) == nil { return "Invalid URL" }
        if draftURL != baseURL { return "Unsaved changes" }
        if client.isLoading { return "Connecting…" }
        switch client.serviceReachable {
        case true?: return "Connected"
        case false?: return "Connection failed"
        case nil: return "Ready to test"
        }
    }

    private var connectionHint: String? {
        if LumeClient.serviceURL(draftURL) == nil { return "Enter an HTTP or HTTPS URL." }
        guard draftURL == baseURL, !client.isLoading, client.serviceReachable == false else { return nil }
        return client.serviceError
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else { return "dev" }
        guard let build = info?["CFBundleVersion"] as? String else { return version }
        return "\(version) (\(build))"
    }
}
