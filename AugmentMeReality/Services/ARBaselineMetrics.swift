import Foundation
import Darwin
import os

/// Opt-in observations for issue #3. A scene update is a render proxy, never proof
/// of presentation. Durations are elapsed wall time, not CPU or GPU execution time.
/// Enable with `-ARBaselineMetrics`; run the identical workload without that argument
/// to measure instrumentation overhead. All mutable state is protected by `lock`.
final class ARBaselineMetrics: @unchecked Sendable {
    static let shared = ARBaselineMetrics(
        enabled: ProcessInfo.processInfo.arguments.contains("-ARBaselineMetrics"),
        automaticExport: true
    )

    struct Limits: Codable, Sendable {
        var epochs = 16
        var seriesPerEpoch = 64
        var samplesPerSeries = 4096
        var eventsPerEpoch = 256
        var eventNamesPerEpoch = 64
        var workloadsPerEpoch = 32
        var signpostStartsPerSecond = 20
        var systemSamples = 128
    }

    struct Token: @unchecked Sendable {
        fileprivate let epochID: Int
        fileprivate let generation: Int
        fileprivate let startedAt: TimeInterval
        fileprivate let name: StaticString
        fileprivate let signpostID: OSSignpostID?
    }

    struct Event: Codable, Sendable {
        let name: String
        let details: String
        let uptime: TimeInterval
        let secondsSinceIntent: TimeInterval
        let generation: Int
    }

    struct Distribution: Codable, Sendable {
        let count: Int
        let meanMilliseconds: Double?
        let minimumMilliseconds: Double?
        let maximumMilliseconds: Double?
        let p95Milliseconds: Double?
        let p99Milliseconds: Double?
    }

    /// Constant-memory, conservative upper bounds in 1 ms buckets. Values over
    /// 1000 ms are an explicit overflow bucket; its quantile upper bound is nil.
    struct HistogramSummary: Codable, Sendable {
        let count: Int
        let bucketWidthMilliseconds: Double
        let p95UpperBoundMilliseconds: Double?
        let p99UpperBoundMilliseconds: Double?
        let overflowCount: Int
    }

    private struct Histogram: Sendable {
        var buckets = [Int](repeating: 0, count: 1002)
        var count = 0
        mutating func add(_ value: Double) {
            let index = value > 1000 ? 1001 : Int(ceil(value))
            buckets[index] += 1
            count += 1
        }
        var summary: HistogramSummary {
            func bound(_ fraction: Double) -> Double? {
                guard count > 0 else { return nil }
                let rank = Int(ceil(Double(count) * fraction))
                var cumulative = 0
                for (index, count) in buckets.enumerated() {
                    cumulative += count
                    if cumulative >= rank { return index == 1001 ? nil : Double(index) }
                }
                return nil
            }
            return HistogramSummary(count: count, bucketWidthMilliseconds: 1,
                p95UpperBoundMilliseconds: bound(0.95), p99UpperBoundMilliseconds: bound(0.99),
                overflowCount: buckets[1001])
        }
    }

    struct WorkloadSummary: Codable, Sendable {
        let enabled: Bool
        let observedActiveSeconds: Double
        let transitions: Int
    }

    struct SeriesSummary: Codable, Sendable {
        let name: String
        let unit: String
        let totalCount: Int
        let meanMilliseconds: Double?
        let minimumMilliseconds: Double?
        let maximumMilliseconds: Double?
        let wholeEpochHistogram: HistogramSummary
        let recentSamples: Distribution
        let startupFirstTenSeconds: Distribution
        let firstSampleUptime: TimeInterval?
        let lastSampleUptime: TimeInterval?
        let sampleAgeMilliseconds: Double?
        let recentWindowStartUptime: TimeInterval?
        let invalidSamples: Int
    }

    struct EpochSummary: Codable, Sendable {
        let id: Int
        let kind: String
        let generation: Int
        let intentUptime: TimeInterval
        let endedUptime: TimeInterval?
        let series: [SeriesSummary]
        let firstEventsByName: [String: Event]
        let recentEvents: [Event]
        let workloads: [String: Bool]
        let workloadActivity: [String: WorkloadSummary]
        let conditions: [String: String]
        let droppedEvents: Int
        let droppedSeries: Int
        let droppedEventNames: Int
        let droppedWorkloads: Int
    }

    struct Snapshot: Codable, Sendable {
        let schemaVersion: Int
        let runID: String
        let enabled: Bool
        let exportedAt: Date
        let exportedUptime: TimeInterval
        let metadata: [String: String]
        let limits: Limits
        let epochs: [EpochSummary]
        let droppedEpochs: Int
        let droppedLateMeasurements: Int
        let residentMemoryBytes: UInt64?
        let processCPUSeconds: Double?
        let processThermalState: String
        let recentSystemSamples: [SystemSample]
        let droppedSystemSamples: Int
    }

    struct SystemSample: Codable, Sendable {
        let uptime: TimeInterval
        let epochID: Int?
        let generation: Int?
        let residentMemoryBytes: UInt64?
        let processCPUSeconds: Double?
        let processThermalState: String
    }

    private struct TimedValue: Sendable {
        let uptime: TimeInterval
        let value: Double
    }

    private struct Ring<Element: Sendable>: Sendable {
        let capacity: Int
        var storage: [Element] = []
        var next = 0

        mutating func append(_ value: Element) {
            if storage.count < capacity {
                storage.append(value)
            } else {
                storage[next] = value
            }
            next = (next + 1) % capacity
        }

        var ordered: [Element] {
            guard storage.count == capacity else { return storage }
            return Array(storage[next...]) + Array(storage[..<next])
        }
    }

    private struct Series: Sendable {
        var totalCount = 0
        var sum = 0.0
        var minimum: Double?
        var maximum: Double?
        var firstSampleUptime: TimeInterval?
        var lastSampleUptime: TimeInterval?
        var previousObservation: TimeInterval?
        var lastObservationSignpost: TimeInterval?
        var invalidSamples = 0
        var histogram = Histogram()
        var recent: Ring<TimedValue>
        var startup: [Double] = []

        mutating func add(_ value: Double, at uptime: TimeInterval, intent: TimeInterval) {
            guard value.isFinite, value >= 0, uptime.isFinite, uptime >= intent else {
                invalidSamples += 1
                return
            }
            totalCount += 1
            histogram.add(value)
            sum += value
            minimum = min(minimum ?? value, value)
            maximum = max(maximum ?? value, value)
            firstSampleUptime = firstSampleUptime ?? uptime
            lastSampleUptime = max(lastSampleUptime ?? uptime, uptime)
            recent.append(TimedValue(uptime: uptime, value: value))
            if uptime - intent <= 10, startup.count < recent.capacity {
                startup.append(value)
            }
        }
    }

    private struct Epoch: Sendable {
        let id: Int
        let kind: String
        let generation: Int
        let intentUptime: TimeInterval
        var endedUptime: TimeInterval?
        var series: [String: Series] = [:]
        var firstEvents: [String: Event] = [:]
        var events: Ring<Event>
        var workloads: [String: Bool] = [:]
        var workloadStarted: [String: TimeInterval] = [:]
        var workloadSeconds: [String: Double] = [:]
        var workloadTransitions: [String: Int] = [:]
        var conditions: [String: String] = [:]
        var droppedEvents = 0
        var droppedSeries = 0
        var droppedEventNames = 0
        var droppedWorkloads = 0
    }

    let isEnabled: Bool
    private let limits: Limits
    private let clock: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private let log = OSLog(subsystem: "com.adnan.augmentmereality", category: "ar-baseline")
    private let exportQueue = DispatchQueue(label: "com.adnan.augmentmereality.baseline-export", qos: .utility)
    private let runID = UUID().uuidString
    private let metadata: [String: String]
    private let outputDirectory: URL?
    private let automaticExport: Bool
    private var epochs: [Epoch] = []
    private var nextEpochID = 0
    private var droppedEpochs = 0
    private var droppedLateMeasurements = 0
    private var signpostWindow = -Double.infinity
    private var signpostStarts = 0
    private var exportPending = false
    private var exportAgain = false
    private var systemSamples: Ring<SystemSample>
    private var droppedSystemSamples = 0
    private var timer: DispatchSourceTimer?

    /// Injectable limits and clock make cadence, eviction and epoch attribution
    /// testable without ARKit or a device. Only the shared instance exports by default.
    init(
        enabled: Bool,
        limits: Limits = Limits(),
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        outputDirectory: URL? = nil,
        automaticExport: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        precondition(limits.epochs > 0 && limits.seriesPerEpoch > 0 && limits.samplesPerSeries > 0)
        precondition(limits.eventsPerEpoch > 0 && limits.eventNamesPerEpoch > 0 && limits.workloadsPerEpoch > 0)
        precondition(limits.signpostStartsPerSecond >= 0)
        precondition(limits.systemSamples > 0)
        isEnabled = enabled
        self.limits = limits
        self.clock = clock
        self.outputDirectory = outputDirectory
        self.automaticExport = automaticExport
        systemSamples = Ring(capacity: limits.systemSamples)
        metadata = Self.makeMetadata(environment: environment)
        if enabled && automaticExport {
            let timer = DispatchSource.makeTimerSource(queue: exportQueue)
            timer.schedule(deadline: .now() + 10, repeating: 30, leeway: .seconds(1))
            timer.setEventHandler { [weak self] in self?.export() }
            self.timer = timer
            timer.resume()
        }
    }

    deinit { timer?.cancel() }

    func beginEpoch(kind: String, generation: Int, at timestamp: TimeInterval? = nil) {
        guard isEnabled else { return }
        let now = timestamp ?? clock()
        lock.lock()
        if !epochs.isEmpty, epochs[epochs.count - 1].endedUptime == nil {
            epochs[epochs.count - 1].endedUptime = now
        }
        appendEpoch(kind: kind, generation: generation, at: now)
        addEvent("epoch_begin", details: kind, at: now, index: epochs.count - 1)
        lock.unlock()
        if automaticExport { export() }
    }

    func endEpoch(reason: String) {
        guard isEnabled else { return }
        lock.lock()
        if !epochs.isEmpty, epochs[epochs.count - 1].endedUptime == nil {
            let now = clock()
            addEvent("epoch_end", details: reason, at: now, index: epochs.count - 1)
            epochs[epochs.count - 1].endedUptime = now
        }
        lock.unlock()
        if automaticExport { export() }
    }

    func event(_ name: String, details: String = "") {
        guard isEnabled else { return }
        let now = clock()
        lock.lock()
        ensureEpoch(at: now)
        addEvent(name, details: details, at: now, index: epochs.count - 1)
        lock.unlock()
    }

    /// Call once per callback. Intervals describe delivery/scene-update cadence;
    /// they must not be relabelled as display presentation cadence.
    func observe(_ name: String, at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard isEnabled else { return }
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        ensureEpoch(at: now)
        let index = epochs.count - 1
        let key = bounded(name) + ".interval"
        guard ensureSeries(key, index: index) else { return }
        let intent = epochs[index].intentUptime
        guard timestamp.isFinite, timestamp >= intent else {
            epochs[index].series[key]!.invalidSamples += 1
            return
        }
        if let previous = epochs[index].series[key]!.previousObservation {
            guard timestamp > previous else {
                epochs[index].series[key]!.invalidSamples += 1
                return
            }
            epochs[index].series[key]!.add((timestamp - previous) * 1000, at: timestamp, intent: intent)
        }
        epochs[index].series[key]!.previousObservation = timestamp
        // Capture/render signposts are sampled to <=1 per second per series,
        // under a shared cap; the bounded cadence buffers still observe every call.
        if timestamp - (epochs[index].series[key]!.lastObservationSignpost ?? -Double.infinity) >= 1,
           takeSignpostSlot(at: now) {
            epochs[index].series[key]!.lastObservationSignpost = timestamp
            os_signpost(.event, log: log, name: "cadence_observation", "%{public}@ epoch=%d generation=%d uptime=%.6f", key, epochs[index].id, epochs[index].generation, timestamp)
        }
    }

    func measure(_ name: StaticString) -> Token? {
        guard isEnabled else { return nil }
        let now = clock()
        lock.lock()
        ensureEpoch(at: now)
        let epoch = epochs[epochs.count - 1]
        let signpostID: OSSignpostID? = takeSignpostSlot(at: now) ? OSSignpostID(log: log) : nil
        if let signpostID {
            os_signpost(.begin, log: log, name: name, signpostID: signpostID, "epoch=%d generation=%d", epoch.id, epoch.generation)
        }
        lock.unlock()
        return Token(epochID: epoch.id, generation: epoch.generation, startedAt: now, name: name, signpostID: signpostID)
    }

    func end(_ token: Token?) {
        guard isEnabled, let token else { return }
        let now = clock()
        if let signpostID = token.signpostID {
            os_signpost(.end, log: log, name: token.name, signpostID: signpostID, "epoch=%d generation=%d", token.epochID, token.generation)
        }
        lock.lock()
        defer { lock.unlock() }
        guard let index = epochs.firstIndex(where: { $0.id == token.epochID && $0.generation == token.generation }) else {
            droppedLateMeasurements += 1
            return
        }
        addSample(bounded(String(describing: token.name)) + ".duration", milliseconds: (now - token.startedAt) * 1000, at: now, index: index)
    }

    func sample(_ name: String, milliseconds: Double) {
        guard isEnabled else { return }
        let now = clock()
        lock.lock()
        ensureEpoch(at: now)
        addSample(bounded(name), milliseconds: milliseconds, at: now, index: epochs.count - 1)
        lock.unlock()
    }

    func sample(_ name: String, milliseconds: Double, originating token: Token?) {
        guard isEnabled, let token else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let index = epochs.firstIndex(where: { $0.id == token.epochID }) else {
            droppedLateMeasurements += 1
            return
        }
        addSample(bounded(name), milliseconds: milliseconds, at: clock(), index: index)
    }

    func condition(_ name: String, value: String) {
        guard isEnabled else { return }
        lock.lock()
        defer { lock.unlock() }
        ensureEpoch(at: clock())
        let index = epochs.count - 1
        let key = bounded(name)
        guard epochs[index].conditions[key] != nil || epochs[index].conditions.count < 32 else { return }
        epochs[index].conditions[key] = String(value.prefix(512))
    }

    func setWorkload(_ name: String, enabled: Bool) {
        guard isEnabled else { return }
        let now = clock()
        lock.lock()
        defer { lock.unlock() }
        ensureEpoch(at: now)
        let index = epochs.count - 1
        let key = bounded(name)
        guard epochs[index].workloads[key] != enabled else { return }
        guard epochs[index].workloads[key] != nil || epochs[index].workloads.count < limits.workloadsPerEpoch else {
            epochs[index].droppedWorkloads += 1
            return
        }
        if let start = epochs[index].workloadStarted.removeValue(forKey: key) {
            epochs[index].workloadSeconds[key, default: 0] += max(0, now - start)
        }
        if enabled { epochs[index].workloadStarted[key] = now }
        epochs[index].workloadTransitions[key, default: 0] += 1
        epochs[index].workloads[key] = enabled
        addEvent("workload_change", details: "\(key)=\(enabled)", at: now, index: index)
    }

    /// Coalesces requests; serialization, percentile sorting and disk IO happen
    /// on a utility queue. Each run overwrites one compact atomic JSON file.
    func export() {
        guard isEnabled else { return }
        lock.lock()
        guard !exportPending else { exportAgain = true; lock.unlock(); return }
        exportPending = true
        lock.unlock()
        exportQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.exportPending = false
                let again = self.exportAgain
                self.exportAgain = false
                self.lock.unlock()
                if again { self.export() }
            }
            do {
                let base = self.outputDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("baselines", isDirectory: true)
                guard let base else { return }
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.sortedKeys]
                self.sampleSystemResources()
                let data = try encoder.encode(self.snapshot())
                let url = base.appendingPathComponent("baseline-\(self.runID).json")
                try data.write(to: url, options: .atomic)
                os_log("Baseline exported: %{public}@", log: self.log, type: .info, url.path)
            } catch {
                os_log("Baseline export failed: %{public}@", log: self.log, type: .error, String(describing: error))
            }
        }
    }

    /// Called on the export queue; retains a bounded thermal/memory timeline so
    /// overwriting the JSON does not erase the sustained run's earlier observations.
    func sampleSystemResources() {
        guard isEnabled else { return }
        let now = clock()
        let resident = Self.residentMemoryBytes()
        let thermal = Self.thermalState(ProcessInfo.processInfo.thermalState)
        lock.lock()
        defer { lock.unlock() }
        if systemSamples.storage.count == limits.systemSamples { droppedSystemSamples += 1 }
        systemSamples.append(SystemSample(uptime: now, epochID: epochs.last?.endedUptime == nil ? epochs.last?.id : nil,
            generation: epochs.last?.generation, residentMemoryBytes: resident,
            processCPUSeconds: Self.processCPUSeconds(), processThermalState: thermal))
    }

    /// Internal for deterministic tests. Production calls this only on exportQueue.
    func snapshot() -> Snapshot {
        let now = clock()
        lock.lock()
        let captured = epochs
        let lostEpochs = droppedEpochs
        let lostMeasurements = droppedLateMeasurements
        let resources = systemSamples.ordered
        let lostSystemSamples = droppedSystemSamples
        lock.unlock()
        let summaries = captured.map { epoch in
            let series = epoch.series.keys.sorted().map { key -> SeriesSummary in
                let values = epoch.series[key]!
                let recent = values.recent.ordered
                return SeriesSummary(
                    name: key, unit: "milliseconds", totalCount: values.totalCount,
                    meanMilliseconds: values.totalCount > 0 ? values.sum / Double(values.totalCount) : nil,
                    minimumMilliseconds: values.minimum, maximumMilliseconds: values.maximum,
                    wholeEpochHistogram: values.histogram.summary,
                    recentSamples: Self.distribution(recent.map(\.value)),
                    startupFirstTenSeconds: Self.distribution(values.startup),
                    firstSampleUptime: values.firstSampleUptime, lastSampleUptime: values.lastSampleUptime,
                    sampleAgeMilliseconds: values.lastSampleUptime.map { max(0, now - $0) * 1000 },
                    recentWindowStartUptime: recent.first?.uptime,
                    invalidSamples: values.invalidSamples
                )
            }
            return EpochSummary(
                id: epoch.id, kind: epoch.kind, generation: epoch.generation,
                intentUptime: epoch.intentUptime, endedUptime: epoch.endedUptime,
                series: series, firstEventsByName: epoch.firstEvents,
                recentEvents: epoch.events.ordered, workloads: epoch.workloads,
                workloadActivity: Dictionary(uniqueKeysWithValues: epoch.workloads.map { name, enabled in
                        let active = epoch.workloadStarted[name].map { max(0, (epoch.endedUptime ?? now) - $0) } ?? 0
                        return (name, WorkloadSummary(enabled: enabled,
                            observedActiveSeconds: (epoch.workloadSeconds[name] ?? 0) + active,
                            transitions: epoch.workloadTransitions[name] ?? 0))
                    }),
                conditions: epoch.conditions,
                droppedEvents: epoch.droppedEvents, droppedSeries: epoch.droppedSeries,
                droppedEventNames: epoch.droppedEventNames, droppedWorkloads: epoch.droppedWorkloads
            )
        }
        return Snapshot(
            schemaVersion: 2, runID: runID, enabled: isEnabled,
            exportedAt: Date(), exportedUptime: now, metadata: metadata, limits: limits,
            epochs: summaries, droppedEpochs: lostEpochs, droppedLateMeasurements: lostMeasurements,
            residentMemoryBytes: Self.residentMemoryBytes(), processCPUSeconds: Self.processCPUSeconds(),
            processThermalState: Self.thermalState(ProcessInfo.processInfo.thermalState),
            recentSystemSamples: resources, droppedSystemSamples: lostSystemSamples
        )
    }

    private func appendEpoch(kind: String, generation: Int, at now: TimeInterval) {
        let workloads = epochs.last?.workloads ?? [:]
        if epochs.count == limits.epochs { epochs.removeFirst(); droppedEpochs += 1 }
        nextEpochID += 1
        epochs.append(Epoch(id: nextEpochID, kind: bounded(kind), generation: generation, intentUptime: now, events: Ring(capacity: limits.eventsPerEpoch), workloads: workloads,
            workloadStarted: Dictionary(uniqueKeysWithValues: workloads.filter(\.value).map { ($0.key, now) })))
    }

    private func ensureEpoch(at now: TimeInterval) {
        if epochs.isEmpty { appendEpoch(kind: "pre_camera", generation: 0, at: now) }
        else if epochs.last?.endedUptime != nil {
            appendEpoch(kind: "cameraInactive", generation: epochs.last?.generation ?? 0, at: now)
        }
    }

    private func ensureSeries(_ name: String, index: Int) -> Bool {
        if epochs[index].series[name] != nil { return true }
        guard epochs[index].series.count < limits.seriesPerEpoch else {
            epochs[index].droppedSeries += 1
            return false
        }
        epochs[index].series[name] = Series(recent: Ring(capacity: limits.samplesPerSeries))
        return true
    }

    private func addSample(_ name: String, milliseconds: Double, at now: TimeInterval, index: Int) {
        guard ensureSeries(name, index: index) else { return }
        let intent = epochs[index].intentUptime
        epochs[index].series[name]!.add(milliseconds, at: now, intent: intent)
    }

    private func addEvent(_ name: String, details: String, at now: TimeInterval, index: Int) {
        let key = bounded(name)
        let value = Event(name: key, details: String(details.prefix(512)), uptime: now, secondsSinceIntent: now - epochs[index].intentUptime, generation: epochs[index].generation)
        if epochs[index].events.storage.count == limits.eventsPerEpoch { epochs[index].droppedEvents += 1 }
        epochs[index].events.append(value)
        if epochs[index].firstEvents[key] == nil {
            if epochs[index].firstEvents.count < limits.eventNamesPerEpoch {
                epochs[index].firstEvents[key] = value
            } else {
                epochs[index].droppedEventNames += 1
            }
        }
        if takeSignpostSlot(at: now) {
            os_signpost(.event, log: log, name: "baseline_event", "%{public}@ %{public}@ epoch=%d generation=%d uptime=%.6f", value.name, value.details, epochs[index].id, value.generation, now)
        }
    }

    private func takeSignpostSlot(at now: TimeInterval) -> Bool {
        if now - signpostWindow >= 1 { signpostWindow = now; signpostStarts = 0 }
        guard signpostStarts < limits.signpostStartsPerSecond else { return false }
        signpostStarts += 1
        return true
    }

    private func bounded(_ value: String) -> String { String(value.prefix(96)) }

    private static func distribution(_ values: [Double]) -> Distribution {
        let sorted = values.sorted()
        func percentile(_ fraction: Double) -> Double? {
            guard !sorted.isEmpty else { return nil }
            return sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)]
        }
        return Distribution(
            count: values.count,
            meanMilliseconds: values.isEmpty ? nil : values.reduce(0, +) / Double(values.count),
            minimumMilliseconds: sorted.first, maximumMilliseconds: sorted.last,
            p95Milliseconds: percentile(0.95), p99Milliseconds: percentile(0.99)
        )
    }

    private static func makeMetadata(environment: [String: String]) -> [String: String] {
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release-like (verify scheme/configuration)"
        #endif
        var system = utsname()
        uname(&system)
        let machineCapacity = MemoryLayout.size(ofValue: system.machine)
        let machine = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: machineCapacity) { String(cString: $0) }
        }
        var result: [String: String] = [
            "bundle_identifier": Bundle.main.bundleIdentifier ?? "unmeasured",
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unmeasured",
            "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unmeasured",
            "compiled_configuration": configuration,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "device_machine": machine,
            "instrumentation": "enabled only with -ARBaselineMetrics; bounded signposts and buffers",
            "quantiles": "nearest-rank recent/startup; whole-epoch histogram upper bounds at 1ms resolution, >1000ms overflow explicit",
            "duration_semantics": "monotonic elapsed wall time; not CPU/GPU execution time",
            "capture_semantics": "ARSession delivery callback interval, not sensor exposure cadence",
            "captureDelivery.interval": "callback arrival uptime intervals (delivery cadence)",
            "captureTimestamp.interval": "ARFrame timestamp intervals as delivered by ARSession (capture timestamp cadence, not display presentation)",
            "sceneUpdateProxy.interval": "RealityKit scene-update callback intervals; presentation unmeasured",
            "render_semantics": "RealityKit scene-update interval proxy, not display presentation",
            "first_presented_hero": "unmeasured; correlate selected-asset render proxy with separate screen recording",
            "cpu_execution_time": "processCPUSeconds is cumulative process user+system CPU from getrusage, not per-subsystem or wall time",
            "gpu_execution_time": "Postprocess command buffer GPU samples GPU start/end on completed command buffers; entire buffer, not just pass or presentation; absent when detached/unavailable",
            "metric_kit_location": "Application Support/diagnostics (delayed, not per-run attribution)",
            "initial_process_thermal_state": thermalState(ProcessInfo.processInfo.thermalState),
            "experiment": ARBaselineExperiment.current.description,
            "build_source_commit": Bundle.main.object(forInfoDictionaryKey: "ARBaselineSourceCommit") as? String ?? "unmeasured",
            "build_source_hash": Bundle.main.object(forInfoDictionaryKey: "ARBaselineSourceHash") as? String ?? "unmeasured",
            "build_source_dirty": Bundle.main.object(forInfoDictionaryKey: "ARBaselineSourceDirty") as? String ?? "unmeasured",
            "build_configuration": Bundle.main.object(forInfoDictionaryKey: "ARBaselineBuildConfiguration") as? String ?? "unmeasured",
            "target_fps": ">=30 (presentation unmeasured)",
            "target_p95_interval_ms": "<=40",
            "target_thermal": "no serious state at 10 minutes; observe to 15 minutes"
        ]
        let fields = ["COMMIT", "ASSET", "DISTANCE_METERS", "BRIGHTNESS", "CHARGING", "INITIAL_THERMAL", "OBSERVED_WARMTH", "TRACE_LOCATION", "RUN_KIND"]
        for field in fields {
            result[field.lowercased()] = environment["AR_BASELINE_" + field].map { String($0.prefix(1024)) } ?? "unmeasured"
        }
        return result
    }

    private static func thermalState(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func processCPUSeconds() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private static func residentMemoryBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : nil
    }
}
