import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var model = ScannerModel()
    @State private var mode: Mode = .list
    @State private var selection = Set<DiscoveredHost.ID>()

    enum Mode: String, CaseIterable, Identifiable {
        case list = "List", map = "Map"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 500)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.toggle() } label: {
                    Label(model.isScanning ? "Stop" : "Scan",
                          systemImage: model.isScanning ? "stop.fill" : "arrow.clockwise")
                }
                .keyboardShortcut("r")
                .help(model.isScanning ? "Stop scanning" : "Scan the local subnet (⌘R)")
            }
        }
        .task { model.start() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "network")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                if let i = model.interface {
                    Text("\(i.name) · \(IPv4.string(i.address)) · \(i.cidr)")
                        .font(.headline)
                        .monospacedDigit()
                } else {
                    Text("Local Network").font(.headline)
                }
                Text(model.status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isScanning {
                ProgressView(value: model.progress)
                    .frame(width: 160)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if model.hosts.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(model.isScanning ? "Looking for devices…" : "No devices found")
                    .foregroundStyle(.secondary)
            }
        } else if mode == .list {
            hostTable
        } else {
            NetworkMapView(hosts: model.hosts)
        }
    }

    private var hostTable: some View {
        Table(model.hosts, selection: $selection) {
            TableColumn("IP Address") { h in
                HStack(spacing: 6) {
                    Image(systemName: h.symbol)
                        .foregroundStyle(h.isThisMac || h.isGateway ? Color.accentColor : Color.secondary)
                        .frame(width: 18)
                    Text(h.ip).monospacedDigit()
                }
            }
            .width(min: 140, ideal: 160)
            TableColumn("Name") { h in
                Text(h.displayName)
                    .foregroundStyle(h.hostname == nil ? Color.secondary : Color.primary)
            }
            TableColumn("MAC Address") { h in
                Text(h.mac ?? "—")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(h.mac == nil ? Color.secondary : Color.primary)
            }
            .width(min: 150, ideal: 170)
            TableColumn("Response") { h in
                Text(h.latency.map { String(format: "%.0f ms", $0) } ?? (h.isThisMac ? "—" : "ARP only"))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 90)
        }
        .contextMenu(forSelectionType: DiscoveredHost.ID.self) { ids in
            Button("Copy IP Address") {
                let text = model.hosts.filter { ids.contains($0.id) }.map(\.ip).joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .disabled(ids.isEmpty)
        }
    }
}

// MARK: - Map

struct NetworkMapView: View {
    let hosts: [DiscoveredHost]

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let hub = hosts.first(where: \.isGateway) ?? hosts.first(where: \.isThisMac) ?? hosts[0]
            let others = hosts.filter { $0.id != hub.id }
            let radius = max(90, min(geo.size.width, geo.size.height) / 2 - 60)
            let points: [CGPoint] = others.indices.map { i in
                let angle = Double(i) / Double(max(others.count, 1)) * 2 * .pi - .pi / 2
                return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            }

            ZStack {
                Path { p in
                    for pt in points { p.move(to: center); p.addLine(to: pt) }
                }
                .stroke(Color.secondary.opacity(0.35), lineWidth: 1)

                NodeView(host: hub, prominent: true).position(center)
                ForEach(Array(others.enumerated()), id: \.element.id) { i, h in
                    NodeView(host: h, prominent: false).position(points[i])
                }
            }
        }
        .padding(30)
    }
}

private struct NodeView: View {
    let host: DiscoveredHost
    let prominent: Bool

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: host.symbol)
                .font(.system(size: prominent ? 22 : 15))
                .foregroundStyle(.white)
                .frame(width: prominent ? 48 : 34, height: prominent ? 48 : 34)
                .background(Circle().fill(host.isThisMac || host.isGateway ? Color.accentColor : Color.gray))
            Text(host.ip)
                .font(.caption.monospacedDigit())
            if host.hostname != nil || prominent {
                Text(host.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 110)
            }
        }
        .help("\(host.displayName)\n\(host.ip)\n\(host.mac ?? "")")
    }
}
