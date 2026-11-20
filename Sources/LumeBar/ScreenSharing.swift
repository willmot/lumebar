import AppKit
import Foundation
import Network
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
        case .auto: "Automatic"
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
    let port: UInt16
    /// URL handed to the system (`vnc://…`). Never contains guest credentials.
    let openURL: URL
    let credential: VNCCredential?

    /// Guest Screen Sharing needs a login before we can grab a thumbnail.
    var canSnapshot: Bool { kind == .lumeVNC || credential != nil }

    static func resolve(vm: LumeVM,
                        details: LumeVMDetails?,
                        preference: ScreenSharingPreference,
                        guestLogin: GuestLogin?,
                        service: URL? = nil) -> ScreenSharingEndpoint? {
        var lume = lumeEndpoint(vncUrl: details?.vncUrl) ?? lumeEndpoint(vncUrl: vm.vncUrl)
        if let service, let host = lume?.host, isLoopback(host), !isLoopback(service.host() ?? "") {
            lume = nil
        }
        let guest = guestEndpoint(ip: guestAddress(for: vm, details: details), login: guestLogin)

        switch preference {
        case .auto:
            if vm.os?.lowercased() == "linux" { return lume }
            // A guest IP does not mean Screen Sharing is enabled. A saved guest login
            // indicates that the user intends to use the guest's own service.
            if guestLogin != nil, let guest { return guest }
            return lume ?? guest
        case .lumeVNC: return lume
        case .guest: return guest
        }
    }

    private static func isLoopback(_ host: String) -> Bool {
        let name = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return name == "localhost" || name == "::1" || (IPv4Address(name)?.rawValue.first == 127)
    }

    private static func lumeEndpoint(vncUrl: String?) -> ScreenSharingEndpoint? {
        guard let vncUrl, !vncUrl.isEmpty,
              let components = URLComponents(string: vncUrl),
              components.scheme?.lowercased() == "vnc",
              let host = components.url?.host(), !host.isEmpty,
              let port = UInt16(exactly: components.port ?? 5900), port > 0,
              let url = URL(string: vncUrl) else { return nil }

        var credential: VNCCredential?
        if let password = components.password, !password.isEmpty {
            if let user = components.user, !user.isEmpty {
                credential = VNCUsernamePasswordCredential(username: user, password: password)
            } else {
                credential = VNCPasswordCredential(password: password)
            }
        }
        return ScreenSharingEndpoint(kind: .lumeVNC, host: host, port: port,
                                     openURL: url, credential: credential)
    }

    static func guestAddress(for vm: LumeVM, details: LumeVMDetails?) -> String? {
        [details?.ipAddress, vm.ipAddress].compactMap { $0 }.first { !$0.isEmpty }
    }

    private static func guestEndpoint(ip: String?, login: GuestLogin?) -> ScreenSharingEndpoint? {
        guard let ip, IPv4Address(ip) != nil || IPv6Address(ip) != nil else { return nil }
        var components = URLComponents()
        components.scheme = "vnc"
        components.host = ip.contains(":") && !ip.hasPrefix("[") ? "[\(ip)]" : ip
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

    func preference(for vm: LumeVM, service: URL) -> ScreenSharingPreference {
        UserDefaults.standard.string(forKey: preferenceKey(for: vm, service: service))
            .flatMap(ScreenSharingPreference.init(rawValue:)) ?? .auto
    }

    func setPreference(_ preference: ScreenSharingPreference, for vm: LumeVM, service: URL) {
        UserDefaults.standard.set(preference.rawValue, forKey: preferenceKey(for: vm, service: service))
        revision += 1
    }

    func guestLogin(for vm: LumeVM, service: URL, address: String) -> GuestLogin? {
        var query = baseQuery(vm, service: service, address: address)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(GuestLogin.self, from: data)
    }

    private func setGuestLogin(_ login: GuestLogin?, for vm: LumeVM, service: URL, address: String) throws {
        var item = baseQuery(vm, service: service, address: address)
        let status: OSStatus
        if let login {
            let data = try JSONEncoder().encode(login)
            let update = SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if update == errSecItemNotFound {
                item[kSecValueData as String] = data
                status = SecItemAdd(item as CFDictionary, nil)
            } else {
                status = update
            }
        } else {
            let deletion = SecItemDelete(item as CFDictionary)
            status = deletion == errSecItemNotFound ? errSecSuccess : deletion
        }

        guard status == errSecSuccess else { throw KeychainError(status: status) }
        revision += 1
    }

    func endpoint(for vm: LumeVM, details: LumeVMDetails?, service: URL, loadLogin: Bool = true) -> ScreenSharingEndpoint? {
        let preference = preference(for: vm, service: service)
        let login: GuestLogin?
        if loadLogin, preference != .lumeVNC,
           preference == .guest || vm.os?.lowercased() != "linux",
           let address = ScreenSharingEndpoint.guestAddress(for: vm, details: details) {
            login = guestLogin(for: vm, service: service, address: address)
        } else {
            login = nil
        }
        return ScreenSharingEndpoint.resolve(vm: vm, details: details, preference: preference, guestLogin: login, service: service)
    }

    func promptForGuestLogin(vm: LumeVM, service: URL, address: String) {
        let existing = guestLogin(for: vm, service: service, address: address)

        let alert = NSAlert()
        alert.messageText = "Screen Sharing login for \(vm.name)"
        alert.informativeText = "LumeBar saves this login in Keychain for previews of this VM at \(address)."
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
        let response = alert.runModal()
        do {
            switch response {
            case .alertFirstButtonReturn:
                let name = user.stringValue.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !password.stringValue.isEmpty else {
                    let error = NSAlert()
                    error.messageText = "Enter a user name and password"
                    error.runModal()
                    return
                }
                try setGuestLogin(GuestLogin(username: name, password: password.stringValue), for: vm, service: service, address: address)
            case .alertThirdButtonReturn:
                try setGuestLogin(nil, for: vm, service: service, address: address)
            default:
                break
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    private func preferenceKey(for vm: LumeVM, service: URL) -> String {
        "lume.screenSharing.v2." + Self.scope(for: vm, service: service)
    }

    static func scope(for vm: LumeVM, service: URL, address: String? = nil) -> String {
        // Length-prefix the fields so distinct service, storage, VM and address tuples stay distinct.
        [service.absoluteString, vm.storage ?? "", vm.name, address == nil ? "" : vm.macAddress ?? "", address ?? ""]
            .map { "\($0.utf8.count):\($0)" }.joined()
    }

    private func baseQuery(_ vm: LumeVM, service url: URL, address: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: Self.scope(for: vm, service: url, address: address)]
    }
}

private struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        "Could not save the Screen Sharing login."
    }

    var failureReason: String? {
        SecCopyErrorMessageString(status, nil) as String?
    }
}
