import Foundation

/// What kind of work the Mac is doing, in the order of how much cooling it needs.
enum WorkloadRegime: Int, Codable, CaseIterable, Comparable, Sendable, Identifiable {
    /// Browsing, writing, coding: power stays low.
    case light
    /// Short spikes that end by themselves, such as a photo filter or an export of one picture.
    case bursty
    /// A long, heavy load, such as a video export or a local language model.
    case sustained

    var id: Int { rawValue }

    static func < (a: WorkloadRegime, b: WorkloadRegime) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .light: return "Light"
        case .bursty: return "Bursty"
        case .sustained: return "Sustained"
        }
    }

    /// What the regime means for the fans, in one sentence.
    var explanation: String {
        switch self {
        case .light:
            return "Fans stay at minimum speed until the forecast passes \(Int(AdaptivePolicy.light.engageCelsius))°."
        case .bursty:
            return "Fans stay quiet through short bursts and speed up only if the load continues."
        case .sustained:
            return "Fans speed up before the heat builds, then hold steady."
        }
    }
}

/// The mean of the values from the last few seconds. Adding a value costs the same however many the
/// window holds.
struct RollingWindow {
    let span: TimeInterval
    private var samples: [(time: TimeInterval, value: Double)] = []
    private var first = 0
    private var sum = 0.0

    init(span: TimeInterval) {
        self.span = span
    }

    var count: Int { samples.count - first }
    var mean: Double? { count > 0 ? sum / Double(count) : nil }
    /// The mean, or the given value while the window is empty.
    func mean(or empty: Double) -> Double { count > 0 ? sum / Double(count) : empty }
    /// The oldest value the window still holds, with its time.
    var oldest: (time: TimeInterval, value: Double)? { count > 0 ? samples[first] : nil }
    /// The time between the oldest value and the newest.
    var covered: TimeInterval {
        guard let last = samples.last, count > 0 else { return 0 }
        return last.time - samples[first].time
    }

    mutating func add(_ value: Double, at time: TimeInterval) {
        guard value.isFinite else { return }
        // When the clock goes backward (after a date change), the window starts again.
        if let last = samples.last, time < last.time {
            self = RollingWindow(span: span)
        }
        samples.append((time, value))
        sum += value
        while first < samples.count, time - samples[first].time > span {
            sum -= samples[first].value
            first += 1
        }
        if first > samples.count / 2 {
            samples.removeFirst(first)
            first = 0
            // The running sum drifts after many additions and removals, so the window recomputes
            // it.
            sum = samples.reduce(0) { $0 + $1.value }
        }
    }
}

/// What this Mac draws at rest and at work, learned as it runs. Power is judged against this range,
/// because 30 watts is rest for one Mac and full load for another.
struct PowerScale: Codable, Equatable, Sendable {
    /// The range always counts as at least this wide, so noise at rest is not a load.
    static let minimumSpan: Double = 15

    var idle: Double
    var peak: Double

    init(idle: Double, peak: Double) {
        self.idle = idle
        self.peak = peak
    }

    /// A scale with only one reading.
    init(first watts: Double) {
        self.init(idle: watts, peak: watts)
    }

    var isValid: Bool {
        idle.isFinite && peak.isFinite && idle > 0 && peak >= idle && peak <= 2000
    }

    private var span: Double { max(peak - idle, Self.minimumSpan) }

    /// True once the Mac has been seen both at rest and at work.
    var hasRange: Bool { peak - idle >= Self.minimumSpan }

    /// Where a power sits between rest (0) and the most this Mac has drawn (1).
    func load(_ watts: Double) -> Double {
        min(max((watts - idle) / span, 0), 1)
    }

    /// Rest follows a lower reading at once and a higher one over hours. The peak follows a
    /// higher reading at once and a lower one over days.
    mutating func observe(restingWatts: Double, burstWatts: Double) {
        guard restingWatts.isFinite, burstWatts.isFinite, restingWatts > 0 else { return }
        idle = restingWatts < idle ? restingWatts : idle + (restingWatts - idle) * 0.0003
        peak = burstWatts > peak ? burstWatts : peak - (peak - max(burstWatts, idle)) * 0.00002
    }
}

/// Decides the regime from how hard the Mac works over 5 and 30 seconds and from what the open
/// apps are known for. It is a small decision tree, so each decision can be read and tested.
struct RegimeDetector: Equatable {
    /// How long the load must stay lower before the regime steps down. A model that waits
    /// between two prompts, or a person between two edits, does not end the regime.
    static let hold: TimeInterval = 20
    /// The share of this Mac's range that counts as working hard.
    static let highLoad = 0.5
    /// When an app known for the regime is open, less load is enough.
    static let hintedLoad = 0.35

    private(set) var regime: WorkloadRegime = .light
    private var lowerSince: TimeInterval?

    static func classify(load5: Double, load30: Double, hint: WorkloadRegime?) -> WorkloadRegime {
        if load30 >= highLoad { return .sustained }
        if hint == .sustained, load5 >= hintedLoad { return .sustained }
        if load5 >= highLoad { return .bursty }
        if hint == .bursty, load5 >= hintedLoad { return .bursty }
        return .light
    }

    /// A higher regime takes effect at once. A lower one takes effect after `hold`.
    mutating func update(load5: Double, load30: Double, hint: WorkloadRegime?, at time: TimeInterval) -> WorkloadRegime {
        let measured = Self.classify(load5: load5, load30: load30, hint: hint)
        if measured >= regime {
            regime = measured
            lowerSince = nil
        } else if let since = lowerSince, time >= since {
            if time - since >= Self.hold {
                regime = measured
                lowerSince = nil
            }
        } else {
            lowerSince = time
        }
        return regime
    }
}

/// Forecasts how far the temperature moves in the next 15 seconds, from the temperature, its
/// slope, the load, and the fans' speed. It is a ridge regression fitted to this Mac as the
/// Mac runs (recursive least squares), so it keeps its coefficients and no history of readings.
struct ThermalForecaster: Codable, Equatable, Sendable {
    static let horizon: TimeInterval = 15
    /// Until the forecaster has learned from this many readings, the forecast continues the slope.
    static let warmUp = 90
    /// A forecast outside this range of the present temperature is not believed.
    static let plausibleRise: ClosedRange<Double> = -15...25
    /// The least and the most (in degrees) that the controller believes full fans cool the Mac
    /// within the horizon, whatever it has learned.
    static let fanEffectRange: ClosedRange<Double> = 2...10
    static let defaultFanEffect: Double = 4
    private static let size = 6
    private static let forgetting = 0.998
    private static let fanIndex = 4
    private static let fanHeatIndex = 5

    private(set) var weights: [Double]
    private var covariance: [Double]
    private(set) var updates: Int
    /// How far off each forecast has been lately, as a mean of squared degrees: the learned one,
    /// and the slope carried on. Each answer scores both before the forecaster learns from it.
    private(set) var learnedSquare: Double?
    private(set) var carriedSquare: Double?
    /// How many answers the two averages look back over.
    private static let scoreSpan = 300.0

    /// The readings that wait for their answer, which is the temperature 15 seconds later.
    private var pending: [Pending] = []
    private var firstPending = 0

    private struct Pending: Equatable {
        let time: TimeInterval
        let celsius: Double
        let features: [Double]
        /// The learned forecast made for this reading, or nil while the forecaster was not warm.
        let learned: Double?
    }

    private enum CodingKeys: String, CodingKey {
        case weights, covariance, updates, learnedSquare, carriedSquare
    }

    init() {
        weights = Array(repeating: 0, count: Self.size)
        covariance = Self.identity(scaledBy: 100)
        updates = 0
    }

    var isWarm: Bool { updates >= Self.warmUp }

    /// The learned forecast's share of the forecast, from 0 to 1. The rest is the slope carried
    /// on. Each has a share in proportion to how close it has lately been, so the slope leads on a
    /// Mac the forecaster has only just met and for a while after the Mac changes, and the learned
    /// forecast leads once it has settled.
    var learnedShare: Double {
        guard isWarm, let learnedSquare, let carriedSquare else { return 0 }
        let learned = 1 / max(learnedSquare, 0.01), carried = 1 / max(carriedSquare, 0.01)
        return learned / (learned + carried)
    }

    /// False for stored numbers that cannot be a forecaster, which then starts again.
    var isValid: Bool {
        weights.count == Self.size && covariance.count == Self.size * Self.size && updates >= 0
            && weights.allSatisfy(\.isFinite) && covariance.allSatisfy(\.isFinite)
            && (learnedSquare ?? 0).isFinite && (carriedSquare ?? 0).isFinite
    }

    /// The last feature is the fans' speed times the temperature, as air takes more heat from a hot
    /// Mac than from a cool one.
    static func features(celsius: Double, slope: Double, load: Double, fanFraction: Double) -> [Double] {
        let heat = (celsius - 50) / 50
        let fans = min(max(fanFraction, 0), 1)
        return [1, heat, min(max(slope, -2), 2), min(max(load, 0), 1), fans, fans * heat]
    }

    /// How far full fans cool the Mac within the horizon at a temperature, in degrees.
    func fanEffect(celsius: Double) -> Double {
        let share = learnedShare
        guard share > 0 else { return Self.defaultFanEffect }
        let learned = -(weights[Self.fanIndex] + weights[Self.fanHeatIndex] * (celsius - 50) / 50)
        guard learned.isFinite else { return Self.defaultFanEffect }
        // What was learned about the fans counts as far as the learned forecast does.
        let effect = share * learned + (1 - share) * Self.defaultFanEffect
        return min(max(effect, Self.fanEffectRange.lowerBound), Self.fanEffectRange.upperBound)
    }

    /// The change in temperature expected over the horizon, in degrees.
    func rise(features: [Double]) -> Double {
        guard features.count == Self.size else { return 0 }
        let carried = Self.plausible(Self.carriedRise(features: features))
        let learned = Self.plausible(Self.learnedRise(weights: weights, features: features))
        let share = learnedShare
        guard share > 0, learned.isFinite else { return carried }
        return share * learned + (1 - share) * carried
    }

    private static func learnedRise(weights: [Double], features: [Double]) -> Double {
        zip(weights, features).reduce(0) { $0 + $1.0 * $1.1 }
    }

    /// The slope of the last few seconds, carried on over the horizon.
    private static func carriedRise(features: [Double]) -> Double {
        features[2] * horizon
    }

    private static func plausible(_ rise: Double) -> Double {
        min(max(rise, plausibleRise.lowerBound), plausibleRise.upperBound)
    }

    /// Scores both forecasts that were made for a reading against its answer. The scores start
    /// once the forecaster is warm, because its first forecasts say nothing about its later ones.
    private mutating func score(_ reading: Pending, target: Double) {
        guard let forecast = reading.learned, target.isFinite, abs(target) <= 60 else { return }
        let learned = target - forecast
        let carried = target - Self.plausible(Self.carriedRise(features: reading.features))
        guard learned.isFinite, carried.isFinite else { return }
        learnedSquare = learnedSquare.map { $0 + (learned * learned - $0) / Self.scoreSpan } ?? learned * learned
        carriedSquare = carriedSquare.map { $0 + (carried * carried - $0) / Self.scoreSpan } ?? carried * carried
    }

    /// Takes a reading. The reading from one horizon ago now has its answer, and the forecaster
    /// learns from that pair.
    mutating func observe(features: [Double], celsius: Double, at time: TimeInterval) {
        guard features.count == Self.size, celsius.isFinite, features.allSatisfy(\.isFinite) else { return }
        if let last = pending.last, time < last.time {
            pending.removeAll()
            firstPending = 0
        }
        while firstPending < pending.count, time - pending[firstPending].time >= Self.horizon {
            let old = pending[firstPending]
            firstPending += 1
            // A reading whose answer came far too late (e.g. after sleep) teaches nothing.
            if time - old.time <= Self.horizon + 5 {
                score(old, target: celsius - old.celsius)
                learn(features: old.features, target: celsius - old.celsius)
            }
        }
        if firstPending > pending.count / 2 {
            pending.removeFirst(firstPending)
            firstPending = 0
        }
        let learned = isWarm ? Self.plausible(Self.learnedRise(weights: weights, features: features)) : nil
        pending.append(Pending(time: time, celsius: celsius, features: features, learned: learned))
    }

    /// One step of recursive least squares with forgetting.
    private mutating func learn(features x: [Double], target: Double) {
        guard target.isFinite, abs(target) <= 60 else { return }
        let n = Self.size
        var px = Array(repeating: 0.0, count: n)
        for row in 0..<n {
            for column in 0..<n {
                px[row] += covariance[row * n + column] * x[column]
            }
        }
        let denominator = Self.forgetting + zip(x, px).reduce(0) { $0 + $1.0 * $1.1 }
        guard denominator.isFinite, denominator > 1e-9 else { return }
        let error = target - zip(weights, x).reduce(0) { $0 + $1.0 * $1.1 }
        for index in 0..<n {
            weights[index] += px[index] / denominator * error
        }
        // The covariance is symmetric, so x'P is the same vector as Px.
        for row in 0..<n {
            for column in 0..<n {
                let value = (covariance[row * n + column] - px[row] * px[column] / denominator) / Self.forgetting
                covariance[row * n + column] = min(max(value, -1e6), 1e6)
            }
        }
        updates += 1
        if !isValid {
            self = ThermalForecaster()
        }
    }

    private static func identity(scaledBy scale: Double) -> [Double] {
        var matrix = Array(repeating: 0.0, count: size * size)
        for index in 0..<size {
            matrix[index * size + index] = scale
        }
        return matrix
    }
}

/// What the controller weighs in one regime.
struct AdaptivePolicy: Equatable, Sendable {
    /// The forecast above which heat starts to count against a quiet fan.
    var engageCelsius: Double
    /// The share of the fan's range that is held whatever the forecast says.
    var floor: Double
    /// What a unit of fan speed costs, against a degree of heat.
    var quiet: Double
    /// The fastest the speed may rise and fall, in RPM a second. An ear hears a jump in pitch
    /// far sooner than it hears steady air.
    var riseRPM: Double
    var fallRPM: Double

    /// Light work counts heat only from where the safety line starts. A Mac can rest warmer than any
    /// lower number, and its fans would then run for work that needs none.
    static let light = AdaptivePolicy(
        engageCelsius: AdaptiveController.safetyFloor.lowerBound, floor: 0, quiet: 0.6, riseRPM: 150, fallRPM: 100
    )
    /// While a burst is short, only the ceiling counts, so the Mac's mass absorbs the burst.
    static let soak = AdaptivePolicy(engageCelsius: AdaptiveController.ceilingCelsius, floor: 0, quiet: 0.6, riseRPM: 150, fallRPM: 100)
    static let bursty = AdaptivePolicy(engageCelsius: 75, floor: 0, quiet: 0.4, riseRPM: 150, fallRPM: 100)
    static let sustained = AdaptivePolicy(engageCelsius: 70, floor: 0.3, quiet: 0.15, riseRPM: 300, fallRPM: 100)

    /// - Parameter load15: the load over 15 seconds, which says whether a burst has lasted.
    static func policy(for regime: WorkloadRegime, load15: Double) -> AdaptivePolicy {
        switch regime {
        case .light: return .light
        case .bursty: return load15 >= RegimeDetector.highLoad ? .bursty : .soak
        case .sustained: return .sustained
        }
    }
}

/// What the adaptive controller sees and asks for at one moment.
struct AdaptiveState: Equatable, Sendable {
    var regime: WorkloadRegime
    /// The power the Mac draws, or nil on a Mac that does not report it.
    var watts: Double?
    /// The hotter of the CPU's and the GPU's average temperature.
    var celsius: Double
    /// The temperature expected in 15 seconds at the speed asked for.
    var forecastCelsius: Double
    /// The share of each fan's range that is asked for, from 0 to 1.
    var fraction: Double
    /// False until AirFlow has seen this Mac at rest and at work, and the forecaster has
    /// learned from enough readings.
    var isLearned: Bool
}

/// The predictive controller. Every reading, it forecasts the temperature for each speed it
/// could choose, weighs heat against noise as the regime says, and takes the cheapest. Then it
/// limits how fast the speed may change and how soon it may fall.
struct AdaptiveController {
    /// The temperature a long load is held under, so the chip does not slow itself down.
    static let ceilingCelsius: Double = 85
    /// Whatever was learned and whatever the regime, the fans are never asked for less than
    /// this line gives at the present temperature: nothing at 80°, full speed at 92°.
    static let safetyFloor: ClosedRange<Double> = 80...92
    /// A change smaller than this share of the range is not worth a change in pitch.
    static let deadband = 0.04
    /// How long a lower speed must be wanted before the fans fall, so they do not cycle between two
    /// prompts or two edits.
    static let fallHold: TimeInterval = 20
    private static let candidates = 21
    private static let heatWeight = 1.0
    private static let ceilingWeight = 10.0
    private static let slewWeight = 0.2

    private(set) var forecaster: ThermalForecaster
    private(set) var scale: PowerScale?
    private(set) var detector = RegimeDetector()
    private(set) var state: AdaptiveState?

    private var power5 = RollingWindow(span: 5)
    private var power15 = RollingWindow(span: 15)
    private var power30 = RollingWindow(span: 30)
    private var recent = RollingWindow(span: 6)
    private var fraction = 0.0
    private var lastStep: TimeInterval?
    private var lowerSince: TimeInterval?

    init(forecaster: ThermalForecaster = ThermalForecaster(), scale: PowerScale? = nil) {
        self.forecaster = forecaster.isValid ? forecaster : ThermalForecaster()
        self.scale = scale.flatMap { $0.isValid ? $0 : nil }
    }

    /// The lowest fan speed asked for at a temperature, whatever else is decided.
    static func safetyFraction(celsius: Double) -> Double {
        min(max((celsius - safetyFloor.lowerBound) / (safetyFloor.upperBound - safetyFloor.lowerBound), 0), 1)
    }

    /// Takes one reading and decides. Returns nil and clears its speed when the Mac reports neither
    /// a CPU nor a GPU temperature, as there is nothing to decide from.
    @discardableResult
    mutating func step(snapshot: ThermalSnapshot, hint: WorkloadRegime?) -> AdaptiveState? {
        let time = snapshot.date.timeIntervalSinceReferenceDate
        let parts = [SensorGroup.cpu, .gpu].compactMap { snapshot.summary(of: $0)?.average }
        guard let celsius = parts.max(), celsius.isFinite else {
            state = nil
            fraction = 0
            lastStep = nil
            return nil
        }

        // Power, as a share of what this Mac draws between rest and full load.
        var load5 = 0.0, load15 = 0.0, load30 = 0.0
        if let watts = snapshot.systemWatts, watts.isFinite {
            power5.add(watts, at: time)
            power15.add(watts, at: time)
            power30.add(watts, at: time)
            var known = scale ?? PowerScale(first: watts)
            known.observe(restingWatts: power30.mean(or: watts), burstWatts: power5.mean(or: watts))
            scale = known
            load5 = known.load(power5.mean(or: watts))
            load15 = known.load(power15.mean(or: watts))
            // A window that only just started cannot show that a load has lasted.
            if power30.covered >= power30.span / 2 {
                load30 = known.load(power30.mean(or: watts))
            }
        }
        let regime = detector.update(load5: load5, load30: load30, hint: hint, at: time)

        // The slope over the last few seconds, in degrees a second.
        recent.add(celsius, at: time)
        var slope = 0.0
        if let oldest = recent.oldest, time - oldest.time >= 1 {
            slope = (celsius - oldest.value) / (time - oldest.time)
        }
        let fans = snapshot.fans.filter(\.hasUsableRange)
        let measured = fans.isEmpty ? 0 : fans.map(\.fraction).reduce(0, +) / Double(fans.count)
        let features = ThermalForecaster.features(celsius: celsius, slope: slope, load: load5, fanFraction: measured)
        forecaster.observe(features: features, celsius: celsius, at: time)

        // The forecast for each speed is the forecast at the current speed, moved by what the fans
        // are known to do.
        let rise = forecaster.rise(features: features)
        let effect = forecaster.fanEffect(celsius: celsius)
        func forecast(_ candidate: Double) -> Double {
            celsius + rise - effect * (candidate - measured)
        }
        let policy = AdaptivePolicy.policy(for: regime, load15: load15)
        var best = fraction
        var bestCost = Double.infinity
        for step in 0..<Self.candidates {
            let candidate = Double(step) / Double(Self.candidates - 1)
            let predicted = forecast(candidate)
            let heat = max(0, predicted - policy.engageCelsius)
            let over = max(0, predicted - Self.ceilingCelsius)
            let noise = candidate * 10
            let change = (candidate - fraction) * 10
            let cost = Self.heatWeight * heat * heat + Self.ceilingWeight * over * over
                + policy.quiet * noise * noise + Self.slewWeight * change * change
            if cost < bestCost {
                bestCost = cost
                best = candidate
            }
        }

        let safety = Self.safetyFraction(celsius: celsius)
        let lowest = max(policy.floor, safety)
        var wanted = max(best, lowest)
        // A small change is not worth a change in pitch. The lowest speed is still reached exactly.
        if wanted > lowest, abs(wanted - fraction) < Self.deadband {
            wanted = max(fraction, lowest)
        }

        // A fall waits until a lower speed has been wanted for a while.
        if wanted < fraction {
            let since = lowerSince ?? time
            lowerSince = since
            if time - since < Self.fallHold || time < since {
                wanted = fraction
            }
        } else {
            lowerSince = nil
        }

        // The speed changes no faster than the regime allows.
        let elapsed = min(max(lastStep.map { time - $0 } ?? 1, 0.25), 5)
        let range = fans.isEmpty ? 4000 : fans.map { $0.maximumRPM - $0.minimumRPM }.reduce(0, +) / Double(fans.count)
        let up = policy.riseRPM / max(range, 1) * elapsed
        let down = policy.fallRPM / max(range, 1) * elapsed
        var next = min(max(wanted, fraction - down), fraction + up)
        // The safety line is not slowed down.
        next = min(max(next, safety), 1)
        fraction = next
        lastStep = time

        let decided = AdaptiveState(
            regime: regime, watts: snapshot.systemWatts, celsius: celsius,
            forecastCelsius: forecast(next), fraction: next,
            isLearned: forecaster.isWarm && (snapshot.systemWatts == nil || scale?.hasRange == true)
        )
        state = decided
        return decided
    }
}

/// What the adaptive controller keeps between launches: the fitted forecaster and the Mac's
/// range of power. It holds no reading and no name of an app.
struct AdaptiveMemory: Codable, Equatable {
    var forecaster: ThermalForecaster
    var scale: PowerScale?
}

/// What an app is known for, kept by the user: its identifier, its name, and its regime.
struct AppWorkload: Codable, Equatable, Identifiable, Sendable {
    var bundleID: String
    var name: String
    var regime: WorkloadRegime

    var id: String { bundleID }
}

/// The apps AirFlow knows by default. A user's own entry for an app replaces these.
enum KnownWorkloads {
    static let regimes: [String: WorkloadRegime] = [
        // Local language models and rendering are long, heavy loads.
        "com.electron.ollama": .sustained,
        "ai.elementlabs.lmstudio": .sustained,
        "com.apple.FinalCut": .sustained,
        "com.apple.Compressor": .sustained,
        "com.apple.motionapp": .sustained,
        "com.adobe.PremierePro.25": .sustained,
        "com.adobe.PremierePro.26": .sustained,
        "com.adobe.AfterEffects.application": .sustained,
        "com.adobe.ame.application.25": .sustained,
        "com.blackmagic-design.DaVinciResolve": .sustained,
        "com.blackmagic-design.DaVinciResolveLite": .sustained,
        "fr.handbrake.HandBrake": .sustained,
        "org.blenderfoundation.blender": .sustained,
        "com.diffusionbee.diffusionbee": .sustained,
        // Photo editing and building code are short spikes.
        "com.adobe.LightroomClassicCC7": .bursty,
        "com.adobe.mas.lightroomCC": .bursty,
        "com.adobe.Photoshop": .bursty,
        "com.pixelmatorteam.pixelmator.x": .bursty,
        "com.seriflabs.affinityphoto2": .bursty,
        "com.apple.Photos": .bursty,
        "com.captureone.captureone16": .bursty,
        "com.apple.dt.Xcode": .bursty,
    ]
}

/// Finds what the open apps are known for. The answer only makes the detector quicker to choose a
/// regime that needs more cooling. An app that is open and idle changes nothing.
enum WorkloadHint {
    static func hint(running: some Sequence<String>, workloads: [String: WorkloadRegime]) -> WorkloadRegime? {
        var hint: WorkloadRegime?
        for bundleID in running {
            guard let regime = workloads[bundleID] ?? KnownWorkloads.regimes[bundleID], regime != .light else { continue }
            hint = max(hint ?? regime, regime)
            if hint == .sustained { break }
        }
        return hint
    }
}
