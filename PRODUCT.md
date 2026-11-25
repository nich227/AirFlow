# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

AirFlow is a native macOS app. It follows the macOS Human Interface Guidelines and has no web or iOS surface. The schema has no `macos` value, so `adaptive` stands for "native, in the platform's own design language".

## Stack

Two parts. The backend is Rust: it reads and writes the SMC, names the sensors, and is the privileged helper that `SMAppService` registers. The user asked for the part that deals with the system to be Rust. The app is SwiftUI on macOS 26 or later, with Liquid Glass, and links the backend through a C interface. XcodeGen generates the Xcode project from `project.yml`. Lottie plays the drawn animations. The on-device model comes from the FoundationModels framework, and Siri and Shortcuts reach the app through App Intents. Presets are stored as YAML. The repository follows the layout of [ClipDeck](https://github.com/nich227/ClipDeck).

## Users

People who own a Mac with fans and want to choose their own trade between noise and temperature. They open AirFlow when the Mac is too loud for a call, too hot under a long build or render, or about to go in a bag. Most of the time they only glance at the menu bar readout. Several times a day they change a preset. Now and then they tune one.

## Product Purpose

AirFlow shows every fan and temperature sensor in the Mac and lets its owner control each fan: left to the system, held at a constant speed, or driven by a sensor between two temperatures. It saves any number of named presets and changes between them in one click. It succeeds when a person gets the fan behavior they asked for in a few seconds and never has to think about whether the Mac is safe.

## Positioning

Macs Fan Control keeps one custom state in its free version and loses it when another preset is chosen. AirFlow keeps unlimited named presets at no charge. It also lets a person describe a preset or a rule in plain language, and the on-device Apple Intelligence model drafts it for approval. No fan data leaves the Mac.

## Operating Context

- The menu bar item shows a fan speed, a temperature, or both. Its panel lists the fans, the active preset, and the other presets.
- The window is where a person reads all sensors, edits a preset, and writes automation rules.
- Siri, Spotlight, and Shortcuts can apply a preset and report fan speeds and temperatures.
- Fan control needs a helper that runs as root. A person can decline it and use AirFlow to monitor only.
- Other fan control software on the same Mac competes for the same SMC keys.

## Capabilities and Constraints

- Reads fan speed (minimum, current, maximum, target) and temperature sensors from the SMC without privileges. Reads drive temperatures where the system reports them.
- Controls each fan in one of three ways: Automatic (the system), Constant (a fixed RPM), or Sensor-Based (a chosen sensor, the temperature where the speed starts to rise, and the temperature of full speed).
- Built-in presets: Automatic and Full Blast. Starter presets a person can edit or delete: Quiet, Heavy Workload, and Travel.
- Automation rules change presets from the frontmost app, the power source, a sensor threshold, or the time of day. Autopilot runs approved rules by itself and is off until the person turns it on.
- The on-device model drafts presets and rules and explains recent thermal behavior. It never writes to a fan. Every draft is validated and clamped by the same code as a hand-made preset, and the person approves it.
- Safety: the helper clamps every target to the fan's own minimum and maximum, accepts connections only from the signed app, and returns every fan to the system when the app disconnects or quits. A temperature safeguard returns fans to the system when a sensor passes its limit.
- Presets are stored as a YAML file a person can read and edit. Presets can be exported to a `.yaml` file and imported from one. An import never replaces a preset.
- Readings and the history chart update every second while they are on screen.
- Settings: launch at login, Celsius or Fahrenheit, precise temperatures, what the menu bar shows, the safeguard limit, and the helper.
- Requires macOS 26. Apple Intelligence features need a Mac and a region where the model is available, and the app says so when it is not.
- Updates come through Sparkle, and releases are signed with the Developer ID certificate and notarized, by the same workflow as Gailan and ClipDeck. The user asked for both.
- Undecided: Intel support. The first version is built for Apple silicon only and is tested on a MacBook Pro with two fans.

## Brand Commitments

- Name: AirFlow.
- Liquid Glass throughout: the Ant Design components are themselves glass, transparent and not flat. Ant Design supplies the components and the icons. Lottie plays drawn animations that AirFlow authors itself. The user named all of these.
- The mark is the fan from Bootstrap Icons, which the user chose. The app icon is that fan in Liquid Glass.
- The user chose both typefaces: Hedvig Letters Sans for text, and IBM Plex Mono for every reading (fan speeds, temperatures, and any other number that is read). Settings keeps the system's look for its numbers.
- The interface must not copy the layout of Macs Fan Control. It must do the same jobs better.
- User-facing copy follows the Apple Style Guide, as ClipDeck does.

## Evidence on Hand

- A running copy of Macs Fan Control 1.5.17 on the development Mac, its English string table, and a capture of its main window. These define feature parity.
- Live SMC readings from the development Mac (two fans, about 25 sensors).
- No customer quotes, benchmarks, or pricing exist. Future work must not invent them.

## Product Principles

1. The Mac's safety comes before the person's preference. Every path that sets a fan can also give it back.
2. The current state is always legible: which preset is active, who chose it, and what each fan is doing about it.
3. A preset is a named thing a person owns. Editing one never destroys another.
4. Intelligence proposes and a person approves. Automatic behavior is opt-in and explains itself.
5. Monitoring works for everyone, with no helper and no password.

## Accessibility & Inclusion

VoiceOver names every fan, sensor, and control with its value and unit. The app works from the keyboard. It follows Reduce Motion, Reduce Transparency, and Increase Contrast. Temperature state is never shown by color alone.
