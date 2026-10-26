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

    var id: String { name }

    var isRunning: Bool {
        (status ?? state)?.lowercased() == "running"
    }

    var isProvisioning: Bool {
        (status ?? state)?.lowercased() == "provisioning"
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
        storage = decodeString([.storage])
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
    @Published private(set) var vms: [LumeVM] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var details: [String: LumeVMDetails] = [:]
    @Published private(set) var detailsLoading: Set<String> = []
    @Published private(set) var detailsError: [String: String] = [:]
    @Published private(set) var vmActionsInFlight: Set<String> = []
    @Published private(set) var serviceReachable: Bool?

    /// Called before a Lume VNC connection is opened so other VNC clients (thumbnails) can release the server first.
    var willOpenLumeVNC: ((String) -> Void)?
    private var lastScreenSharingOpen: [String: Date] = [:]
    private let screenSharingCooldown: TimeInterval = 3
    private var baseURL = URL(string: "http://localhost:7777")!
    private var didAttemptStartServer = false
    private var serverProcess: Process?
    private var serverOutputPipe: Pipe?
    private var serverErrorPipe: Pipe?
    private var detailsUpdatedAt: [String: Date] = [:]
    private var lastStates: [String: String] = [:]
    private let detailsTTL: TimeInterval = 15
    private let startVerificationTimeout: TimeInterval = 45
    private let startVerificationPollInterval: TimeInterval = 1.5
    private let detachedRunLogPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("lumebar-lume-run.log")
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    var serviceAddress: String {
        guard let host = baseURL.host else { return baseURL.absoluteString }
        if let port = baseURL.port { return "\(host):\(port)" }
        return host
    }

    var lumeExecutablePath: String? {
        findLumeExecutableURL()?.path
    }

    func updateBaseURL(_ value: String) {
        guard let url = URL(string: value), url != baseURL else { return }
        baseURL = url
        serviceReachable = nil
    }

    func fetchVms() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let decoded = try await withServerRetry { try await self.loadVMs() }
            // Running VMs first, then ones being provisioned, then the rest; by name within each group.
            let sorted = decoded.sorted {
                if $0.sortRank != $1.sortRank { return $0.sortRank < $1.sortRank }
                return $0.name.lowercased() < $1.name.lowercased()
            }
            vms = sorted
            serviceReachable = true
            pruneDetailsCache(with: sorted)
        } catch {
            serviceReachable = false
            errorMessage = errorMessage(from: error)
        }
    }

    func fetchDetails(for vm: LumeVM) async {
        let name = vm.name
        if let lastUpdate = detailsUpdatedAt[name],
           Date().timeIntervalSince(lastUpdate) < detailsTTL {
            return
        }
        if detailsLoading.contains(name) { return }
        detailsLoading.insert(name)
        detailsError[name] = nil
        defer { detailsLoading.remove(name) }

        do {
            let decoded = try await withServerRetry { try await self.loadDetails(for: name) }
            details[name] = decoded
            detailsUpdatedAt[name] = Date()
        } catch {
            detailsError[name] = errorMessage(from: error)
        }
    }

    func run(vm: LumeVM, noDisplay: Bool, vncDisabled: Bool) async {
        guard !vmActionsInFlight.contains(vm.name) else { return }
        vmActionsInFlight.insert(vm.name)
        defer { vmActionsInFlight.remove(vm.name) }

        do {
            var arguments = ["run", vm.name]
            if noDisplay {
                arguments.append("--no-display")
            }
            if vncDisabled {
                arguments.append(contentsOf: ["--vnc", "disabled"])
            }
            try await runCLIInBackground(arguments: arguments)
            let isRunning = try await waitForRunningState(vmName: vm.name, timeout: startVerificationTimeout)
            guard isRunning else {
                throw LumeError.cliStartVerificationFailed(detachedRunLogPath)
            }
            await fetchVms()
        } catch {
            errorMessage = errorMessage(from: error)
        }
    }

    func stop(vm: LumeVM) async {
        guard !vmActionsInFlight.contains(vm.name) else { return }
        vmActionsInFlight.insert(vm.name)
        defer { vmActionsInFlight.remove(vm.name) }

        do {
            try await runCLI(arguments: ["stop", vm.name])
            await fetchVms()
        } catch {
            errorMessage = errorMessage(from: error)
        }
    }

    func isActionInFlight(vmName: String) -> Bool {
        vmActionsInFlight.contains(vmName)
    }

    func openScreenSharing(vm: LumeVM) async {
        // Ignore repeated clicks: concurrent VNC handshakes can crash Lume's VNC server (and the VM with it).
        let now = Date()
        if let last = lastScreenSharingOpen[vm.name], now.timeIntervalSince(last) < screenSharingCooldown { return }
        lastScreenSharingOpen[vm.name] = now

        if details[vm.name]?.ipAddress == nil && details[vm.name]?.vncUrl == nil {
            await fetchDetails(for: vm)
        }

        let settings = ScreenSharingSettings.shared
        if let endpoint = settings.endpoint(for: vm, details: details[vm.name]) {
            if endpoint.kind == .lumeVNC {
                // Drop our own thumbnail connection and let the server settle before a second client attaches.
                willOpenLumeVNC?(vm.name)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            NSWorkspace.shared.open(endpoint.openURL)
            return
        }

        switch ScreenSharingSettings.shared.preference(for: vm.name) {
        case .lumeVNC:
            errorMessage = "\(vm.name) has no Lume VNC server (started with --vnc disabled?). Switch it to macOS Screen Sharing."
        case .guest:
            errorMessage = "No IP address yet for \(vm.name)."
        case .auto:
            errorMessage = "No VNC URL or IP available for \(vm.name)."
        }
    }

    private func loadVMs() async throws -> [LumeVM] {
        let url = baseURL.appendingPathComponent("lume/vms")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response)
        return try decoder.decode([LumeVM].self, from: data)
    }

    private func loadDetails(for name: String) async throws -> LumeVMDetails {
        let path = "lume/vms/\(escaped(name))"
        let url = baseURL.appendingPathComponent(path)
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response)
        return try decoder.decode(LumeVMDetails.self, from: data)
    }

    private func withServerRetry<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            if shouldAttemptStartServer(error: error) {
                await startServerIfNeeded()
                return try await operation()
            }
            throw error
        }
    }

    private func escaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LumeError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw LumeError.httpError(http.statusCode)
        }
    }

    private func shouldAttemptStartServer(error: Error) -> Bool {
        guard !didAttemptStartServer else { return false }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost,
                 .networkConnectionLost,
                 .notConnectedToInternet,
                 .cannotFindHost,
                 .timedOut:
                return true
            default:
                return false
            }
        }
        return false
    }

    private func startServerIfNeeded() async {
        guard !didAttemptStartServer else { return }
        didAttemptStartServer = true
        if let serverProcess, serverProcess.isRunning { return }
        guard let executableURL = findLumeExecutableURL() else { return }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["serve"]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return
        }

        serverProcess = process
        serverOutputPipe = outputPipe
        serverErrorPipe = errorPipe
        consume(pipe: outputPipe)
        consume(pipe: errorPipe)

        try? await Task.sleep(nanoseconds: 1_500_000_000)
    }

    private func errorMessage(from error: Error) -> String {
        if let lumeError = error as? LumeError {
            return lumeError.message
        }
        return "Lume API not reachable. Make sure the Lume service is running."
    }

    private func runCLI(arguments: [String]) async throws {
        let executableURL = try requiredLumeExecutableURL()
        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CLIResult, Error>) in
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            process.terminationHandler = { process in
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: outputData, encoding: .utf8) ?? ""
                let stderr = String(data: errorData, encoding: .utf8) ?? ""
                continuation.resume(returning: CLIResult(status: process.terminationStatus,
                                                         stdout: stdout,
                                                         stderr: stderr))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: LumeError.cliLaunchFailed)
            }
        }

        guard result.status == 0 else {
            throw LumeError.cliCommandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    private func runCLIInBackground(arguments: [String]) async throws {
        let executablePath = try requiredLumeExecutableURL().path
        let command = "nohup \(shellQuote(executablePath)) \(arguments.map(shellQuote).joined(separator: " ")) >\(shellQuote(detachedRunLogPath)) 2>&1 &"

        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CLIResult, Error>) in
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            process.terminationHandler = { process in
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: outputData, encoding: .utf8) ?? ""
                let stderr = String(data: errorData, encoding: .utf8) ?? ""
                continuation.resume(returning: CLIResult(status: process.terminationStatus,
                                                         stdout: stdout,
                                                         stderr: stderr))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: LumeError.cliLaunchFailed)
            }
        }

        guard result.status == 0 else {
            throw LumeError.cliCommandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    private func waitForRunningState(vmName: String, timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            do {
                let current = try await withServerRetry { try await self.loadVMs() }
                if current.contains(where: { $0.name == vmName && $0.isRunning }) {
                    return true
                }
            } catch {
                // Continue polling through transient API/server startup failures.
            }

            try? await Task.sleep(nanoseconds: UInt64(startVerificationPollInterval * 1_000_000_000))
        }

        return false
    }

    private func findLumeExecutableURL() -> URL? {
        let env = ProcessInfo.processInfo.environment
        let envPaths = (env["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        // Apps launched from Finder get a minimal PATH, so also check the
        // locations the Lume installer and Homebrew use.
        let candidates = envPaths + [
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin"),
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]

        let fileManager = FileManager.default
        for dir in candidates {
            let path = URL(fileURLWithPath: dir).appendingPathComponent("lume").path
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        return nil
    }

    private func requiredLumeExecutableURL() throws -> URL {
        guard let url = findLumeExecutableURL() else {
            throw LumeError.cliNotInstalled
        }
        return url
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func pruneDetailsCache(with vms: [LumeVM]) {
        let names = Set(vms.map(\.name))
        details = details.filter { names.contains($0.key) }
        detailsError = detailsError.filter { names.contains($0.key) }
        detailsLoading = Set(detailsLoading.filter { names.contains($0) })
        detailsUpdatedAt = detailsUpdatedAt.filter { names.contains($0.key) }

        for vm in vms {
            let newState = vm.stateDescription
            if let previous = lastStates[vm.name], previous != newState {
                detailsUpdatedAt[vm.name] = nil
                details[vm.name] = nil
            }
            lastStates[vm.name] = newState
        }
    }

    private func consume(pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            }
        }
    }
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

private enum LumeError: Error {
    case invalidResponse
    case httpError(Int)
    case cliNotInstalled
    case cliLaunchFailed
    case cliCommandFailed(String)
    case cliStartVerificationFailed(String)

    var message: String {
        switch self {
        case .invalidResponse:
            return "Unexpected response from Lume API."
        case .httpError(let status):
            return "Lume API returned HTTP \(status)."
        case .cliNotInstalled:
            return "Lume CLI not found. Install `lume` and ensure it is available in PATH (for example: /opt/homebrew/bin/lume)."
        case .cliLaunchFailed:
            return "Failed to launch `lume`. Make sure it is installed and available in PATH."
        case .cliCommandFailed(let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Lume CLI command failed."
            }
            return trimmed
        case .cliStartVerificationFailed(let logPath):
            return "Lume run command started but VM did not reach running state in time. Check log: \(logPath)"
        }
    }
}

private struct CLIResult {
    let status: Int32
    let stdout: String
    let stderr: String
}
