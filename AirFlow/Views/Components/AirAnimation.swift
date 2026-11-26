import AppKit
import Lottie
import SwiftUI

private struct AirReduceMotionKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    /// If this value is set, drawn animations use it instead of the system's Reduce Motion
    /// setting. The machine that runs the tests chooses the system setting, so a test sets this.
    var airReduceMotion: Bool? {
        get { self[AirReduceMotionKey.self] }
        set { self[AirReduceMotionKey.self] = newValue }
    }
}

/// Drawn animations have one entry point: a bundled Lottie file in a single tint. A one-shot draws
/// once and holds its still frame. A loop repeats at a rate the caller can change while it runs.
/// Nothing moves while `isActive` is false or Reduce Motion is on.
struct AirAnimation: View {
    let name: String
    var loops = false
    var isActive = true
    /// How fast a loop's time runs. 1 plays the file as drawn, and 0 holds it still.
    var speed: Double = 1
    var tint: Color = Palette.accent
    /// The VoiceOver label. Without one the animation is decorative and hidden.
    var label: String?

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.airReduceMotion) private var reduceMotionOverride

    var body: some View {
        let player = AnimationPlayer(
            name: name,
            playback: Self.playback(
                loops: loops, isActive: isActive, speed: speed, reduceMotion: reduceMotionOverride ?? systemReduceMotion
            ),
            tint: tint
        )
        .allowsHitTesting(false)
        if let label {
            player
                .accessibilityElement()
                .accessibilityLabel(label)
                .accessibilityAddTraits(.isImage)
        } else {
            player.accessibilityHidden(true)
        }
    }

    static func playback(loops: Bool, isActive: Bool, speed: Double, reduceMotion: Bool) -> AnimationSurface.Playback {
        if reduceMotion { return .still }
        guard isActive else { return .idle }
        guard loops else { return .once }
        // Small changes in speed are not worth a change to the layer's clock.
        return .loop(speed: (max(speed, 0) * 20).rounded() / 20)
    }
}

private struct AnimationPlayer: NSViewRepresentable {
    let name: String
    let playback: AnimationSurface.Playback
    let tint: Color

    func makeNSView(context: Context) -> AnimationSurface {
        AnimationSurface(name: name)
    }

    func updateNSView(_ surface: AnimationSurface, context: Context) {
        surface.setTint(NSColor(tint))
        surface.setPlayback(playback)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AnimationSurface, context: Context) -> CGSize? {
        let side = min(proposal.width ?? IconSize.illustration, proposal.height ?? IconSize.illustration)
        return CGSize(width: side, height: side)
    }

    static func dismantleNSView(_ surface: AnimationSurface, coordinator: ()) {
        surface.setPlayback(.idle)
    }
}

/// The AppKit view under `AirAnimation`. It owns one Lottie view, played on Lottie's Core
/// Animation engine, so the render server does the drawing and the app does no work per frame.
final class AnimationSurface: NSView {
    enum Playback: Equatable {
        /// The surface is off screen. Whatever frame is showing stays, and nothing runs.
        case idle
        /// Only the still frame for Reduce Motion.
        case still
        /// From the first frame to the still frame once.
        case once
        case loop(speed: Double)
    }

    private let player: LottieAnimationView
    private let stillFrame: AnimationFrameTime
    private(set) var playback: Playback = .idle
    private var tint: NSColor?
    private var isLooping = false

    init(name: String) {
        let animation = AnimationLibrary.animation(named: name)
        player = LottieAnimationView(animation: animation, configuration: LottieConfiguration(renderingEngine: .coreAnimation))
        stillFrame = animation?.frameTime(forMarker: Animations.stillMarker) ?? 0
        super.init(frame: .zero)
        wantsLayer = true
        player.contentMode = .scaleAspectFit
        player.backgroundBehavior = .pauseAndRestore
        player.autoresizingMask = [.width, .height]
        player.frame = bounds
        player.currentFrame = stillFrame
        addSubview(player)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        player.frame = bounds
    }

    func setPlayback(_ new: Playback) {
        guard new != playback else { return }
        playback = new
        switch new {
        case .idle:
            setClock(0)
        case .still:
            isLooping = false
            player.stop()
            setClock(1)
            player.currentFrame = stillFrame
        case .once:
            isLooping = false
            setClock(1)
            player.play(fromFrame: 0, toFrame: stillFrame, loopMode: .playOnce)
        case .loop(let speed):
            if !isLooping {
                isLooping = true
                setClock(1)
                player.loopMode = .loop
                player.play()
            }
            setClock(speed)
        }
    }

    func setTint(_ color: NSColor) {
        guard color != tint else { return }
        tint = color
        applyTint()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    /// The speed of this view's layer scales the time of every animation beneath it. Moving the
    /// layer's time origin to now keeps the drawing where it is when the speed changes.
    private func setClock(_ speed: Double) {
        guard let layer, Double(layer.speed) != speed else { return }
        let now = CACurrentMediaTime()
        let parentTime = layer.superlayer?.convertTime(now, from: nil) ?? now
        let localTime = layer.convertTime(now, from: nil)
        layer.speed = Float(speed)
        layer.timeOffset = localTime
        layer.beginTime = parentTime
    }

    private func applyTint() {
        guard let tint else { return }
        var resolved = tint
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = tint.usingColorSpace(.sRGB) ?? tint
        }
        let color = LottieColor(
            r: Double(resolved.redComponent), g: Double(resolved.greenComponent),
            b: Double(resolved.blueComponent), a: Double(resolved.alphaComponent)
        )
        for keypath in ["**.Stroke 1.Color", "**.Fill 1.Color"] {
            player.setValueProvider(ColorValueProvider(color), keypath: AnimationKeypath(keypath: keypath))
        }
    }
}

/// Decodes each bundled animation once.
enum AnimationLibrary {
    private static var cache: [String: LottieAnimation] = [:]
    private static let lock = NSLock()

    static func animation(named name: String) -> LottieAnimation? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let animation = try? LottieAnimation.from(data: data)
        else { return nil }
        cache[name] = animation
        return animation
    }
}

/// The mark turns at a rate that follows the fan's speed.
struct Rotor: View {
    let fan: Fan?
    var size: CGFloat = IconSize.rotor
    var isActive = true
    var tint: Color = .primary
    @Environment(\.airRainbow) private var isRainbow

    /// Turns per second at a fan's minimum and maximum speed. A real fan turns far too fast to
    /// read, so the drawing maps the fan's range onto speeds the eye can compare.
    static let slowest: Double = 0.35
    static let fastest: Double = 2.75
    /// Below this the fan is stopped.
    static let stoppedRPM: Double = 100

    var body: some View {
        if isRainbow {
            // The rotor is the stencil, and the rainbow shows through it.
            // The rainbow runs outward in rings: the hub is one color, the blades step through the
            // others, and the housing comes back to the hub's color.
            RadialGradient(stops: Palette.rainbowRings, center: .center, startRadius: 0, endRadius: size / 2)
                .mask {
                    ZStack {
                        AirAnimation(name: Animations.rotor, loops: true, isActive: isActive, speed: Self.turnsPerSecond(for: fan), tint: .white)
                        // The hub is one solid disc, with a gap left before the blades.
                        Circle().frame(width: size * 0.1875, height: size * 0.1875)
                    }
                }
                .frame(width: size, height: size)
        } else {
            AirAnimation(name: Animations.rotor, loops: true, isActive: isActive, speed: Self.turnsPerSecond(for: fan), tint: tint)
                .frame(width: size, height: size)
        }
    }

    static func turnsPerSecond(for fan: Fan?) -> Double {
        guard let fan, fan.currentRPM >= stoppedRPM else { return 0 }
        return slowest + (fastest - slowest) * fan.fraction
    }
}
