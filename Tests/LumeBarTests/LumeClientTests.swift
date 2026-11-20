import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import LumeBar

@MainActor
struct LumeClientTests {
    @Test func previewIgnoresBlankBootFrameButKeepsDarkContent() throws {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                            bytesPerRow: 8, space: CGColorSpaceCreateDeviceGray(),
                                            bitmapInfo: CGImageAlphaInfo.none.rawValue))
        let frame = CGRect(x: 0, y: 0, width: 8, height: 8)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(frame)
        #expect(!VNCThumbnailStore.hasVisibleContent(try #require(context.makeImage())))

        context.setFillColor(gray: 0.05, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        #expect(VNCThumbnailStore.hasVisibleContent(try #require(context.makeImage())))
    }

    @Test func serviceURLRequiresAnHTTPOrigin() {
        #expect(LumeClient.serviceURL(" HTTPS://EXAMPLE.test:443/proxy/ ")?.absoluteString == "https://example.test/proxy")
        for invalid in ["", "localhost:7777", "file:///tmp/lume", "http://", "http://user@host", "http://host?token=x", "http://host:65536"] {
            #expect(LumeClient.serviceURL(invalid) == nil, "Accepted \(invalid)")
        }
    }

    @Test func detailsEncodesNameAndStorageIndependently() throws {
        let base = try #require(LumeClient.serviceURL("https://example.test/proxy"))
        let id = LumeVM.ID(name: "QA / 100% #1", storage: "Lab & Testing")
        let url = try #require(LumeClient.makeRequest(at: base, vm: id).url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.percentEncodedPath == "/proxy/lume/vms/QA%20%2F%20100%25%20%231")
        #expect(components.queryItems == [URLQueryItem(name: "storage", value: "Lab & Testing")])
    }

    @Test func actionsUseTheSelectedServiceAndStorage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LumeFixture.self]
        let client = LumeClient(service: "https://fixture.test/proxy", session: URLSession(configuration: configuration))
        await client.fetchVms()
        #expect(client.vms.count == 3)
        let vm = try #require(client.vms.first { $0.storage == "Test" })
        let pulling = try #require(client.vms.first { $0.name == "downloading" })
        #expect(pulling.isProvisioning)
        await client.run(vm: pulling, noDisplay: false, vncDisabled: true)
        #expect(client.actionError == nil)

        await client.run(vm: vm, noDisplay: false, vncDisabled: true)
        #expect(client.actionError == nil)
        let running = try #require(client.vms.first { $0.id == vm.id })
        #expect(running.isRunning)
        await client.stop(vm: running)
        #expect(client.actionError == nil)
        #expect(client.vms.first { $0.id == vm.id }?.isRunning == false)

        client.updateBaseURL("https://other.test")
        #expect(client.vms.isEmpty)
        #expect(client.serviceReachable == nil)
        #expect(client.vmActionsInFlight.isEmpty)
    }

    @Test func oldServersCannotSilentlyEnableVNC() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LumeFixture.self]
        let client = LumeClient(service: "https://old.fixture.test/proxy", session: URLSession(configuration: configuration))
        await client.fetchVms()
        let vm = try #require(client.vms.first { $0.storage == "Test" })
        await client.run(vm: vm, noDisplay: true, vncDisabled: true)
        #expect(client.actionError?.contains("Lume 0.6.0") == true)
        #expect(client.vms.first { $0.id == vm.id }?.isRunning == false)
    }

    @Test func automaticScreenSharingUsesAnAdvertisedEndpointBeforeAssumingGuestSharing() throws {
        let data = Data(#"{"name":"dev","os":"macOS","ipAddress":"192.0.2.42","vncUrl":"vnc://localhost:5902"}"#.utf8)
        let vm = try JSONDecoder().decode(LumeVM.self, from: data)
        let login = GuestLogin(username: "guest", password: "fixture-password")

        #expect(ScreenSharingEndpoint.resolve(vm: vm, details: nil, preference: .auto, guestLogin: nil)?.kind == .lumeVNC)
        #expect(ScreenSharingEndpoint.resolve(vm: vm, details: nil, preference: .auto, guestLogin: login)?.kind == .guest)
        #expect(ScreenSharingEndpoint.resolve(vm: vm, details: nil, preference: .guest, guestLogin: nil)?.kind == .guest)
        #expect(ScreenSharingEndpoint.resolve(vm: vm, details: nil, preference: .lumeVNC, guestLogin: login)?.kind == .lumeVNC)
    }

    @Test func screenSharingEndpointsRespectScopeAndInput() throws {
        let service = try #require(LumeClient.serviceURL("http://localhost:7777"))
        let other = try #require(LumeClient.serviceURL("https://other.test"))
        let data = Data(#"{"name":"dev","os":"macOS","locationName":"Test","ipAddress":"fd00::1","vncUrl":"vnc://localhost:65536"}"#.utf8)
        let vm = try JSONDecoder().decode(LumeVM.self, from: data)
        #expect(ScreenSharingSettings.scope(for: vm, service: service, address: "fd00::1") !=
                ScreenSharingSettings.scope(for: vm, service: other, address: "fd00::1"))
        #expect(ScreenSharingSettings.scope(for: vm, service: service, address: "fd00::1") !=
                ScreenSharingSettings.scope(for: vm, service: service, address: "fd00::2"))
        #expect(ScreenSharingEndpoint.resolve(vm: vm, details: nil, preference: .lumeVNC, guestLogin: nil) == nil)
        let login = GuestLogin(username: "qa user", password: "fixture-password")
        let endpoint = try #require(ScreenSharingEndpoint.resolve(vm: vm, details: nil, preference: .auto, guestLogin: login))
        #expect(endpoint.kind == .guest)
        #expect(endpoint.openURL.absoluteString == "vnc://qa%20user@[fd00::1]:5900")
        #expect(endpoint.openURL.password() == nil)
    }
}

private final class LumeFixture: URLProtocol, @unchecked Sendable {
    private static let isRunning = Mutex(false)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(),
              ["fixture.test", "old.fixture.test"].contains(host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let status: Int
        var response = Data()
        switch (request.httpMethod, url.path()) {
        case ("GET", "/proxy/lume/host/status"):
            let version = host == "fixture.test" ? "0.6.0" : "0.5.3"
            response = Data(#"{"version":"\#(version)"}"#.utf8)
            status = 200
        case ("GET", "/proxy/lume/vms"):
            let state = host == "fixture.test" && Self.isRunning.withLock { $0 } ? "running" : "stopped"
            response = Data("""
            [{"name":"dev","locationName":"Test","status":"\(state)"},
             {"name":"dev","locationName":"Default","status":"stopped"},
             {"name":"downloading","status":"pulling"}]
            """.utf8)
            status = 200
        case ("POST", "/proxy/lume/vms/dev/run"):
            let value = body
            if host == "fixture.test", value["storage"] as? String == "Test", value["noDisplay"] as? Bool == true,
               value["vnc"] as? String == "disabled" {
                Self.isRunning.withLock { $0 = true }
                status = 202
            } else {
                status = 400
            }
        case ("POST", "/proxy/lume/vms/dev/stop"):
            if body["storage"] as? String == "Test" {
                Self.isRunning.withLock { $0 = false }
                status = 200
            } else {
                status = 400
            }
        default:
            status = 404
        }
        let result = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: result, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private var body: [String: Any] {
        var bytes = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
        }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
    }
}
