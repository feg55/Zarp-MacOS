import Darwin
import Foundation
import ZarpCore

/// Finds another VPN or proxy that currently carries the machine's traffic (Windows Zarp's
/// `NetCheck.ForeignVpnAdapters`). A scan run while one is active measures *its* tunnel, not
/// anything Zarp does, and a full tunnel cannot be set up on top of it — so the engine asks before
/// carrying on.
///
/// Two independent signals, either of which flags an interface:
///
/// - the default route points at a `utun` interface — whoever owns it is, by definition, carrying
///   everything; and
/// - a `utun` interface is up and holds an ordinary IPv4 address. macOS's own `utun` devices (iCloud
///   Private Relay, Handoff, ...) carry only IPv6 link-local addresses, so requiring an IPv4 one
///   separates a VPN client's tunnel from the system's plumbing — the same "must have a real
///   gateway, not merely exist" rule the Windows check applies.
///
/// Zarp's own tunnel is not a candidate: the engine closes it before asking.
struct SystemNetworkInspector: NetworkInspector {
    func foreignVPNInterfaceNames() -> [String] {
        var names = Set(Self.tunnelInterfacesWithIPv4())
        if let route = Self.defaultRouteInterface(), route.hasPrefix("utun") { names.insert(route) }
        return names.sorted()
    }

    /// `utun*` interfaces that are up and have a non-link-local IPv4 address.
    static func tunnelInterfacesWithIPv4() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var found = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("utun") else { continue }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0 else { continue }
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let ipv4 = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if ipv4 >> 16 == 0xA9FE { continue } // 169.254.0.0/16, link-local
            found.insert(name)
        }
        return found.sorted()
    }

    /// The interface `route -n get default` reports (a read-only query any user may run).
    static func defaultRouteInterface() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", "get", "default"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return interface(fromRouteGet: String(decoding: data, as: UTF8.self))
    }

    /// Pulls `interface: en0` out of `route -n get` output.
    static func interface(fromRouteGet output: String) -> String? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("interface:") {
                let value = trimmed.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}
