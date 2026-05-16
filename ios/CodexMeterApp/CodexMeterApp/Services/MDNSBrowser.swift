import Foundation
@preconcurrency import Combine
import Darwin

/// MDNSBrowser discovers HTTP services on the local network and publishes resolved URLs.
final class MDNSServiceBrowser: NSObject {
    static let shared = MDNSServiceBrowser()

    /// Publishes (url, name) for each discovered service.
    let discoveryPublisher = PassthroughSubject<(String, String), Never>()

    private let serviceType = "_http._tcp."
    private let domain = "local."
    private let netServiceBrowser = NetServiceBrowser()
    private var servicesResolving = Set<NetService>()
    private var isBrowsing = false
    private var discoveredURLs = Set<String>()

    private override init() {
        super.init()
        netServiceBrowser.delegate = self
    }

    func startBrowsing() {
        DispatchQueue.main.async {
            guard !self.isBrowsing else { return }
            self.isBrowsing = true
            self.discoveredURLs.removeAll()
            self.netServiceBrowser.searchForServices(ofType: self.serviceType, inDomain: self.domain)
        }
    }

    func stopBrowsing() {
        DispatchQueue.main.async {
            guard self.isBrowsing else { return }
            self.isBrowsing = false
            self.netServiceBrowser.stop()
            self.servicesResolving.removeAll()
            self.discoveredURLs.removeAll()
        }
    }

    private func cleanup(service: NetService) {
        service.delegate = nil
        servicesResolving.remove(service)
    }

    private func urlString(from service: NetService) -> String? {
        guard service.port > 0 else { return nil }

        if let addresses = service.addresses {
            for addressData in addresses {
                if let ip = ipAddressFrom(addressData: addressData) {
                    return "http://\(ip):\(service.port)"
                }
            }
        }

        guard let hostName = service.hostName, !hostName.isEmpty else { return nil }
        return "http://\(hostName):\(service.port)"
    }

    private func ipAddressFrom(addressData: Data) -> String? {
        return addressData.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) -> String? in
            guard let sockaddrPtr = pointer.bindMemory(to: sockaddr.self).baseAddress else {
                return nil
            }
            let family = sockaddrPtr.pointee.sa_family
            if family == sa_family_t(AF_INET) {
                let sockaddr4Ptr = UnsafeRawPointer(sockaddrPtr).assumingMemoryBound(to: sockaddr_in.self)
                var addr = sockaddr4Ptr.pointee.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                let conversion = inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN))
                if conversion != nil {
                    return String(cString: buffer)
                }
            }
            return nil
        }
    }
}

// MARK: - Async/Await helpers

extension MDNSServiceBrowser {
    /// Returns an AsyncStream of discovered (url, name) pairs.
    func discoveriesAsync() -> AsyncStream<(String, String)> {
        AsyncStream { continuation in
            let cancellable = discoveryPublisher.sink { pair in
                continuation.yield(pair)
            }
            continuation.onTermination = { _ in
                cancellable.cancel()
            }
            // start browsing when stream is created
            self.startBrowsing()
        }
    }

    /// Convenience: await the first discovery up to `timeout` seconds.
    /// Returns (url, name) or nil on timeout.
    func firstDiscovery(timeout: TimeInterval = 5.0) async -> (String, String)? {
        await withCheckedContinuation { (cont: CheckedContinuation<(String, String)?, Never>) in
            var resumed = false
            var cancellable: AnyCancellable? = nil
            cancellable = discoveryPublisher.sink { pair in
                if !resumed {
                    resumed = true
                    cancellable?.cancel()
                    cont.resume(returning: pair)
                }
            }
            // Timeout handler
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                if !resumed {
                    resumed = true
                    cancellable?.cancel()
                    cont.resume(returning: nil)
                }
            }
            self.startBrowsing()
        }
    }
}

extension MDNSServiceBrowser: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        DispatchQueue.main.async {
            if !self.servicesResolving.contains(service) {
                self.servicesResolving.insert(service)
                service.delegate = self
                service.resolve(withTimeout: 5.0)
            }
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        DispatchQueue.main.async {
            self.servicesResolving.remove(service)
            if let urlString = self.urlString(from: service) {
                self.discoveredURLs.remove(urlString)
            }
        }
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        DispatchQueue.main.async { self.isBrowsing = false }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        DispatchQueue.main.async { self.isBrowsing = false }
    }
}

extension MDNSServiceBrowser: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        DispatchQueue.main.async {
            guard self.servicesResolving.contains(sender) else { self.cleanup(service: sender); return }
            guard let urlString = self.urlString(from: sender) else { self.cleanup(service: sender); return }
            if !self.discoveredURLs.contains(urlString) {
                self.discoveredURLs.insert(urlString)
                self.discoveryPublisher.send((urlString, sender.name))
            }
            self.cleanup(service: sender)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        DispatchQueue.main.async { self.cleanup(service: sender) }
    }

    func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        // No-op
    }
}
