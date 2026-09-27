import Darwin
import Foundation
import SwiftUI
import UIKit

@main
struct M0App: App {
    var body: some Scene {
        WindowGroup { BenchmarkView() }
    }
}

@MainActor
final class BenchmarkModel: ObservableObject {
    @Published var isRunning = false
    @Published var status = "One pretokenized Choice request. Model hashing and loading are measured separately."
    @Published var reportURL: URL?

    func run() {
        guard !isRunning else { return }
        isRunning = true
        reportURL = nil
        status = "Verifying model, then running first + 20 warm requests…"
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var hardware = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &hardware, &size, nil, 0)
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        let device: [String: Any] = [
            "platform": "iOS", "simulator": simulator,
            "hardware": String(cString: hardware), "os": UIDevice.current.systemVersion,
            "thermal_state_at_start": ProcessInfo.processInfo.thermalState.rawValue,
        ]
        let deviceData: Data
        do { deviceData = try JSONSerialization.data(withJSONObject: device) }
        catch { status = error.localizedDescription; isRunning = false; return }
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try Self.execute(deviceData: deviceData)
                }.value
                status = result.0
                reportURL = result.1
            } catch {
                status = "Benchmark failed: \(error.localizedDescription)"
            }
            isRunning = false
        }
    }

    nonisolated private static func execute(deviceData: Data) throws -> (String, URL) {
        guard let fixtureURL = Bundle.main.url(forResource: "fixture", withExtension: "json"),
              let modelURL = Bundle.main.url(forResource: "model", withExtension: "gguf"),
              let receiptURL = Bundle.main.url(forResource: "build-receipt", withExtension: "json") else {
            throw NSError(domain: "edge_one.m0", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing bundled benchmark inputs"])
        }
        let fixture = try String(contentsOf: fixtureURL, encoding: .utf8)
        guard let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any],
              let fixtureHash = receipt["fixture_sha256"] as? String else {
            throw NSError(domain: "edge_one.m0", code: 5, userInfo: [NSLocalizedDescriptionKey: "Missing fixture checksum"])
        }
        let raw = try NativeBenchmark.run(withModelPath: modelURL.path, fixtureJSON: fixture, fixtureSHA256: fixtureHash, repetitions: 20)
        guard var report = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              var metadata = report["metadata"] as? [String: Any],
              let records = report["records"] as? [[String: Any]], records.count == 21 else {
            throw NSError(domain: "edge_one.m0", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid native report"])
        }
        metadata["device"] = try JSONSerialization.jsonObject(with: deviceData)
        metadata["build"] = receipt
        metadata["finished_utc"] = ISO8601DateFormatter().string(from: Date())
        report["metadata"] = metadata
        let warm = records.dropFirst().compactMap { $0["duration_ms"] as? Double }.sorted()
        guard warm.count == 20, warm.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw NSError(domain: "edge_one.m0", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid warm samples"])
        }
        let median = (warm[9] + warm[10]) / 2
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let url = directory.appendingPathComponent("m0-ios-\(UUID().uuidString).json")
        try data.write(to: url, options: .atomic)
        print("M0_REPORT_PATH=\(url.path)")
        return (String(format: "Warm p50: %.1f ms (20 samples)\nPretokenized native scoring + softmax. Export the raw report for parity validation.", median), url)
    }
}

struct BenchmarkView: View {
    @StateObject private var model = BenchmarkModel()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("M0 iOS Benchmark").font(.title2.bold())
                Text("Synthetic billing ticket · 3 Choice options").foregroundStyle(.secondary)
                #if targetEnvironment(simulator)
                Text("Simulator run. Physical-device latency remains unmeasured.")
                    .foregroundStyle(.secondary)
                #endif
                Text(model.status).textSelection(.enabled)
                if model.isRunning { ProgressView() }
                Button("Run 20 warm samples", action: model.run)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isRunning)
                    .accessibilityIdentifier("runBenchmark")
                if let url = model.reportURL { ShareLink("Export JSON report", item: url) }
                Spacer()
            }
            .padding()
            .navigationTitle("edge_one")
        }
    }
}
