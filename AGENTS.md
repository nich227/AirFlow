# AGENTS.md

AirFlow: macOS menu bar fan control. A Rust backend reads the SMC and is the privileged helper. A SwiftUI app shows fans and sensors, keeps presets as YAML, runs rules, and drafts presets with the on-device model. Layout follows https://github.com/nich227/ClipDeck.

## Invariants

1. Everything that touches the Mac itself is Rust, in `backend/`: the SMC, fan and sensor reads, sensor names, fan writes, the power source, the trust rule, and the helper. Swift never calls IOKit or the SMC. Swift reaches the backend only through `backend/include/airflow.h` (`AirFlow/Hardware/Backend.swift`, `HelperClient.swift`). The frontmost app, login items, and `SMAppService` stay in Swift.
2. Only the helper writes to the SMC, and only through `FanWriter` (`backend/src/fans.rs`). `set_target` clamps to the fan's own `F<n>Mn` and `F<n>Mx`, refuses a fan index out of range, a speed that is not finite, and a fan whose limits are equal, and writes no target to a fan the system did not hand over.
3. The helper accepts a client only when the helper has a team identifier and the client satisfies `signing::requirement` for that team and `protocol::CLIENT_IDENTIFIERS`. An ad hoc helper accepts no one. The app sets the mirror requirement on its connection (`airflow_helper_requirement`). Never weaken either side, and never add a second way to reach the helper.
4. The helper gives every fan back to the system in four cases: the last client disconnects, no request arrives for `protocol::WATCHDOG` while a fan is held, SIGTERM, and `reset_all`. It releases `Ftst` when it holds no fan, including after a handover that failed.
5. The app's control loop is `FanController.tick`, and `AppModel.apply` is the one place that changes the active preset. Views never call the helper. A fan with no entry in `FanController.sent` is the system's, so a preset that leaves every fan automatic sends nothing and never starts the helper.
6. The safeguard (`Safeguard` in `Models/FanControl.swift`) overrides every preset. It engages at the limit on the CPU or GPU average and releases `Safeguard.releaseMargin` below it.
7. The on-device model never reaches a fan. `IntelligenceService` returns a `PresetProposal` or `RuleProposal`. `makePreset` and `makeRule` clamp and check every field, and a person saves the result. Autopilot (`AutomationCoordinator`) applies saved rules only, is off by default, and a preset the person chooses holds until a different rule matches.
8. Every number that enters from outside goes through one clamp: `SensorRule.init` for temperatures, `FanPlanner` for speeds, and then the helper. This covers YAML files, model drafts, and App Intents.
9. Presets are stored and exported in one format, `PresetCodec` (`airflow: 1`). Reading goes through Yams. Writing is line by line in `PresetCodec.encode`. A change to the format raises `PresetCodec.version` and keeps reading the older one. A stored file that cannot be read is moved to `presets.yaml.unreadable` and never written over.
10. Importing never replaces a preset: `PresetStore.importText` gives each one a new identifier and a name of its own. Built-in presets (`Preset.automatic`, `Preset.fullBlast`) are never stored, exported, changed, or deleted.
11. Every page in the window's detail column has a `ScrollView` or a `Table` at its root. A page rooted in a plain stack makes the split view lay the whole window out taller than it is, so the sidebar and the page's own header leave the screen (measured on macOS 26.7). Use `PageEmptyState` for an empty page.
12. Ant Design components are Liquid Glass: use `antGlass` and `GlassCard` (`Utilities/Theme.swift`), `StateTag`, and `StatusBanner`. Never call `glassEffect` in a view: one direct call leaves the whole page out of an off-screen drawing. Never nest one glass card in another. Do not wrap page content in `GlassEffectContainer`: it sizes to its content's ideal width and pushes the window's columns off screen.
13. Every drawn animation is a Lottie file played through `AirAnimation`, on Lottie's Core Animation engine. `scripts/make-animations.py` generates the files. Edit the script, rerun it, commit both, and list the name in `Animations.all`. Each file marks its still frame with a `reduced motion` marker. Nothing moves with Reduce Motion on or while `isActive` is false.
14. Opening the window never puts the keyboard in a text field. A preset's name is text until the person clicks the pencil.
15. No force unwraps, `try!`, or `as!` in `AirFlow/`. No `unwrap()` or `expect()` outside tests in `backend/src/`: clippy denies both there. Outside tests, each `unsafe` block in the backend has a `SAFETY:` comment.
16. `cargo clippy --all-targets -- -D warnings` passes, and the Swift build has no warnings.
17. Text is Hedvig Letters Sans through `airFont`. Every reading (a fan speed with its unit, a temperature, a percentage, an axis value, an SMC key) is IBM Plex Mono: `readingFont` for a value that stands alone, and `Text(readings:)` for a sentence that holds one. Settings is the exception: its numbers use `monospacedDigit()`. Never use `.system(size:)` in a view. A button's title, a toggle's title, and a sidebar row need `airFont` on their own text, because the system sets them in its own font otherwise. Use `AntSegmented` and `AntSelect`, not a segmented or pop-up `Picker`.
18. A fan's sentence comes from `FanSentence.text`. It states a fact ("Held at", "Follows") only for the active preset while `FanController.mode` is `.controlling`. In every other case it says what the preset would do and who controls the fan.

## Facts

| | |
|---|---|
| Bundle ID | `com.kevster.airflow` (Debug: `com.kevster.airflow.debug`) |
| Helper | Rust binary `AirFlowHelper` at `Contents/MacOS/`, signing identifier and Mach service `com.kevster.airflow.helper`, registered with `SMAppService.daemon` from `Contents/Library/LaunchDaemons/com.kevster.airflow.helper.plist` |
| Helper messages | XPC dictionaries. Keys and operations are in `backend/src/protocol.rs` and repeated in `airflow.h`. `protocol::tests::the_header_names_the_same_things` fails when they differ |
| Log subsystem | `com.kevster.airflow` |
| Minimum macOS | 26.0, Apple silicon only (`ARCHS: arm64` in `project.yml`). The backend keeps the Intel SMC forms (`fpe2`, `FS! `), which no build exercises |
| Toolchain | Xcode 26+, Swift 5 language mode, Rust (stable), XcodeGen |
| Packages | SwiftPM: `Lottie` 4.6.1+, `Yams` 6+. Cargo: `block2`, `libc`, pinned by `backend/Cargo.lock` |
| Fonts | `AirFlow/Resources/Fonts`: Hedvig Letters Sans (one weight) and IBM Plex Mono (regular, medium), both under the SIL Open Font License. `ATSApplicationFontsPath` in `Info.plist` registers them. `AirType.textFamily` and `AirType.readingFamily` name them |
| Frameworks | FoundationModels, AppIntents, Charts, ServiceManagement, XPC |
| Storage | `~/Library/Application Support/AirFlow/presets.yaml` and `rules.json`. A Debug build uses the `Debug/` folder inside it |
| UserDefaults keys | `temperatureUnit`, `preciseTemperatures`, `menuBarReadout`, `safeguardEnabled`, `safeguardLimit`, `autopilotEnabled`, `activePresetID`, `userPresetID`, `showsInspector`, `welcomeShown` |
| Signing | Ad hoc by default, which can only monitor. `scripts/build.sh --sign` passes `AIRFLOW_SIGN_IDENTITY` and `AIRFLOW_TEAM`. Passing `CODE_SIGN_IDENTITY` on the command line breaks the Swift packages |
| Lifecycle | SwiftUI `App`: a `Window` that does not open at launch, a `MenuBarExtra` with the window style, and `Settings`. The app has no Dock icon until its window or Settings is open (`AppDelegate.updateDockPresence`). Opening the app again shows the window (`WindowOpener`) |
| Sampling | `ThermalMonitor` reads every second while a window or the panel shows readings, and every four seconds otherwise. History holds 15 minutes |
| SMC keys | Fans: `FNum`, `F<n>Ac`, `F<n>Mn`, `F<n>Mx`, `F<n>Tg`, `F<n>Md`, `Ftst`. Temperatures: every `T???` key with a plausible value. Names and groups are in `backend/src/sensors.rs`. A key with no known meaning gets its group's name and a number in key order, and `is_known` is false |
| Mark | The fan from Bootstrap Icons, in `scripts/fan_geometry.py`. The app icon is `AirFlow/Resources/AppIcon.icon`, an Icon Composer document with the blades and the housing as two glass layers |
| User-facing copy | Apple Style Guide: title-style capitalization for menu items, buttons, toggles, and headings, sentence style for messages, "click" and "choose", contractions are fine, never "please" |

## Commands

```bash
scripts/build.sh                 # xcodegen, cargo (through Xcode), xcodebuild; ad hoc
scripts/build.sh --sign          # signed with a developer identity, so the helper can be installed
scripts/test.sh                  # cargo test, then the AirFlowTests unit tests
(cd backend && cargo test && cargo clippy --all-targets -- -D warnings)
python3 scripts/make-animations.py                      # regenerates AirFlow/Resources/Animations/*.json
python3 scripts/make-icons.py <ant-design-icons checkout>   # the mark and the Ant Design icons
TEST_RUNNER_AIRFLOW_SNAPSHOTS=/tmp/airflow-shots scripts/test.sh   # draws each surface with made-up readings
open -g --env AIRFLOW_SHOW=rules build/DerivedData/Build/Products/Debug/AirFlow.app   # Debug only: opens the window on a page (rules, sensors, or a preset's name) without taking the keyboard
open -g --env AIRFLOW_SHOW=Quiet --env AIRFLOW_APPEARANCE=light build/DerivedData/Build/Products/Debug/AirFlow.app   # Debug only: the same, in Light Mode (or dark)
```

`AIRFLOW_BUILD_JOBS` caps the workers of both builds (default 4). The `.xcodeproj` is generated and gitignored. Edit `project.yml`.

## Files

```
backend/                              Rust. The system layer.
├── Cargo.toml, Cargo.lock, build.rs  staticlib + rlib + the AirFlowHelper binary; build.rs embeds helper-Info.plist
├── include/airflow.h                 The C interface and the wire names; module.modulemap makes it the Swift module AirFlowBackend
└── src/
    ├── smc.rs                        SmcAccess, SmcConnection (IOKit), the byte formats
    ├── sensors.rs                    Reader (fans, sensors, discovery), the sensor catalog
    ├── fans.rs                       FanWriter
    ├── power.rs                      Battery or adapter
    ├── signing.rs                    Own team identifier, the requirement string
    ├── protocol.rs                   Service name, message keys, operations, timeouts
    ├── ffi.rs                        The functions airflow.h declares
    ├── testing.rs                    FakeSmc, also behind airflow_reader_open_sample
    └── bin/helper.rs                 The helper: XPC listener, state, watchdog, SIGTERM
AirFlow/
├── AirFlowApp.swift                  Scenes, File menu commands, AppDelegate, WindowOpener
├── Hardware/
│   ├── Backend.swift                 BackendReader, SnapshotSource, HardwareSampler, Backend
│   ├── ThermalMonitor.swift          Snapshot, history, extremes, the sampling loop
│   └── HelperClient.swift            FanCommanding, HelperClient (XPC), HelperManager (SMAppService)
├── Models/                           Fan, Sensor, ThermalSnapshot, FanControl (SensorRule, FanPlanner, Safeguard),
│                                     Preset, PresetCodec, PresetsDocument, Automation, Temperature, AppSettings
├── Controllers/                      AppModel, FanController, PresetStore (PresetFile, JSONFile, NameRegistry), AutomationCoordinator (AppDirectory)
├── Intelligence/                     IntelligenceService (FoundationModels), Proposals, FanIntents (App Intents)
├── Views/                            MainWindow (Sidebar), PresetDetail (FanSentence, FanSection, SensorRuleEditor), LiveInspector
│   │                                 (HistoryChart, SensorsView), AutomationView (RuleRow), DescribePresetSheet, MenuPanel
│   ├── Components/                   AirAnimation (Rotor), Components (StateTag, Statistic, FanTrack, StatusBanner, EmptyState, AntSegmented, AntSelect, FlowLayout), CurveEditor
│   └── Settings/SettingsView.swift   General, Fan Control, Intelligence, About
├── Utilities/                        Theme (tokens, AirType, ReadingText, antGlass, GlassCard, AntIcon), Log
└── Resources/                        Assets.xcassets (MenuBarIcon, ant-*, Temp* colors), AppIcon.icon, Animations/, Fonts/, LaunchDaemons/
AirFlowTests/                         XCTest. Fixtures.swift holds CommandRecorder and made-up snapshots
scripts/                              build.sh, test.sh, build-backend.sh, embed-helper.sh, make-animations.py, make-icons.py, fan_geometry.py
licenses/                             One file per dependency and icon set. The app carries the folder
PRODUCT.md, DESIGN.md                 What the product is, and how it looks and moves
```

## Tests

| Where | Covers |
|---|---|
| `backend/src/smc.rs` | The byte formats, values that do not fit, key codes |
| `backend/src/sensors.rs` | Fan reads, plausible sensors only, groups and names for Apple silicon and Intel, numbers for keys with no known meaning, a sensor that goes off |
| `backend/src/fans.rs` | Clamping, taking and returning a fan, a fan that does not exist, a speed that is not a number, equal limits, the `Ftst` handover and its failure, reset past a failing fan, Intel's bit per fan |
| `backend/src/signing.rs`, `protocol.rs`, `ffi.rs` | The requirement string and what makes none, the header agreeing with the source, the sample reader across the C interface, null and negative arguments, text cut to fit |
| `HelperTests.swift` | The sample Mac across the bridge, group numbers against the header, the helper and its property list inside the built app, the app's requirement, an unsigned copy reaching no helper |
| `HardwareTests.swift` | Group summaries and outliers, sensor sources, history length, extremes, a failed read, the one-second interval |
| `ControlTests.swift` | Sensor rules and their limits, each control as a command, built-in and starter presets, the safeguard, the control loop (nothing without the helper, send once then keep alive, a fan taken back, automatic, failure and retry, wake) |
| `AutomationAndStoreTests.swift` | Rule matching and order, time past midnight, temperature hysteresis, Autopilot decisions and the person's hold, rule storage, finding apps, the preset store (YAML on disk, unique names, built-ins, duplicates, import, export, an unreadable file), `AppModel` |
| `PresetCodecTests.swift` | Round trips, the shape of the file, names YAML could misread, a file written by hand, limits on numbers, every refusal and its message, sensor names, import and export through `AppModel` |
| `IntelligenceAndViewTests.swift` | Proposals becoming presets and rules, the digest, formats and bands, the menu bar readout, the sentence Siri speaks, settings, animations and icons, both fonts being registered, the readings in a sentence, each fan sentence by mode, names for imported presets, the rule row's line breaks |
| `SnapshotTests.swift` | Skipped unless `AIRFLOW_SNAPSHOTS` is set. Draws each surface's layers off screen. The system draws nothing that sits on Liquid Glass there, so the drawings set `airFlatGlass`, and `antGlass` draws a flat fill |

## When you change X, also change Y

| Change | Also update |
|---|---|
| A function or structure in `ffi.rs` | `backend/include/airflow.h`, `Backend.swift`, `ffi::tests::the_header_declares_every_function` |
| A message key or operation | `protocol.rs`, `airflow.h`, `bin/helper.rs`, `HelperClient.swift`, and raise `PROTOCOL_VERSION` |
| A sensor group | `sensors::Group`, the `AIRFLOW_GROUP_*` values in `airflow.h`, `SensorGroup` in the same order, `TemperatureBand.thresholds`, `testTheGroupsAreNumberedAsTheBackendNumbersThem` |
| A sensor's name or group | `KNOWN` or the prefix rules in `sensors.rs`, and its tests |
| The helper's identifier or service name | `protocol.rs`, `airflow.h`, `helper-Info.plist`, the launchd property list, `scripts/embed-helper.sh`, `HelperManager.daemonPlistName` |
| A kind of fan control | `FanControl`, `FanPlanner`, `PresetCodec` (both directions), `FanSection`, `ProposalPreview`, the README's table |
| The presets file's format | `PresetCodec.version`, a test that reads the older format, the README's example |
| A design token | `DESIGN.md` and `Utilities/Theme.swift` together |
| A font | `AirFlow/Resources/Fonts`, `AirType.textFamily` or `readingFamily`, `ReadingFontTests`, `licenses/`, `DESIGN.md`, the README's License section |
| An animation | `scripts/make-animations.py`, rerun it, `Animations` (the name and `all`), `AnimationTests`, the table in `DESIGN.md` |
| An icon | `ANT_ICONS` in `scripts/make-icons.py`, rerun it, and `PresetIcon` if a preset can carry it |
| The mark | `scripts/fan_geometry.py`, then both scripts, and `AppIcon.icon/icon.json` |
| A UserDefaults key | `AppSettings`, the pane that writes it, the Facts table |
| A new page in the window | `SidebarItem`, `MainWindow.detail`, `MainWindow.launchSelection`, invariant 11 |
| A sentence or a label that shows a number | `Text(readings:)` or `readingFont`, invariant 17 |
| A dependency | `project.yml` or `Cargo.toml`, `licenses/`, the README's License section |
| The minimum macOS | `project.yml`, `scripts/build-backend.sh`, the README |

## Verify before finishing

```bash
scripts/build.sh                                                   # must print BUILD SUCCEEDED and no warning
scripts/test.sh                                                    # cargo test, then TEST SUCCEEDED
(cd backend && cargo clippy --all-targets -- -D warnings)
python3 scripts/make-animations.py && git diff --exit-code -- AirFlow/Resources/Animations
grep -rnE 'as!|try!|\)!' AirFlow --include='*.swift'                # must print nothing
```

Fan writes cannot be tested without the helper installed, which needs a signed build and approval in System Settings. Say so when you report a change to `fans.rs`, `bin/helper.rs`, or `HelperClient.swift`, and name what you ran.
