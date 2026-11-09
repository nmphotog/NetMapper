import Foundation

enum CSVExporter {
    static func csv(for hosts: [DiscoveredHost]) -> String {
        var rows = [["IP Address", "Name", "MAC Address", "Response (ms)", "Role"]]
        for h in hosts {
            let role = h.isThisMac ? "This Mac" : (h.isGateway ? "Router" : "")
            rows.append([
                h.ip,
                h.hostname ?? "",
                h.mac ?? "",
                h.latency.map { String(format: "%.0f", $0) } ?? "",
                role,
            ])
        }
        return rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// Quotes a field if it contains a comma, quote, or newline (RFC 4180).
    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
