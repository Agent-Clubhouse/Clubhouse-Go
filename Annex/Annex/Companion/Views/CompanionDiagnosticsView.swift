import SwiftUI
import ClubhouseTransport

/// Explicit local capture and manual reviewed export. There is no remote destination.
struct CompanionDiagnosticsView: View {
    @State private var settings = AnnexDiagnosticSettings.shared
    @State private var snapshot = AnnexTelemetry.shared.snapshot()
    @State private var reviewedExport: String?
    @State private var exportError = false
    var body: some View {
        List {
            Section {
                Picker("Capture", selection: Binding(get: { settings.mode }, set: {
                    settings.select($0); refresh(); reviewedExport = nil
                })) {
                    ForEach(AnnexDiagnosticCaptureMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }.accessibilityIdentifier("diagnostics.capture")
                Text("Off by default. This session stops on app restart; Always remembers collection on future launches. Both keep only bounded traces in memory. No messages, addresses, paths, credentials or screenshots. Off clears traces. Collection also sends random W3C trace IDs to your paired desktop for correlation, never to a collector automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Export") {
                Label("Remote export disabled", systemImage: "network.slash")
                Text("No collector is configured. Nothing is uploaded automatically. Review a sanitized JSON snapshot before sharing it yourself.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Review diagnostic export") {
                    do {
                        reviewedExport = String(decoding: try AnnexTelemetry.shared.exportJSON(), as: UTF8.self)
                    } catch { exportError = true }
                }.disabled(snapshot.records.isEmpty)
                Button("Clear captured diagnostics", role: .destructive) {
                    AnnexTelemetry.shared.clear(); reviewedExport = nil; refresh()
                }
            }
            Section("Recent operations") {
                Text("\(snapshot.records.count) retained · \(snapshot.dropped) dropped at capacity")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(snapshot.records.reversed()) { record in
                    DisclosureGroup {
                        Text("Trace \(record.traceID)").font(.caption.monospaced()).textSelection(.enabled)
                        ForEach(record.measurements.keys.sorted(), id: \.self) { key in
                            LabeledContent(key, value: String(format: "%.1f", record.measurements[key] ?? 0))
                        }
                        if !record.events.isEmpty { Text(record.events.joined(separator: ", ")).font(.caption) }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(record.operation.rawValue)
                            Text("\(record.durationMs, specifier: "%.1f") ms · \(record.failure.rawValue)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .toolbar { Button("Refresh", systemImage: "arrow.clockwise", action: refresh) }
        .onAppear(perform: refresh)
        .sheet(isPresented: Binding(get: { reviewedExport != nil }, set: { if !$0 { reviewedExport = nil } })) {
            NavigationStack {
                ScrollView { Text(reviewedExport ?? "").font(.caption.monospaced()).textSelection(.enabled).padding() }
                    .navigationTitle("Review export")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Done") { reviewedExport = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            if let reviewedExport { ShareLink(item: reviewedExport) }
                        }
                    }
            }
        }
        .alert("Could not prepare bounded export", isPresented: $exportError) { Button("OK") {} }
    }
    private func refresh() { snapshot = AnnexTelemetry.shared.snapshot() }
}
