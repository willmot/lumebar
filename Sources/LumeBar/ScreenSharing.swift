import AppKit
import Foundation
import RoyalVNCKit
import Security

/// Which remote display to use for a VM.
enum ScreenSharingPreference: String, CaseIterable, Identifiable {
    case auto
    case lumeVNC
    case guest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Automatic (guest first)"
        case .lumeVNC: "Lume VNC"
        case .guest: "macOS Screen Sharing"
        }
    }
}

/// A resolved way to reach a VM's screen.
struct ScreenSharingEndpoint {
    enum Kind { case lumeVNC, guest }

    let kind: Kind
    let host: String
    let port: Int
    /// URL handed to the system (`vnc://…`). Never contains guest credentials.
    let openURL: URL
    let credential: VNCCredential?

    /// Stable identity used to decide whether a thumbnail needs reconnecting.
    var key: String { "\(kind)-\(host):\(port)-\(credential != nil)" }

    /// Guest Screen Sharing needs a login before we can grab a thumbnail.
    var canSnapshot: Bool { credential != nil }

    static func resolve(vm: LumeVM,
                        details: LumeVMDetails?,
                        preference: ScreenSharingPreference,
                        guestLogin: GuestLogin?) -> ScreenSharingEndpoint? {
        let lume = lumeEndpoint(vncUrl: details?.vncUrl ?? vm.vncUrl)
        let guest = guestEndpoint(ip: details?.ipAddress ?? vm.ipAddress, login: guestLogin)

        switch preference {
        // Lume's built-in VNC server (Virtualization.framework `_VZVNCServer`) can hit an assertion and take the
        // whole VM process down when a client connects. Prefer the guest's own Screen Sharing when reachable.
        case .auto: return guest ?? lume
        case .lumeVNC: return lume
        case .guest: return guest
        }
    }

    private static func lumeEndpoint(vncUrl: String?) -> ScreenSharingEndpoint? {
        guard let vncUrl, !vncUrl.isEmpty,
              let components = URLComponents(string: vncUrl),
              components.scheme?.lowercased() == "vnc",
              let host = components.host,
              let url = URL(string: vncUrl) else { return nil }

        var credential: VNCCredential?
        if let password = components.password, !password.isEmpty {
            if let user = components.user, !user.isEmpty {
                credential = VNCUsernamePasswordCredential(username: user, password: password)
            } else {
                credential = VNCPasswordCredential(password: password)
            }
        }
        return ScreenSharingEndpoint(kind: .lumeVNC, host: host, port: components.port ?? 5900,
                                     openURL: url, credential: credential)
    }

    private static func guestEndpoint(ip: String?, login: GuestLogin?) -> ScreenSharingEndpoint? {
        guard let ip, !ip.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "vnc"
        components.host = ip
        components.port = 5900
        // Pre-fill the user name only; the password stays in the Keychain.
        components.user = login?.username
        guard let url = components.url else { return nil }

        let credential = login.map {
            VNCUsernamePasswordCredential(username: $0.username, password: $0.password) as VNCCredential
        }
        return ScreenSharingEndpoint(kind: .guest, host: ip, port: 5900, openURL: url, credential: credential)
    }
}

struct GuestLogin: Codable, Equatable {
    var username: String
    var password: String
}

/// Per-VM screen sharing preference and guest login (Keychain). Bumps `revision` on change so views refresh.
@MainActor
final class ScreenSharingSettings: ObservableObject {
    static let shared = ScreenSharingSettings()

    @Published private(set) var revision = 0

    private let service = "com.lume.LumeBar.screensharing"

    func preference(for vmName: String) -> ScreenSharingPreference {
        UserDefaults.standard.string(forKey: prefKey(vmName))
            .flatMap(ScreenSharingPreference.init(rawValue:)) ?? .auto
    }

    func setPreference(_ preference: ScreenSharingPreference, for vmName: String) {
        if preference == .auto {
            UserDefaults.standard.removeObject(forKey: prefKey(vmName))
        } else {
            UserDefaults.standard.set(preference.rawValue, forKey: prefKey(vmName))
        }
        revision += 1
    }

    func guestLogin(for vmName: String) -> GuestLogin? {
        var query = baseQuery(vmName)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(GuestLogin.self, from: data)
    }

    func setGuestLogin(_ login: GuestLogin?, for vmName: String) {
        SecItemDelete(baseQuery(vmName) as CFDictionary)
        if let login, let data = try? JSONEncoder().encode(login) {
            var item = baseQuery(vmName)
            item[kSecValueData as String] = data
            SecItemAdd(item as CFDictionary, nil)
        }
        revision += 1
    }

    func endpoint(for vm: LumeVM, details: LumeVMDetails?) -> ScreenSharingEndpoint? {
        ScreenSharingEndpoint.resolve(vm: vm,
                                      details: details,
                                      preference: preference(for: vm.name),
                                      guestLogin: guestLogin(for: vm.name))
    }

    /// Asks for the guest's Screen Sharing login with a small modal prompt.
    func promptForGuestLogin(vmName: String) {
        let existing = guestLogin(for: vmName)

        let alert = NSAlert()
        alert.messageText = "Screen Sharing login for \(vmName)"
        alert.informativeText = "Used for the live thumbnail and pre-filled when opening macOS Screen Sharing. The password is stored in your Keychain."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if existing != nil { alert.addButton(withTitle: "Remove") }

        let user = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        user.placeholderString = "User name"
        user.stringValue = existing?.username ?? "lume"
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        password.placeholderString = "Password"
        password.stringValue = existing?.password ?? ""
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        container.addSubview(user)
        container.addSubview(password)
        alert.accessoryView = container
        alert.window.initialFirstResponder = password

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let name = user.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !password.stringValue.isEmpty else { return }
            setGuestLogin(GuestLogin(username: name, password: password.stringValue), for: vmName)
        case .alertThirdButtonReturn:
            setGuestLogin(nil, for: vmName)
        default:
            break
        }
    }

    private func prefKey(_ vmName: String) -> String { "lume.screenSharing.\(vmName)" }

    private func baseQuery(_ vmName: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: vmName]
    }
}
