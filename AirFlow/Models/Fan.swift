import Foundation

/// One fan as the SMC reports it.
struct Fan: Identifiable, Equatable, Sendable {
    let index: Int
    var name: String
    var minimumRPM: Double
    var maximumRPM: Double
    var currentRPM: Double
    var targetRPM: Double
    /// True while something other than the system holds the fan's speed.
    var isManual: Bool

    var id: Int { index }

    var hasUsableRange: Bool { maximumRPM > minimumRPM }

    /// Where the current speed sits between the minimum and the maximum, from 0 to 1.
    var fraction: Double { fraction(of: currentRPM) }

    func fraction(of rpm: Double) -> Double {
        guard hasUsableRange else { return 0 }
        return min(max((rpm - minimumRPM) / (maximumRPM - minimumRPM), 0), 1)
    }

    func rpm(atFraction fraction: Double) -> Double {
        minimumRPM + min(max(fraction, 0), 1) * (maximumRPM - minimumRPM)
    }

    func clamp(_ rpm: Double) -> Double {
        min(max(rpm, minimumRPM), maximumRPM)
    }

    static func name(index: Int, count: Int) -> String {
        switch count {
        case 1: return "Fan"
        case 2: return index == 0 ? "Left Fan" : "Right Fan"
        default: return "Fan \(index + 1)"
        }
    }
}
