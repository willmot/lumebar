import AppKit
import SwiftUI

@main
struct LumeBarApp: App {
    @AppStorage("lume.baseURL") private var baseURL = LumeClient.defaultService
    @AppStorage("lume.noDisplay") private var noDisplay = true
    // macOS 27.0 crashes `lume run` in the VNC server setup, so VNC stays off unless switched on.
    @AppStorage("lume.vncDisabled") private var vncDisabled = true
    @StateObject private var client: LumeClient
    @StateObject private var thumbnails = VNCThumbnailStore()

    init() {
        let service = UserDefaults.standard.string(forKey: "lume.baseURL") ?? LumeClient.defaultService
        _client = StateObject(wrappedValue: LumeClient(service: service))
        // Run as a menu bar only app (no Dock icon).
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    private var menuBarStatusImage: NSImage {
        if let image = Bundle.module.image(forResource: "MenubarIcon") {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            return image
        }

        let fallback = NSImage(
            systemSymbolName: "play.rectangle.on.rectangle",
            accessibilityDescription: "Lume"
        ) ?? NSImage()
        fallback.size = NSSize(width: 18, height: 18)
        fallback.isTemplate = true
        return fallback
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(client: client, thumbnails: thumbnails, noDisplay: $noDisplay, vncDisabled: $vncDisabled)
                .frame(width: 440)
                .onAppear {
                    client.updateBaseURL(baseURL)
                    client.willOpenLumeVNC = { [thumbnails] id in thumbnails.releaseForScreenSharing(vm: id) }
                }
                .onChange(of: baseURL) {
                    client.updateBaseURL(baseURL)
                }
        } label: {
            Label {
                Text("Lume")
            } icon: {
                Image(nsImage: menuBarStatusImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(client: client, baseURL: $baseURL, noDisplay: $noDisplay, vncDisabled: $vncDisabled)
        }
    }
}
