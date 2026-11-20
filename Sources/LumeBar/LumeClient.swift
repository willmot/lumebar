import AppKit
import Foundation

struct LumeVM: Codable, Identifiable {
    let name: String
    let state: String?
    let status: String?
    let os: String?
    let cpuCount: Int?
    let memorySize: Int64?
    let diskSize: DiskSize?
    let display: String?
    let ipAddress: String?
    let vncUrl: String?
    let provisioningOperation: String?
    let locationName: String?
    let macAddress: String?

    var storage: String? { locationName }

    struct ID: Hashable {
        let name: String
        let storage: String?
    }

    var id: ID { ID(name: name, storage: storage) }

    var isRunning: Bool {
        (status ?? state)?.lowercased() == "running"
    }

    var isProvisioning: Bool {
        ["provisioning", "pulling"].contains((status ?? state)?.lowercased() ?? "")
    }

    var sortRank: Int {
        if isRunning { return 0 }
        if isProvisioning { return 1 }
        return 2
    }

    var provisioningDescription: String {
        switch provisioningOperation?.lowercased() {
        case "ipsw_install": return "Installing macOS…"
        case "pull": return "Downloading image…"
        case _ where (status ?? state)?.lowercased() == "pulling": return "Downloading image…"
        default: return "Provisioning…"
        }
    }

    var stateDescription: String {
        (status ?? state)?.capitalized ?? "Unknown"
    }
}

struct LumeVMDetails: Decodable {
    let name: String?
    let status: String?
    let state: String?
    let ipAddress: String?
    let cpuCount: Int?
    let memorySize: Int64?
    let diskSize: DiskSize?
    let os: String?
    let display: String?
    let storage: String?
    let createdAt: String?
    let vncUrl: String?

    var stateDescription: String {
        (status ?? state)?.capitalized ?? "Unknown"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        func decodeString(_ keys: [CodingKeys]) -> String? {
            for key in keys {
                if let value = try? container.decode(String.self, forKey: key) {
                    return value
                }
            }
            return nil
        }

        name = decodeString([.name])
        status = decodeString([.status])
        state = decodeString([.state])
        ipAddress = decodeString([.ipAddress, .ip, .address])
        cpuCount = container.decodeInt(for: [.cpuCount, .cpu])
        memorySize = container.decodeInt64(for: [.memorySize, .memory])
        diskSize = container.decodeDiskSize(for: [.diskSize, .disk])
        os = decodeString([.os])
        display = decodeString([.display, .displaySize])
        storage = decodeString([.locationName, .storage])
        createdAt = decodeString([.createdAt, .created])
        vncUrl = decodeString([.vncUrl, .vnc])
    }

    enum CodingKeys: String, CodingKey {
        case name
        case status
        case state
        case ip
        case ipAddress
        case address
        case cpu
        case cpuCount
        case memory
        case memorySize
        case diskSize
        case disk
        case os
        case display
        case displaySize
        case storage
        case locationName
        case createdAt
        case created
        case vncUrl
        case vnc
    }
}

struct DiskSize: Codable {
    let total: Int64?
    let allocated: Int64?
}

@MainActor
final class LumeClient: ObservableObject {
    static let defaultService = "http://localhost:7777"

    @Published private(set) var vms: [LumeVM] = []
    @Published private(set) var isLoading = false
    @Published private(set) var serviceError: String?
    @Published private(set) var actionError: String?
    @Published private(set) var serviceReachable: Bool?
    @Published private(set) var details: [LumeVM.ID: LumeVMDetails] = [:]
    @Published private(set) var detailsError: [LumeVM.ID: String] = [:]
    @Published private(set) var vmActionsInFlight: Set<LumeVM.ID> = []
    @Published private(set) var serviceRevision = UUID()

    var willOpenLumeVNC: ((LumeVM.ID) -> Void)?
    private(set) var baseURL: URL?
    private let session: URLSession
    private var detailsRequests: [LumeVM.ID: UUID] = [:]
    private var detailsUpdatedAt: [LumeVM.ID: ContinuousClock.Instant] = [:]
    private var lastScreenSharingOpen: [LumeVM.ID: ContinuousClock.Instant] = [:]
    private var serverProcess: Process?
    private let clock = ContinuousClock()

    init(service: String = LumeClient.defaultService, session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 120
        self.session = session ?? URLSession(configuration: configuration, delegate: LumeRedirectPolicy(), delegateQueue: nil)
        baseURL = Self.serviceURL(service)
    }

    static func serviceURL(_ value: String) -> URL? {
        guard var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              (1...65535).contains(components.port ?? 7777) else { return nil }
        components.scheme = scheme
        components.host = host
        if components.port == (scheme == "https" ? 443 : 80) { components.port = nil }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        return components.url
    }

    var serviceAddress: String {
        guard let baseURL, let host = baseURL.host() else { return "Service URL" }
        return baseURL.port.map { "\(host):\($0)" } ?? host
    }

    var isConfigured: Bool { baseURL != nil }

    func updateBaseURL(_ value: String) {
        let url = Self.serviceURL(value)
        guard url != baseURL else { return }
        baseURL = url
        serviceRevision = UUID()
        serviceReachable = nil
        serviceError = nil
        actionError = nil
        isLoading = false
        vms = []
        details = [:]
        detailsError = [:]
        detailsRequests = [:]
        detailsUpdatedAt = [:]
        vmActionsInFlight = []
        lastScreenSharingOpen = [:]
    }

    func fetchVms(startLocalService: Bool = false) async {
        guard !isLoading else { return }
        guard let url = baseURL else {
            serviceError = "Enter a valid HTTP or HTTPS service URL in Settings."
            serviceReachable = false
            return
        }
        let revision = serviceRevision
        isLoading = true
        defer {
            if serviceRevision == revision { isLoading = false }
        }

        do {
            let loaded: [LumeVM]
            do {
                loaded = try await request(at: url)
            } catch let error as URLError where error.code == .cannotConnectToHost && startLocalService && url.absoluteString == Self.defaultService {
                try Task.checkCancellation()
                guard serviceRevision == revision else { return }
                startServerIfNeeded()
                try await Task.sleep(for: .seconds(1))
                loaded = try await request(at: url)
            }
            try Task.checkCancellation()
            guard serviceRevision == revision else { return }
            let oldVMs = Dictionary(vms.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let uniqueVMs = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for (id, vm) in oldVMs {
                let replacement = uniqueVMs[id]
                if replacement?.stateDescription != vm.stateDescription
                    || replacement?.macAddress != vm.macAddress
                    || replacement?.ipAddress != vm.ipAddress || replacement?.vncUrl != vm.vncUrl {
                    details[id] = nil
                    detailsUpdatedAt[id] = nil
                    detailsRequests[id] = nil
                    detailsError[id] = nil
                }
                if replacement == nil { lastScreenSharingOpen[id] = nil }
            }
            vms = uniqueVMs.values.sorted {
                if $0.sortRank != $1.sortRank { return $0.sortRank < $1.sortRank }
                let nameOrder = $0.name.localizedStandardCompare($1.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                if $0.name != $1.name { return $0.name < $1.name }
                return ($0.storage ?? "") < ($1.storage ?? "")
            }
            serviceReachable = true
            serviceError = nil
        } catch {
            guard serviceRevision == revision, !Task.isCancelled else { return }
            serviceReachable = false
            serviceError = message(for: error)
        }
    }

    func fetchDetails(for vm: LumeVM) async {
        let id = vm.id
        guard let url = baseURL, vms.contains(where: { $0.id == id }), detailsRequests[id] == nil else { return }
        if let updated = detailsUpdatedAt[id], updated.duration(to: clock.now) < .seconds(15) { return }

        let requestID = UUID()
        detailsRequests[id] = requestID
        detailsError[id] = nil
        defer {
            if detailsRequests[id] == requestID { detailsRequests[id] = nil }
        }

        do {
            let result: LumeVMDetails = try await request(at: url, vm: id)
            try Task.checkCancellation()
            guard detailsRequests[id] == requestID else { return }
            details[id] = result
            detailsUpdatedAt[id] = clock.now
        } catch {
            guard detailsRequests[id] == requestID, !Task.isCancelled else { return }
            detailsError[id] = message(for: error)
        }
    }

    func run(vm: LumeVM, noDisplay: Bool, vncDisabled: Bool) async {
        await performAction(vm, action: "run", body: [
            "noDisplay": noDisplay || vncDisabled,
            "vnc": vncDisabled ? "disabled" : "enabled"
        ])
    }

    func stop(vm: LumeVM) async {
        await performAction(vm, action: "stop", body: [:])
    }

    func dismissActionError() {
        actionError = nil
    }

    private func performAction(_ vm: LumeVM, action: String, body: [String: any Sendable]) async {
        guard let url = baseURL, serviceReachable == true,
              let currentVM = vms.first(where: { $0.id == vm.id }),
              action == "stop" ? currentVM.isRunning : (!currentVM.isRunning && !currentVM.isProvisioning),
              vmActionsInFlight.insert(vm.id).inserted else { return }

        let revision = serviceRevision
        defer {
            if revision == serviceRevision { vmActionsInFlight.remove(vm.id) }
        }
        actionError = nil

        do {
            if body["vnc"] as? String == "disabled" {
                try await verifyDisabledVNCSupport(at: url)
                guard revision == serviceRevision, serviceReachable == true,
                      vms.contains(where: { $0.id == vm.id && !$0.isRunning && !$0.isProvisioning }) else { return }
            }
            let request = try Self.makeRequest(at: url, vm: vm.id, action: action, body: body)
            let (_, response) = try await session.data(for: request)
            try Self.validate(response)
            guard revision == serviceRevision else { return }
            if action == "run" {
                let deadline = clock.now.advanced(by: .seconds(45))
                repeat {
                    await fetchVms()
                    guard revision == serviceRevision else { return }
                    if vms.contains(where: { $0.id == vm.id && $0.isRunning }) { return }
                    try await Task.sleep(for: .seconds(1))
                } while clock.now < deadline
                throw LumeError.runTimedOut
            }
            await fetchVms()
        } catch {
            guard revision == serviceRevision, !Task.isCancelled else { return }
            actionError = "\(vm.name) · \(message(for: error))"
        }
    }

    private func verifyDisabledVNCSupport(at url: URL) async throws {
        struct HostStatus: Decodable { let version: String }

        do {
            let request = URLRequest(url: url.appending(path: "lume/host/status"),
                                     cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
            let (data, response) = try await session.data(for: request)
            try Self.validate(response)
            let host = try JSONDecoder().decode(HostStatus.self, from: data)
            // Older servers silently ignore the unknown vnc field and start a listener.
            let parts = host.version.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count >= 3, let major = Int(parts[0]), let minor = Int(parts[1]),
                  major > 0 || (major == 0 && minor >= 6) else { throw LumeError.vncPolicyUnavailable }
        } catch {
            try Task.checkCancellation()
            throw LumeError.vncPolicyUnavailable
        }
    }

    func openScreenSharing(vm: LumeVM) async {
        guard let url = baseURL, serviceReachable == true,
              vms.contains(where: { $0.id == vm.id && $0.isRunning }) else { return }
        let now = clock.now
        if let last = lastScreenSharingOpen[vm.id], last.duration(to: now) < .seconds(3) { return }
        lastScreenSharingOpen[vm.id] = now
        let revision = serviceRevision

        let sharing = ScreenSharingSettings.shared
        if sharing.endpoint(for: vm, details: details[vm.id], service: url, loadLogin: false) == nil {
            await fetchDetails(for: vm)
        }
        guard revision == serviceRevision, serviceReachable == true,
              let current = vms.first(where: { $0.id == vm.id && $0.isRunning }) else { return }
        guard let endpoint = sharing.endpoint(for: current, details: details[vm.id], service: url) else {
            actionError = "No Screen Sharing address is available for \(vm.name)."
            return
        }
        if endpoint.kind == .lumeVNC {
            willOpenLumeVNC?(vm.id)
            // Give Lume's VNC server time to release the thumbnail client.
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
        guard revision == serviceRevision, serviceReachable == true,
              vms.contains(where: { $0.id == vm.id && $0.isRunning }) else { return }
        if !NSWorkspace.shared.open(endpoint.openURL) {
            actionError = "Could not open Screen Sharing for \(vm.name)."
        }
    }

    private func request<T: Decodable>(at url: URL, vm: LumeVM.ID? = nil) async throws -> T {
        let request = try Self.makeRequest(at: url, vm: vm)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    static func makeRequest(at base: URL, vm: LumeVM.ID? = nil, action: String? = nil,
                            body: [String: any Sendable] = [:]) throws -> URLRequest {
        let list = base.appending(path: "lume/vms")
        var url = list
        if let vm {
            // Encode the VM name as one path segment, including slashes and percent signs.
            guard !vm.name.isEmpty, vm.name != ".", vm.name != "..",
                  let name = vm.name.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/;%"))) else {
                throw LumeError.invalidVMName
            }
            guard let vmURL = URL(string: list.absoluteString + "/" + name) else { throw LumeError.invalidVMName }
            url = vmURL
            if let action { url.append(component: action) }
            if action == nil, let storage = vm.storage { url.append(queryItems: [URLQueryItem(name: "storage", value: storage)]) }
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: action == "stop" ? 115 : 5)
        if action != nil {
            var payload = body
            payload["storage"] = vm?.storage
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        }
        return request
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw LumeError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw LumeError.httpError(http.statusCode) }
    }

    private func startServerIfNeeded() {
        guard serverProcess?.isRunning != true, let executable = Self.findLumeExecutableURL() else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            serverProcess = process
        } catch {
            // The follow-up request reports whether the service became available.
        }
    }

    static func findLumeExecutableURL() -> URL? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let directories = paths + [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        return directories.lazy.filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0).appending(component: "lume") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func message(for error: Error) -> String {
        switch error {
        case LumeError.invalidResponse: "The Lume service returned an unexpected response."
        case LumeError.invalidVMName: "This VM has an invalid name."
        case LumeError.httpError(409): "The Lume service reported a conflict. Check the host's VM limit and try again."
        case LumeError.httpError(let status): "The Lume service returned HTTP \(status)."
        case LumeError.vncPolicyUnavailable: "Could not verify support for VNC-disabled starts. Check the connection and use Lume 0.6.0 or later."
        case LumeError.runTimedOut: "The VM did not reach running state within 45 seconds. Refresh to check its current status."
        case is DecodingError: "The response could not be read. Check that the URL points to a compatible Lume service."
        case is URLError: "Check the service URL and confirm that the Lume service is running."
        default: "The Lume request failed."
        }
    }
}

private final class LumeRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // VM actions and connection settings belong to the configured service.
        completionHandler(nil)
    }
}

private enum LumeError: Error {
    case invalidResponse
    case invalidVMName
    case httpError(Int)
    case runTimedOut
    case vncPolicyUnavailable
}

private extension KeyedDecodingContainer where Key == LumeVMDetails.CodingKeys {
    func decodeInt(for keys: [Key]) -> Int? {
        for key in keys {
            if let value = try? decode(Int.self, forKey: key) {
                return value
            }
            if let value = try? decode(String.self, forKey: key), let intValue = Int(value) {
                return intValue
            }
        }
        return nil
    }

    func decodeInt64(for keys: [Key]) -> Int64? {
        for key in keys {
            if let value = try? decode(Int64.self, forKey: key) {
                return value
            }
            if let value = try? decode(Int.self, forKey: key) {
                return Int64(value)
            }
            if let value = try? decode(String.self, forKey: key), let intValue = Int64(value) {
                return intValue
            }
        }
        return nil
    }

    func decodeDiskSize(for keys: [Key]) -> DiskSize? {
        for key in keys {
            if let value = try? decode(DiskSize.self, forKey: key) {
                return value
            }
        }
        return nil
    }
}
