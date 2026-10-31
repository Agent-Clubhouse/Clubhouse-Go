import SwiftUI
import ClubhouseTransport

/// Explicit capture, reviewed local export and separately consented collector export.
struct CompanionDiagnosticsView: View {
    private let exporter: AnnexOTLPExporter?
    @State private var exportHealth: AnnexOTLPExporter.Health?
    init(exporter: AnnexOTLPExporter? = nil) { self.exporter = exporter }
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
                if AnnexTelemetry.shared.capturesForEnrollment {
                    Text("You're enrolled in developer feedback, so these diagnostics are also captured, with random trace IDs sent to your paired desktop, and sent to the developer as telemetry, even with Capture off. Clearing enrollment in Settings stops it.")
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("diagnostics.enrollment-capture")
                }
            }
            Section("Export") {
                Label(settings.remoteEnabled ? (settings.mode == .off ? "Collector paused (capture off)" : "Collector export enabled") : "Remote export disabled", systemImage: settings.remoteEnabled ? "network" : "network.slash")
                if let exportHealth {
                    Text("Collector accepted: \(exportHealth.delivered) · dropped: \(exportHealth.dropped) · latest result: \(exportHealth.failure.rawValue)")
                        .font(.caption)
                    Text("Acceptance does not prove downstream ingestion. Refresh to update; counts are process-local.").font(.caption).foregroundStyle(.secondary)
                }
                NavigationLink("Tracing destination") { CompanionTelemetryDestinationView() }
                Text("A tracing collector is separate from developer feedback. Collection alone does not enable sharing. You can also review a sanitized JSON snapshot before sharing it yourself.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Review diagnostic export") {
                    do {
                        reviewedExport = String(decoding: try AnnexTelemetry.shared.exportJSON(), as: UTF8.self)
                    } catch { exportError = true }
                }.disabled(snapshot.records.isEmpty)
                Button("Clear captured diagnostics", role: .destructive) {
                    settings.clear(); reviewedExport = nil; refresh()
                }
            }
            Section("Recent operations") {
                Text("\(snapshot.records.count) retained · \(snapshot.dropped) dropped at capacity")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(snapshot.records.reversed()) { record in
                    DisclosureGroup {
                        Text("Trace \(record.traceID)").font(.caption.monospaced()).textSelection(.enabled)
                        Text("\(record.serviceName) · \(record.serviceInstanceID)").font(.caption.monospaced())
                        ForEach(record.identifiers.keys.sorted(), id: \.self) { key in
                            LabeledContent(key, value: record.identifiers[key] ?? "").font(.caption.monospaced())
                        }
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
    private func refresh() {
        snapshot = AnnexTelemetry.shared.snapshot()
        Task { exportHealth = await exporter?.health() }
    }
}

struct CompanionTelemetryDestinationView: View {
    @State private var settings = AnnexDiagnosticSettings.shared
    @State private var address = ""
    @State private var error = false
    @State private var confirm = false
    var body: some View {
        Form {
            Section("Separate tracing backend") {
                Text("Use an existing HTTPS OTLP/HTTP JSON collector that forwards to your App Insights instance. An App Insights connection string is not an OTLP URL. This configuration is independent of Framebriar feedback.")
                TextField("https://collector.example/v1/traces", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Button("Save destination without enabling") {
                    do { try settings.configureDestination(address: address.trimmingCharacters(in: .whitespacesAndNewlines)); error = false }
                    catch { self.error = true }
                }
                Text("HTTPS and the complete /v1/traces route are required. No secrets in the URL. This route uses standard TLS trust, refuses redirects, and sends no authorization credentials. A collector requiring authentication needs a separately approved auth adapter.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let destination = settings.destination {
                Section("Reviewed destination") {
                    Text(destination.endpoint.absoluteString).font(.caption).textSelection(.enabled)
                    Text("Backend reference: \(destination.backendReference.uuidString.lowercased())").font(.caption.monospaced())
                    Button(settings.remoteEnabled ? "Disable collector export" : "Enable reviewed collector export") {
                        if settings.remoteEnabled { settings.setRemoteEnabled(false) } else { confirm = true }
                    }
                    Button("Remove destination", role: .destructive) { settings.removeDestination(); address = "" }
                }
            }
            if error { Text("Enter an HTTPS traces endpoint without credentials, query parameters or fragments.").foregroundStyle(.red) }
        }
        .navigationTitle("Tracing destination")
        .onAppear { address = settings.destination?.endpoint.absoluteString ?? "" }
        .confirmationDialog("Send future sanitized traces to this collector?", isPresented: $confirm, titleVisibility: .visible) {
            Button("I verified this collector — enable export") { settings.setRemoteEnabled(true) }
        } message: {
            Text("Confirm you control this destination and it accepts OTLP/HTTP JSON. Only traces collected after enabling are sent, while the app is active. Nothing from feedback enrollment is reused. Previously captured traces are excluded. Failed batches have bounded retries and may be dropped.")
        }
    }
}
