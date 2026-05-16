import Foundation
import Network

/// Simple mDNS browser to discover HTTP services (_http._tcp) on the local LAN.
final class MDNSBrowser: NSObject {
    static let shared = MDNSBrowser()

    private var browser: NetServiceBrowser?
    private var services: [NetService] = []

    override init() {
        super.init()
    }

    func startBrowsing() {
        stopBrowsing()
        browser = NetServiceBrowser()
        browser?.delegate = self
        browser?.searchForServices(ofType: "_http._tcp.", inDomain: "local.")
    }

    func stopBrowsing() {
        browser?.stop()
        browser?.delegate = nil
        browser = nil
        services.removeAll()
    }
}

extension MDNSBrowser: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 == service }
    }
}

extension MDNSBrowser: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        defer { sender.stop() }
        guard let hostName = sender.hostName, !hostName.isEmpty else {
            // Try to extract from addresses
            if let addr = MDNSBrowser.firstIPv4Address(from: sender.addresses) {
                let url = "http://\(addr):\(sender.port)"
                NotificationCenter.default.post(name: .didDiscoverDaemon, object: nil, userInfo: ["url": url])
            }
            return
        }
        let url = "http://\(hostName):\(sender.port)"
        NotificationCenter.default.post(name: .didDiscoverDaemon, object: nil, userInfo: ["url": url])
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        // ignore
    }

    private static func firstIPv4Address(from addrs: [Data]?) -> String? {
        guard let addrs = addrs else { return nil }
        for d in addrs {
            d.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                let sa = ptr.bindMemory(to: sockaddr.self)
                if sa.count > 0 {
                    let family = sa[0].sa_family
                    if family == sa_family_t(AF_INET) {
                        // IPv4
                    }
                }
            }
        }
        // Fallback: not implemented full parsing here
        return nil
    }
}

extension Notification.Name {
    static let didDiscoverDaemon = Notification.Name("didDiscoverDaemon")
}
