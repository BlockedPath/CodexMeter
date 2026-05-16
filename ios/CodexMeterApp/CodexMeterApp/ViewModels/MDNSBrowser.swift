import Foundation

final class MDNSBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    static let shared = MDNSBrowser()

    private let serviceType = "_codexmeter._tcp."
    private let domain = "local."
    private let netServiceBrowser = NetServiceBrowser()
    private var servicesResolving = Set<NetService>()
    private var isBrowsing = false

    // To avoid duplicate notifications for the same resolved URL
    private var discoveredURLs = Set<String>()

    private override init() {
        super.init()
        netServiceBrowser.delegate = self
    }

    // MARK: - Public

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

    // MARK: - NetServiceBrowserDelegate

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
            // Clean up if service is removed before resolving
            self.servicesResolving.remove(service)
            // Also remove associated URL if any
            if let urlString = self.urlString(from: service) {
                self.discoveredURLs.remove(urlString)
            }
        }
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        DispatchQueue.main.async {
            self.isBrowsing = false
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        DispatchQueue.main.async {
            self.isBrowsing = false
        }
    }

    // MARK: - NetServiceDelegate

    func netServiceDidResolveAddress(_ sender: NetService) {
        DispatchQueue.main.async {
            guard self.servicesResolving.contains(sender) else { return }
            guard let urlString = self.urlString(from: sender) else {
                self.cleanup(service: sender)
                return
            }
            if !self.discoveredURLs.contains(urlString) {
                self.discoveredURLs.insert(urlString)
                NotificationCenter.default.post(name: Notification.Name("didDiscoverDaemon"),
                                                object: nil,
                                                userInfo: ["url": urlString])
            }
            self.cleanup(service: sender)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        DispatchQueue.main.async {
            self.cleanup(service: sender)
        }
    }

    func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        // No-op for this implementation
    }

    // MARK: - Helpers

    private func cleanup(service: NetService) {
        service.delegate = nil
        self.servicesResolving.remove(service)
    }

    private func urlString(from service: NetService) -> String? {
        guard service.port > 0 else { return nil }

        // Try to get IPv4 address from addresses data
        if let addresses = service.addresses {
            for addressData in addresses {
                if let ip = self.ipAddressFrom(addressData: addressData) {
                    return "http://\(ip):\(service.port)"
                }
            }
        }

        // Fallback to hostName (which may be nil or empty)
        guard let hostName = service.hostName, !hostName.isEmpty else { return nil }
        return "http://\(hostName):\(service.port)"
    }

    private func ipAddressFrom(addressData: Data) -> String? {
        // The sockaddr structures can be IPv4 or IPv6.
        // We prefer IPv4 addresses.
        return addressData.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) -> String? in
            guard let sockaddrPtr = pointer.bindMemory(to: sockaddr.self).baseAddress else {
                return nil
            }
            let family = sockaddrPtr.pointee.sa_family
            if family == sa_family_t(AF_INET) {
                // IPv4
                let sockaddr4Ptr = UnsafeRawPointer(sockaddrPtr).assumingMemoryBound(to: sockaddr_in.self)
                var addr = sockaddr4Ptr.pointee.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                let conversion = inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN))
                if conversion != nil {
                    return String(cString: buffer)
                }
            }
            // Skip IPv6 for now as per requirements, prefer IPv4 only
            return nil
        }
    }
}

import Darwin // For sockaddr and inet_ntop
