import SwiftUI

struct SettingsView: View {
    @ObservedObject var client: LumeClient
    @Binding var baseURL: String
    @Binding var noDisplay: Bool
    @Binding var vncDisabled: Bool

    static let defaultBaseURL = "http://localhost:7777"

    var body: some View {
        Form {
            Section("Lume Service") {
                TextField("Service URL", text: $baseURL)
                    .multilineTextAlignment(.trailing)

                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Test Connection") {
                        client.updateBaseURL(baseURL)
                        Task { await client.fetchVms() }
                    }
                    if baseURL != Self.defaultBaseURL {
                        Button("Reset to Default") {
                            baseURL = Self.defaultBaseURL
                        }
                    }
                }
            }

            Section("Virtual Machines") {
                Toggle(isOn: $noDisplay) {
                    Text("Start VMs headless")
                    Text("No display window opens. Use Screen Sharing from the menu to see the VM. Without Lume VNC, enable Screen Sharing in the guest (System Settings › General › Sharing).")
                }
            }

Section {
                Toggle(isOn: $vncDisabled) {
                    Text("Start VMs without VNC (--vnc disabled)")
                    Text("Recommended on macOS 27.0: the Lume VNC server can crash the VM at start. Also closes the VNC port on the network. Use guest Screen Sharing instead.")
                }
            }

            Section("Lume CLI") {
                LabeledContent("Location") {
                    if let path = client.lumeExecutablePath {
                        Label {
                            Text(abbreviatedPath(path))
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    } else {
                        Label {
                            Text("Not found")
                        } icon: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }
                if client.lumeExecutablePath == nil {
                    Link("Install Lume", destination: URL(string: "https://cua.ai/docs/lume/guide/getting-started/quickstart")!)
                }
            }

            Section {
                HStack {
                    Text("LumeBar \(appVersion)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Link("Lume documentation", destination: URL(string: "https://cua.ai/docs/lume/guide/getting-started/quickstart")!)
                }
                .font(.footnote)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onChange(of: baseURL) {
            client.updateBaseURL(baseURL)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var statusColor: Color {
        switch client.serviceReachable {
        case .some(true): .green
        case .some(false): .red
        case .none: .secondary
        }
    }

    private var statusText: String {
        switch client.serviceReachable {
        case .some(true):
            let count = client.vms.count
            return "Connected · \(count == 1 ? "1 VM" : "\(count) VMs")"
        case .some(false):
            return "Not reachable"
        case .none:
            return "Not checked yet"
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        if let build = info?["CFBundleVersion"] as? String {
            return "\(version) (\(build))"
        }
        return version
    }

    private func abbreviatedPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
