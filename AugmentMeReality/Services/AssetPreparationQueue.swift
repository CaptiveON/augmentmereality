import Foundation

/// A single decoder with bounded admission and an LRU template cache. Demand is
/// just resource identity; decoded objects never accumulate in a pending queue.
/// Cost is an explicit caller estimate, not a measurement of resident memory.
@MainActor
final class AssetPreparationQueue<Value> {
    struct Limits {
        var queued = 8
        var cached = 3
        var cacheCost = 24 * 1_024 * 1_024
    }

    private struct Entry {
        var value: Value
        var cost: Int
        var lastUse: UInt64
    }

    private let limits: Limits
    private let load: (String) async -> Value?
    private let cost: (String) -> Int
    var onCompletion: ((String, Bool) -> Void)?
    private var cache: [String: Entry] = [:]
    private var useCounter: UInt64 = 0
    private var demand: Set<String> = []
    private var priority: String?
    private var delivered: Set<String> = []
    private(set) var failed: Set<String> = []
    private(set) var queued: [String] = []
    private(set) var inFlight: String?
    private(set) var isActive = true
    // Oversized assets can be cloned during the synchronous completion callback
    // without admitting their template to the resident cache.
    private var delivery: (name: String, value: Value)?

    init(limits: Limits = Limits(), cost: @escaping (String) -> Int,
         load: @escaping (String) async -> Value?) {
        precondition(limits.queued > 0 && limits.cached >= 0 && limits.cacheCost >= 0)
        self.limits = limits
        self.cost = cost
        self.load = load
    }

    var cachedNames: Set<String> { Set(cache.keys) }
    var cachedCost: Int { cache.values.reduce(0) { $0 + $1.cost } }

    func contains(_ name: String) -> Bool {
        cache[name] != nil || delivery?.name == name
    }

    func value(for name: String) -> Value? {
        if delivery?.name == name { return delivery?.value }
        guard var entry = cache[name] else { return nil }
        delivered.insert(name)
        useCounter &+= 1
        entry.lastUse = useCounter
        cache[name] = entry
        return entry.value
    }

    /// Replacing demand invalidates obsolete queued work before it can start.
    /// A non-cancellable SDK decode may finish, but cannot publish to a hidden
    /// or irrelevant scene. Already cloned live content is owned by the scene.
    func setDemand(_ names: Set<String>, active: Bool, priority: String? = nil) {
        demand = names
        self.priority = priority.flatMap { names.contains($0) ? $0 : nil }
        isActive = active
        delivered.formIntersection(names)
        queued.removeAll { !active || !names.contains($0) }
        pump()
    }

    /// A cache miss while constructing content means a new clone is needed,
    /// even if an earlier clone of this resource was already delivered.
    func request(_ name: String) {
        guard !contains(name), !failed.contains(name) else { return }
        demand.insert(name)
        delivered.remove(name)
        pump()
    }

    func releaseCachedTemplates() {
        cache.removeAll()
        // Do not clear delivered: evicting an unused template must not decode
        // it again while its live clone is still being rendered.
    }

    private func pump() {
        guard isActive else { return }
        // A newly selected hero displaces queued, lower-priority identifiers.
        // Already running SDK work finishes under its decoder deadline.
        if let priority, !contains(priority), !delivered.contains(priority),
           !failed.contains(priority), priority != inFlight {
            queued.removeAll { $0 == priority }
            queued.insert(priority, at: 0)
            queued = Array(queued.prefix(limits.queued))
        }
        let candidates = demand.subtracting(delivered).subtracting(failed)
            .filter { !contains($0) && $0 != inFlight && !queued.contains($0) }
            .sorted()
        queued.append(contentsOf: candidates.prefix(max(0, limits.queued - queued.count)))
        guard inFlight == nil, !queued.isEmpty else { return }
        let name = queued.removeFirst()
        inFlight = name
        Task { [weak self, load] in
            let value = await load(name)
            self?.complete(name, value: value)
        }
    }

    private func complete(_ name: String, value: Value?) {
        // Keep the in-flight slot occupied through the callback: callbacks can
        // request more templates, but cannot create concurrent decoders.
        guard inFlight == name else { return }
        if value == nil { failed.insert(name) }
        if isActive && demand.contains(name) {
            if let value {
                insert(value, for: name)
                delivery = (name, value)
            }
            delivered.insert(name)
            onCompletion?(name, value != nil)
            delivery = nil
        }
        inFlight = nil
        pump()
    }

    private func insert(_ value: Value, for name: String) {
        let estimate = max(0, cost(name))
        guard limits.cached > 0, estimate <= limits.cacheCost else { return }
        while !cache.isEmpty && (cache.count >= limits.cached
            || cachedCost > limits.cacheCost - estimate) {
            guard let oldest = cache.min(by: { $0.value.lastUse < $1.value.lastUse })?.key else { break }
            cache.removeValue(forKey: oldest)
        }
        useCounter &+= 1
        cache[name] = Entry(value: value, cost: estimate, lastUse: useCounter)
    }
}
