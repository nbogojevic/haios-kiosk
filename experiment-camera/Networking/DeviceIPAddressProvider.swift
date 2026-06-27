//
//  DeviceIPAddressProvider.swift
//  experiment-camera
//
//  Split from CameraCaptureNetworking.swift.
//

import Foundation
import Darwin

enum DeviceIPAddressProvider {
    private enum InterfacePreference: Int {
        case wifiIPv4 = 0
        case wifiIPv6 = 1
        case cellularIPv4 = 2
        case cellularIPv6 = 3
        case otherIPv4 = 4
        case otherIPv6 = 5
    }

    nonisolated static func currentIPAddress() -> String? {
        var interfacePointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfacePointer) == 0, let firstInterface = interfacePointer else {
            return nil
        }

        defer { freeifaddrs(interfacePointer) }

        var current = firstInterface
        var candidates: [(priority: Int, address: String)] = []

        while true {
            let interface = current.pointee
            let flags = Int32(interface.ifa_flags)

            guard let socketAddress = interface.ifa_addr else {
                if let next = interface.ifa_next {
                    current = next
                    continue
                }

                break
            }

            let family = socketAddress.pointee.sa_family
            let isIPv4 = family == UInt8(AF_INET)
            let isIPv6 = family == UInt8(AF_INET6)

            guard (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  isIPv4 || isIPv6 else {
                if let next = interface.ifa_next {
                    current = next
                    continue
                }

                break
            }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            guard result == 0 else {
                if let next = interface.ifa_next {
                    current = next
                    continue
                }

                break
            }

            let address = String(cString: hostname)
            if isIPv6 && address.lowercased().hasPrefix("fe80") {
                if let next = interface.ifa_next {
                    current = next
                    continue
                }

                break
            }

            let interfaceName = String(cString: interface.ifa_name)
            if let preference = preference(for: interfaceName, isIPv4: isIPv4) {
                candidates.append((priority: preference.rawValue, address: address))
            }

            guard let next = interface.ifa_next else {
                break
            }

            current = next
        }

        return candidates.min(by: { $0.priority < $1.priority })?.address
    }

    nonisolated private static func preference(for interfaceName: String, isIPv4: Bool) -> InterfacePreference? {
        switch interfaceName {
        case "en0":
            return isIPv4 ? .wifiIPv4 : .wifiIPv6
        case "pdp_ip0":
            return isIPv4 ? .cellularIPv4 : .cellularIPv6
        default:
            return isIPv4 ? .otherIPv4 : .otherIPv6
        }
    }
}
