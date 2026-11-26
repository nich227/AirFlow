# AGENTS.md

AirFlow: macOS menu bar fan control. A Rust backend reads the SMC and is the privileged helper. A SwiftUI app shows fans and sensors, keeps presets as YAML, runs rules, and drafts presets with the on-device model. Layout follows https://github.com/nich227/ClipDeck.

## Invariants

1. Everything that touches the Mac itself is Rust, in `backend/`: the SMC, fan and sensor reads, sensor names, fan writes, the power source, the trust rule, and the helper. Swift never calls IOKit or the SMC. Swift reaches the backend only through `backend/include/airflow.h` (`AirFlow/Hardware/Backend.swift`, `HelperClient.swift`). The frontmost app, login items, and `SMAppService` stay in Swift.
2. Only the helper writes to the SMC, and only through `FanWriter` (`backend/src/fans.rs`). `set_automatic` asks until the fan reads as the system's again (`RELEASE_ATTEMPTS`), because the SMC follows a write late, and a fan is the system's at any mode but 1. The last fan to go back gives the system its control back first. The app gives every fan back in one `reset_all` when the plan leaves every fan automatic (`FanController.apply`). `set_target` clamps to the fan's own `F<n>Mn` and `F<n>Mx`, refuses a fan index out of range, a speed that is not finite, and a fan whose limits are equal, and writes no target to a fan the system did not hand over.
3. The helper accepts a client only when the helper has a team identifier and the client satisfies `signing::requirement` for that team and `protocol::CLIENT_IDENTIFIERS`. An ad hoc helper accepts no one. The app sets the mirror requirement on its connection (`airflow_helper_requirement`). Never weaken either side, and never add a second way to reach the helper.
4. The helper gives every fan back to the system in four cases: the last client disconnects, no request arrives for `protocol::WATCHDOG` while a fan is held, SIGTERM, and `reset_all`. It releases `Ftst` when it holds no fan, including after a handover that failed.
5. The app's control loop is `FanController.tick`, and `AppModel.apply` is the one place that changes the active preset. Views never call the helper. A fan with no entry in `FanController.sent` is the system's, so a preset that leaves every fan automatic sends nothing and never starts the helper.
6. The safeguard (`Safeguard` in `Models/FanControl.swift`) overrides every preset. It engages at the limit on the CPU or GPU average and releases `Safeguard.releaseMargin` below it.
7. The on-device model never reaches a fan. `IntelligenceService` returns a `PresetProposal`, a `RuleProposal`, a `WorkloadProposal`, or an `AppSelectionProposal`. An `AppSelectionProposal` only selects apps in the grid of apps (`AppPickerSheet`), where the person clicks Add, and it can name only an app that is installed. `makePreset` and `makeRule` clamp and check every field, and a person saves the result. A `WorkloadProposal` says what an app is known for: it counts only after the person accepts it (`AdaptiveCoordinator.setWorkload`), and an app's regime can only make the detector choose more cooling sooner. Autopilot (`AutomationCoordinator`) applies saved rules only, is off by default, and a preset the person chooses holds until a different rule matches.
8. Every number that enters from outside goes through one clamp: `SensorRule.init` for temperatures, `FanPlanner` for speeds, and then the helper. This covers YAML files, model drafts, and App Intents.
9. Presets are stored and exported in one format, `PresetCodec` (`airflow: 1`). Reading goes through Yams. Writing is line by line in `PresetCodec.encode`. A change to the format raises `PresetCodec.version` and keeps reading the older one. A stored file that cannot be read is moved to `presets.yaml.unreadable` and never written over.
10. Importing never replaces a preset: `PresetStore.importText` gives each one a new identifier and a name of its own. Built-in presets (`Preset.automatic`, `Preset.adaptive`, `Preset.fullBlast`) are never stored, exported, changed, or deleted.
11. Every page in the window's detail column has a `ScrollView` or a `Table` at its root. A page rooted in a plain stack makes the split view lay the whole window out taller than it is, so the sidebar and the page's own header leave the screen (measured on macOS 26.7). Use `PageEmptyState` for an empty page.
12. Ant Design components are Liquid Glass: use `antGlass` and `GlassCard` (`Utilities/Theme.swift`), `StateTag`, and `StatusBanner`. Never call `glassEffect` in a view: one direct call leaves the whole page out of an off-screen drawing. Never nest one glass card in another. Do not wrap page content in `GlassEffectContainer`: it sizes to its content's ideal width and pushes the window's columns off screen.
12a. The window's background is the blurred desktop (`.ultraThinMaterial`). Only while Adaptive is the current preset do the window and the menu bar panel sit on `AirBackdrop`: the rainbow as two fields of color that turn about the window's middle, the inner one faster, so the colors swirl. It turns wherever part of its window is on screen, also behind another app's window, and is still with Reduce Motion on. While Adaptive is current the fan is drawn as a pinwheel of the six colors of the rainbow: each `Rotor` through `airRainbow`, and the Dock icon's fan. Readings are never flat: a status dot is `StatusDot`, a fan's bar is `FanTrack`, and chart and curve lines carry a soft light and a fall of their own color. The accent is `Palette.accent`, the main color of the palette the person chose (`ColorPalette.accent`), not the accent from System Settings: it marks a fan's bar, the selected row of the sidebar, and what acts, and each scene sets it as its `tint`. A view reads its colors as it is built, so each scene's content has `.id(settings.colorPalette)`.
13. Every drawn animation is a Lottie file played through `AirAnimation`, on Lottie's Core Animation engine. The one motion that is not is the backdrop's swirl, a `MeshGradient`, which a Lottie file cannot hold. A one-shot that shows a state takes `isReversed`: it runs forward when the state comes on and back when it goes off, as the readings button's line does. `scripts/make-animations.py` generates the files. Edit the script, rerun it, commit both, and list the name in `Animations.all`. Each file marks its still frame with a `reduced motion` marker. Nothing moves with Reduce Motion on or while `isActive` is false.
14. Opening the window never puts the keyboard in a text field. A preset's name is text until the person clicks the pencil.
15. No force unwraps, `try!`, or `as!` in `AirFlow/`. No `unwrap()` or `expect()` outside tests in `backend/src/`: clippy denies both there. Outside tests, each `unsafe` block in the backend has a `SAFETY:` comment.
16. `cargo clippy --all-targets -- -D warnings` passes, and the Swift build has no warnings.
17. Text is Hedvig Letters Sans through `airFont`. Every reading (a fan speed with its unit, a temperature, a percentage, an axis value, an SMC key) is IBM Plex Mono: `readingFont` for a value that stands alone, and `Text(readings:)` for a sentence that holds one. Settings is the exception: its numbers use `monospacedDigit()`. Never use `.system(size:)` in a view. A button's title, a toggle's title, and a sidebar row need `airFont` on their own text, because the system sets them in its own font otherwise. Use `AntSegmented` and `AntSelect`, not a segmented or pop-up `Picker`.
18. A fan's sentence comes from `FanSentence.text`. It states a fact ("Held at", "Follows") only for the active preset while `FanController.mode` is `.controlling`. In every other case it says what the preset would do and who controls the fan.
19. The Adaptive preset's speed is a share of each fan's range from `AdaptiveController.step`. It reaches a fan only through `FanPlanner.adaptiveCommand`, which keeps it between the fan's limits, and then the helper. It is never below `AdaptiveController.safetyFraction` at the present temperature, whatever the forecaster has learned, and the safety line is not slowed by the slew limit. The safeguard overrides it. With no CPU or GPU temperature it leaves the fans to the system. `adaptive.json` holds the forecaster's coefficients, its two recent error scores, and the Mac's range of power: no reading and no app's name.

## Facts

| | |
|---|---|
| Bundle ID | `com.kevster.airflow` (Debug: `com.kevster.airflow.debug`) |
| Helper | Rust binary `AirFlowHelper` at `Contents/MacOS/`, signing identifier and Mach service `com.kevster.airflow.helper`, registered with `SMAppService.daemon` from `Contents/Library/LaunchDaemons/com.kevster.airflow.helper.plist` |
| Helper messages | XPC dictionaries. Keys and operations are in `backend/src/protocol.rs` and repeated in `airflow.h`. `protocol::tests::the_header_names_the_same_things` fails when they differ |
| Log subsystem | `com.kevster.airflow` |
| Minimum macOS | 26.0, Apple silicon only (`ARCHS: arm64` in `project.yml`). The backend keeps the Intel SMC forms (`fpe2`, `FS! `), which no build exercises |
| Toolchain | Xcode 26+, Swift 5 language mode, Rust (stable), XcodeGen |
| Packages | SwiftPM: `Lottie` 4.6.1+, `Yams` 6+, `Sparkle` 2.8+. Cargo: `block2`, `libc`, pinned by `backend/Cargo.lock` |
| Updates | Sparkle, through `Updates` (`Controllers/Updates.swift`). `SUFeedURL` is `updates.xml.rss` on this repository's `gh-pages` branch, and `SUPublicEDKey` is the public half of the key in the `SPARKLE_ED_PRIVATE_KEY` secret. A Debug build and a test never start the updater |
| License | GNU Affero General Public License, version 3 only (SPDX `AGPL-3.0-only`). `LICENSE` is the FSF's text, unchanged, and the app carries it in `Contents/Resources`. `license` in `backend/Cargo.toml` and `NSHumanReadableCopyright` in `Info.plist` name it. A dependency, a font, or an icon set needs a license that AGPL-3.0 code can include: MIT, BSD, Apache 2.0, and the SIL Open Font License are fine |
| Fonts | `AirFlow/Resources/Fonts`: Hedvig Letters Sans (one weight) and IBM Plex Mono (regular, medium), both under the SIL Open Font License. `ATSApplicationFontsPath` in `Info.plist` registers them. `AirType.textFamily` and `AirType.readingFamily` name them |
| Frameworks | FoundationModels, AppIntents, Charts, ServiceManagement, XPC |
| Forecaster | Adaptive's forecast is the app's own recursive least squares, not an Apple model. `rise` mixes it with the slope carried on, each by `1 / mean squared error` over its last 300 answers (`learnedShare`), because the learned forecast alone lost to the slope in a Mac's first ten minutes and after the Mac changed. Apple's `LinearRegressor` (Create ML Components) was measured against it on 2026-11-25 with `ForecasterComparisonTests`: its `update` leaves a model unchanged after the first fit, a smaller `stepSize` makes the coefficients diverge, and fitting a window again never forecast better (1.15 to 3.03 degrees of mean error against 0.98 to 1.25). Run the comparison again before changing this |
| Storage | `~/Library/Application Support/AirFlow/presets.yaml`, `rules.json`, `adaptive.json` (what the forecaster learned), and `workloads.json` (what the person says an app is known for). A Debug build uses the `Debug/` folder inside it |
| UserDefaults keys | `temperatureUnit`, `preciseTemperatures`, `menuBarReadout`, `safeguardEnabled`, `safeguardLimit`, `autopilotEnabled`, `activePresetID`, `userPresetID`, `showsInspector`, `welcomeShown`, `setupShown`, `colorPalette` |
| Signing | Ad hoc by default, which can only monitor. `scripts/build.sh --sign` takes the Developer ID Application identity from the keychain (team `8ZUR795GTN`), the one a release is signed with, and passes `AIRFLOW_SIGN_IDENTITY` and `AIRFLOW_TEAM`. `CODE_SIGN_IDENTITY` on the command line needs `CODE_SIGN_STYLE=Manual` beside it, as the release workflow passes them, or the Swift packages refuse it |
| Lifecycle | SwiftUI `App`: a `Window` that does not open at launch, a `MenuBarExtra` with the window style, and `Settings`. The app has no Dock icon until its window or Settings is open (`AppDelegate.updateDockPresence`). Opening the app again shows the window (`WindowOpener`). The first time the window opens, `SetupSheet` asks for fan control, opening at login, and automatic updates, and once fan control is on it suggests Adaptive. Turning on fan control opens System Settings at Login Items with `SettingsGuide` beside it: a floating panel that says what to do there, follows that window, and closes when the switch is on (`AppModel.openFanControlSettings`). An app cannot draw inside System Settings, and pointing at the switch itself would need the Accessibility permission |
| Sampling | `ThermalMonitor` reads every second while a window or the panel shows readings, and every four seconds otherwise. History holds 15 minutes |
| SMC keys | Fans: `FNum`, `F<n>Ac`, `F<n>Mn`, `F<n>Mx`, `F<n>Tg`, `F<n>Md`, `Ftst`. Power: `PSTR`, the whole Mac's draw in watts. Temperatures: every `T???` key with a plausible value. Names and groups are in `backend/src/sensors.rs`. A key with no known meaning gets its group's name and a number in key order, and `is_known` is false |
| Mark | The fan from Bootstrap Icons, in `scripts/fan_geometry.py`. The app icon is `AirFlow/Resources/AppIcon.icon`, an Icon Composer document with the blades and the housing as two glass layers. The whole fan has the first palette's color in `AppIcon.icon`, and `scripts/make-icons.py` writes a copy for each other palette (`AppIconMatrix.icon` and so on, from `PALETTES`). `AppIconRainbow.icon` has the fan in the rainbow, from `swift scripts/make-rainbow-icon.swift`. All are listed in `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`, so macOS draws each in Liquid Glass. While AirFlow runs, `DockIcon.update` shows the one for the person's palette, or the rainbow one while Adaptive is current, and chooses again when the palette, the preset, or the icon style changes. macOS draws only the first icon in the person's icon style (Dark, Clear, Tinted). An icon the app sets is a picture, so `make-icons.py` also draws each one's Dark rendition with Icon Composer's `ictool` (`DockMatrixDark` and so on in the asset catalog), and `DockIcon.showsDarkIcons` reads the style from `AppleIconAppearanceTheme`. Only `RegularDark` was seen on a Mac. The other values are read by their endings. The menu bar icon is a template image: white on a dark menu bar, dark on a light one, and never the accent |
| Color palettes | `ColorPalette` (`Models/ColorPalette.swift`): Bliss (the one a new copy starts with), Aurora, Matrix, Girlypop, Synthwave, Nord, Catppuccin. Each has an accent, the five steps of the temperature scale, two colors for the CPU's line and two for the GPU's, and three for the fans' lines, which are never a color of the CPU's or the GPU's. Each color has a Light Mode and a Dark Mode value. `ColorPalette.current` is what the drawing code reads, and `AppSettings.colorPalette` sets it. An alert's colors (`Palette.success`, `caution`, `danger`) are Aurora's in every palette. Nord, Catppuccin, and SynthWave '84 values come from those themes, and Aurora and Girlypop from Tailwind's colors (`licenses/`) |
| Sheets | macOS gives a sheet no shadow. Each sheet's root has `castsSheetShadow()`, which puts the sheet's size in `AppModel.openSheetSize` while it is open, and `SheetShadow` in the window draws the shadow under it |
| User-facing copy | Apple Style Guide: title-style capitalization for menu items, buttons, toggles, and headings, sentence style for messages, "click" and "choose", contractions are fine, never "please". Where an Apple app says the same thing, use its words: the preset in use is "Current" (not controlling) or "Active", and it was "Applied by" Autopilot, Siri, or you. An app "is active". Fans "speed up" and run at "minimum speed" or "full speed". The helper is "the helper tool" where it is first named. Something in progress ends in an ellipsis ("Loading Sensors…"). A search with no match says "Check the spelling or try a new search." |

## Commands

```bash
scripts/build.sh                 # xcodegen, cargo (through Xcode), xcodebuild; ad hoc
scripts/build.sh --sign          # signed with a developer identity, so the helper can be installed
scripts/test.sh                  # cargo test, then the AirFlowTests unit tests
(cd backend && cargo test && cargo clippy --all-targets -- -D warnings)
python3 scripts/make-animations.py                      # regenerates AirFlow/Resources/Animations/*.json
python3 scripts/make-icons.py <ant-design-icons checkout>   # the mark and the Ant Design icons
swift scripts/make-rainbow-icon.swift                   # the rainbow fan inside AppIconRainbow.icon
swift scripts/make-brand.swift                          # docs/images/airflow-brand.png and airflow-brand-dark.png, for the README
scripts/make-screenshots.sh                             # the README's screenshots into docs/images, from the Debug build, without taking the keyboard
TEST_RUNNER_AIRFLOW_SNAPSHOTS=/tmp/airflow-shots scripts/test.sh   # draws each surface with made-up readings
TEST_RUNNER_AIRFLOW_COMPARE=1 scripts/test.sh 2>&1 | grep COMPARE   # the forecaster against Apple's LinearRegressor on the made-up Mac
open -g --env AIRFLOW_SHOW=rules build/DerivedData/Build/Products/Debug/AirFlow.app   # Debug only: opens the window on a page (rules, sensors, a preset's name, setup for the setup sheet, apps for the grid of apps, or guide for the panel beside System Settings) without taking the keyboard
open -g --env AIRFLOW_SHOW=Adaptive --env AIRFLOW_TOGGLE_READINGS=1 build/DerivedData/Build/Products/Debug/AirFlow.app   # Debug only: closes and opens the readings column by itself, for a recording
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
│                                     Preset, PresetCodec, PresetsDocument, Automation, Temperature, AppSettings, ColorPalette,
│                                     Adaptive (WorkloadRegime, RollingWindow, PowerScale, RegimeDetector, ThermalForecaster,
│                                     AdaptivePolicy, AdaptiveController, KnownWorkloads)
├── Controllers/                      AppModel, FanController, PresetStore (PresetFile, JSONFile, NameRegistry), AutomationCoordinator (AppDirectory),
│                                     AdaptiveCoordinator, Updates (Sparkle)
├── Intelligence/                     IntelligenceService (FoundationModels), Proposals, FanIntents (App Intents)
├── Views/                            MainWindow (Sidebar), PresetDetail (FanSentence, FanSection, SensorRuleEditor), LiveInspector
│   │                                 (HistoryChart, SensorsView), AutomationView (RuleRow), AdaptiveViews (AdaptiveSummary,
│   │                                 AppWorkloadsEditor), AppPicker (AppPickerSheet, AppIcons), DescribePresetSheet, SetupSheet (LoginItem), SettingsGuide, MenuPanel
│   ├── Components/                   AirAnimation (Rotor), Components (StateTag, Statistic, FanTrack, StatusBanner, EmptyState, AntSegmented, AntSelect, FlowLayout), CurveEditor
│   └── Settings/SettingsView.swift   General, Fan Control, Intelligence, About
├── Utilities/                        Theme (tokens, AirType, ReadingText, antGlass, AirBackdrop, SheetShadow, GlassCard, AntIcon), DockIcon, Log
└── Resources/                        Assets.xcassets (MenuBarIcon, MarkBlades, MarkHousing, ant-*, Dock*Dark), AppIcon.icon and one for each other palette, AppIconRainbow.icon, Animations/, Fonts/, LaunchDaemons/
AirFlowTests/                         XCTest. Fixtures.swift holds CommandRecorder and made-up snapshots
scripts/                              build.sh, test.sh, build-backend.sh, embed-helper.sh, make-animations.py, make-icons.py, fan_geometry.py,
                                      make-brand.swift, make-screenshots.sh (the README's pictures),
                                      and for a release: import-certificate.sh, sign-nested.sh, make-dmg.sh, check-sparkle-key.js,
                                      sign-release.js, update-appcast.js
.github/workflows/                    test.yml, release.yml (a tag push), check-secrets.yml (by hand)
docs/                                 images/ (the README's brand image and screenshots), release-notes/<version>.md
licenses/                             One file per dependency and icon set. The app carries the folder
PRODUCT.md, DESIGN.md                 What the product is, and how it looks and moves
```

## Tests

| Where | Covers |
|---|---|
| `backend/src/smc.rs` | The byte formats, values that do not fit, key codes |
| `backend/src/sensors.rs` | Fan reads, plausible sensors only, groups and names for Apple silicon and Intel, numbers for keys with no known meaning, a sensor that goes off |
| `backend/src/fans.rs` | Clamping, taking and returning a fan, a fan whose mode follows late, a fan that stays manual while the system's control is off, a fan the system reports with another number, a fan the system never takes back, a fan that does not exist, a speed that is not a number, equal limits, the `Ftst` handover and its failure, reset past a failing fan, Intel's bit per fan |
| `backend/src/signing.rs`, `protocol.rs`, `ffi.rs` | The requirement string and what makes none, the header agreeing with the source, the sample reader across the C interface, null and negative arguments, text cut to fit |
| `HelperTests.swift` | The sample Mac across the bridge, group numbers against the header, the helper and its property list inside the built app, the app's requirement, an unsigned copy reaching no helper, the appcast's address and the update key in `Info.plist`, the license inside the app, no updater under test |
| `HardwareTests.swift` | Group summaries and outliers, sensor sources, history length, extremes, a failed read, the one-second interval |
| `ControlTests.swift` | Sensor rules and their limits, each control as a command, built-in and starter presets, the safeguard, the control loop (nothing without the helper, send once then keep alive, a fan taken back, every fan given back in one request, one fan given back while another is held, a failed give-back, failure and retry, wake) |
| `AutomationAndStoreTests.swift` | Rule matching and order, time past midnight, temperature hysteresis, Autopilot decisions and the person's hold, rule storage, finding apps, the preset store (YAML on disk, unique names, built-ins, duplicates, import, export, an unreadable file), `AppModel` |
| `AdaptiveTests.swift` | The rolling window, the Mac's range of power, the regime tree and its hold, the forecaster learning a made-up Mac, the controller against that Mac (light work, a long load, a steady speed, the slew limit, the fall hold, short bursts, an app's hint, the safety line, no power, no temperature), the share of the range as a speed, the control loop and the safeguard, the hint from open apps, storage. `ForecasterComparisonTests` is skipped unless `AIRFLOW_COMPARE` is set: it prints the forecaster's error beside Apple's `LinearRegressor` (Create ML Components) on the made-up Mac |
| `PresetCodecTests.swift` | Round trips, the shape of the file, names YAML could misread, a file written by hand, limits on numbers, every refusal and its message, sensor names, import and export through `AppModel` |
| `IntelligenceAndViewTests.swift` | Proposals becoming presets and rules, the digest, formats and bands, the menu bar readout, the sentence Siri speaks, settings, animations and icons, both fonts being registered, the readings in a sentence, each fan sentence by mode, names for imported presets, the rule row's line breaks, the Dock icon by palette and by icon style, every palette's colors, the palette in Settings, an app selection, the list of apps for the model, the grid of apps' search and its lines, the warning before a preset is deleted |
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
| A number of the adaptive controller (a threshold, a weight, a slew rate, a hold) | `AdaptivePolicy`, `RegimeDetector`, or `AdaptiveController`, the README's "How Adaptive decides" section and its Adaptive features, and `AdaptiveControllerTests`, which must still pass against the made-up Mac |
| A design token | `DESIGN.md` and `Utilities/Theme.swift` together |
| A font | `AirFlow/Resources/Fonts`, `AirType.textFamily` or `readingFamily`, `ReadingFontTests`, `licenses/`, `DESIGN.md`, the README's License section |
| An animation | `scripts/make-animations.py`, rerun it, `Animations` (the name and `all`), `AnimationTests`, the table in `DESIGN.md` |
| An icon | `ANT_ICONS` in `scripts/make-icons.py`, rerun it, and `PresetIcon` if a preset can carry it. The sparkles (`ant-sparkles`) and the airplane (`ant-airplane`) are drawn by the script itself. The sparkles mark Adaptive and every Apple Intelligence action, and no other preset takes them |
| A color of a palette | `ColorPalette`, the tables in `DESIGN.md`, and `PALETTES` in `scripts/make-icons.py` if it is the accent. `testEveryPaletteHasEveryColorAndTheFirstIsBliss` must still pass: a fan's line is no color of the CPU's or the GPU's, and white text is read on the accent |
| A new palette | A case of `ColorPalette` with every color, an entry in `PALETTES`, then `python3 scripts/make-icons.py`, the new `AppIcon<Name>.icon` in `project.yml` (the resources, the excluded files, and `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`), `licenses/` if the colors come from a theme, `DESIGN.md`, the README |
| The rainbow fan | `swift scripts/make-rainbow-icon.swift`, then `python3 scripts/make-icons.py` for its Dark picture, and `Rotor` in `AirAnimation.swift`, which draws the same pinwheel |
| The mark | `scripts/fan_geometry.py`, then both scripts, `AppIcon.icon/icon.json`, and `swift scripts/make-brand.swift` |
| A page, a banner, or a control that a README picture shows | `scripts/make-screenshots.sh` after `scripts/build.sh`, and the picture's `alt` text in `README.md` |
| A UserDefaults key | `AppSettings`, the pane that writes it, the Facts table |
| A new sheet over the window | `castsSheetShadow()` on its root, so the window draws its shadow |
| Something AirFlow needs permission for | A row in `SetupSheet`, which asks for all of them the first time the window opens (`setupShown`), and the Settings pane that changes it later |
| A new page in the window | `SidebarItem`, `MainWindow.detail`, `MainWindow.launchSelection`, invariant 11 |
| A sentence or a label that shows a number | `Text(readings:)` or `readingFont`, invariant 17 |
| A dependency | `project.yml` or `Cargo.toml`, `licenses/`, the README's License section. Check its license against the License row in Facts first |
| AirFlow's license | `LICENSE`, `license` in `backend/Cargo.toml`, `NSHumanReadableCopyright` in `Info.plist`, the README's License section, the License row in Facts, `testTheAppCarriesItsLicense` |
| The update key | Never, for an app that has shipped: every installed copy refuses an update signed with another key. If it must change, `SUPublicEDKey` in `Info.plist` and the `SPARKLE_ED_PRIVATE_KEY` secret change together, and `scripts/check-sparkle-key.js` must pass |
| Something new inside the app bundle that runs | `scripts/sign-nested.sh` or `scripts/embed-helper.sh` signs it, and the release workflow's "verify the signature" step must still pass |
| The minimum macOS | `project.yml`, `scripts/build-backend.sh`, the README |

## Releasing

The mechanism is the one nich227/Gailan and nich227/ClipDeck use. Push a tag such as `v1.0.1`, and `release.yml` does the rest on a `macos-26` runner:

1. It checks that `SPARKLE_ED_PRIVATE_KEY` is the private half of `SUPublicEDKey`, and runs the backend's tests.
2. It imports the Developer ID certificate into a keychain made for the run (`scripts/import-certificate.sh`) and builds Release with it. `MARKETING_VERSION` is the tag, and `CURRENT_PROJECT_VERSION` is `x*10000 + y*100 + z`, which is the number Sparkle compares.
3. `scripts/embed-helper.sh` signs the helper during the build. `scripts/sign-nested.sh` signs what is inside Sparkle, signs the app again with its entitlements, and checks that the app and the helper carry one team.
4. It notarizes and staples the app, makes the ZIP that Sparkle downloads and the DMG that people download, and signs, notarizes, and staples the DMG.
5. It signs the ZIP with the Ed25519 key (`scripts/sign-release.js`), publishes the GitHub Release with `docs/release-notes/<version>.md`, and adds the release to `updates.xml.rss` on `gh-pages` (`scripts/update-appcast.js`).

Six repository secrets carry it: `MACOS_CERTIFICATE_P12` (base64) and `MACOS_CERTIFICATE_PASSWORD` for the Developer ID certificate, `APPLE_API_KEY_P8` (base64), `APPLE_API_KEY_ID`, and `APPLE_API_ISSUER` for notarization, and `SPARKLE_ED_PRIVATE_KEY`, the base64 of the 32-byte seed. The certificate and the API key are the ones Gailan and ClipDeck use. The update key is AirFlow's own, as each app's is. Its private half is also in the login keychain of the Mac that made it, under the service `https://sparkle-project.org` and the account `AirFlow`.

Run `check-secrets.yml` by hand (Actions > check secrets > Run workflow) to test all six without a release. No key, certificate, or password is ever committed: `.gitignore` refuses their file types.

Write the release notes for the update window, which is small: a heading and bullets.

## Verify before finishing

```bash
scripts/build.sh                                                   # must print BUILD SUCCEEDED and no warning
scripts/test.sh                                                    # cargo test, then TEST SUCCEEDED
(cd backend && cargo clippy --all-targets -- -D warnings)
python3 scripts/make-animations.py && git diff --exit-code -- AirFlow/Resources/Animations
grep -rnE 'as!|try!|\)!' AirFlow --include='*.swift'                # must print nothing
```

The adaptive controller has run only against the made-up Mac in `AdaptiveTests.swift` and, without the helper, as a forecast on the real one. Say so when you report a change to it.

Fan writes cannot be tested without the helper installed, which needs a signed build and approval in System Settings. Say so when you report a change to `fans.rs`, `bin/helper.rs`, or `HelperClient.swift`, and name what you ran.
