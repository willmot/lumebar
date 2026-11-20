import AppKit
import RoyalVNCKit

@MainActor
final class VNCThumbnailStore: ObservableObject {
    @Published private(set) var images: [LumeVM.ID: CGImage] = [:]
    @Published private(set) var errors: [LumeVM.ID: String] = [:]

    private struct Snapshot {
        let token: UUID
        let connection: ThumbnailConnection
        let timeout: Task<Void, Never>
    }

    private var snapshots: [LumeVM.ID: Snapshot] = [:]
    private var attemptedVMs: Set<LumeVM.ID> = []

    func start(vm: LumeVM.ID, endpoint: ScreenSharingEndpoint) {
        guard endpoint.canSnapshot, attemptedVMs.insert(vm).inserted else { return }

        let token = UUID()
        let connection = ThumbnailConnection(endpoint: endpoint) { [weak self] result in
            Task { @MainActor in
                self?.finish(vm: vm, token: token, result: result)
            }
        }
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            self?.finish(vm: vm, token: token, result: .failed("Preview timed out"))
        }
        snapshots[vm] = Snapshot(token: token, connection: connection, timeout: timeout)
        connection.connect()
    }

    private func finish(vm: LumeVM.ID, token: UUID, result: ThumbnailConnection.Result) {
        // Ignore late frames and disconnects from superseded connections.
        guard snapshots[vm]?.token == token else { return }
        disconnect(vm: vm)
        switch result {
        case .image(let image): images[vm] = image
        case .failed(let message): errors[vm] = message
        }
    }

    private func disconnect(vm: LumeVM.ID) {
        guard let snapshot = snapshots.removeValue(forKey: vm) else { return }
        snapshot.timeout.cancel()
        snapshot.connection.disconnect()
    }

    nonisolated static func hasVisibleContent(_ image: CGImage) -> Bool {
        let side = 8
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { return true }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return UnsafeRawBufferPointer(start: data, count: side * side).contains { $0 > 0 }
    }

    func releaseForScreenSharing(vm: LumeVM.ID) {
        disconnect(vm: vm)
        if images[vm] == nil { errors[vm] = "Screen Sharing opened separately" }
    }

    func stop(vm: LumeVM.ID) {
        disconnect(vm: vm)
        images[vm] = nil
        errors[vm] = nil
        attemptedVMs.remove(vm)
    }

    func stopAll() {
        for id in Array(snapshots.keys) { disconnect(vm: id) }
        images = [:]
        errors = [:]
        attemptedVMs = []
    }
}

private final class ThumbnailConnection: NSObject, VNCConnectionDelegate {
    enum Result: Sendable {
        case image(CGImage)
        case failed(String)
    }

    private let endpointKind: ScreenSharingEndpoint.Kind
    private let credential: VNCCredential?
    private let connection: VNCConnection
    private let complete: @Sendable (Result) -> Void

    init(endpoint: ScreenSharingEndpoint, complete: @escaping @Sendable (Result) -> Void) {
        let logger = VNCCustomLogger(logDebugHandler: { _ in },
                                     logInfoHandler: { _ in },
                                     logWarningHandler: { _ in },
                                     logErrorHandler: { _ in })
        let settings = VNCConnection.Settings(isDebugLoggingEnabled: false,
                                              hostname: endpoint.host,
                                              port: endpoint.port,
                                              isShared: true,
                                              isScalingEnabled: true,
                                              useDisplayLink: false,
                                              inputMode: .none,
                                              isClipboardRedirectionEnabled: false,
                                              colorDepth: .depth24Bit,
                                              frameEncodings: .default)
        connection = VNCConnection(settings: settings, logger: logger)
        endpointKind = endpoint.kind
        credential = endpoint.credential
        self.complete = complete
        super.init()
        connection.delegate = self
    }

    func connect() {
        connection.connect()
    }

    func disconnect() {
        connection.delegate = nil
        connection.disconnect()
    }

    func connection(_ connection: VNCConnection, stateDidChange state: VNCConnection.ConnectionState) {
        guard state.status == .disconnected else { return }
        if endpointKind == .guest, let error = state.error as? VNCError, error.isAuthenticationError {
            complete(.failed("Check Screen Sharing login and access"))
        } else {
            complete(.failed("Preview unavailable"))
        }
    }

    func connection(_ connection: VNCConnection,
                    credentialFor authenticationType: VNCAuthenticationType,
                    completion: @escaping (VNCCredential?) -> Void) {
        completion(credential)
    }

    func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {}
    func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {}
    func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {}

    func connection(_ connection: VNCConnection, didUpdateFramebuffer framebuffer: VNCFramebuffer,
                    x: UInt16, y: UInt16, width: UInt16, height: UInt16) {
        // The first frame can be black while the guest boots. Keep listening
        // within the snapshot timeout without waking or interacting with it.
        guard let image = framebuffer.cgImage, VNCThumbnailStore.hasVisibleContent(image) else { return }
        complete(.image(image))
    }
}
