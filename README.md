# AirFlow

*Your Mac's fans, set the way you want them.*

AirFlow shows every fan and temperature sensor in your Mac and lets you control each fan. You can save any number of presets and change between them from the menu bar. You can also describe a preset in plain words, and Apple Intelligence drafts it on your Mac.

AirFlow requires macOS 26 or later and a Mac with Apple silicon.

## Features

- AirFlow reads each fan's speed, its minimum, and its maximum, and the temperature of every sensor your Mac reports. Sensors are grouped by part: CPU, GPU, Memory, Storage, Battery, Enclosure, Power, and Wireless.
- Each fan can be Automatic (macOS controls it), Constant (one speed), or Sensor-Based (the fan follows a sensor between two temperatures). A sensor-based fan is drawn as a curve with the sensor's current temperature marked on it.
- You can keep as many presets as you want. AirFlow starts with Automatic, Full Blast, Quiet, Heavy Workload, and Travel. Changing a preset never changes another one.
- The menu bar item shows a fan speed, a temperature, or both. Click it to see every fan and to change presets.
- Rules change presets for you: when an app is in front, when your Mac is on battery, when a part gets hot, or at a time of day. Rules do nothing until you turn on Autopilot.
- Describe a preset or a rule, such as "Stay quiet until the CPU reaches 80°", and the model on your Mac drafts it. You decide whether to keep it. Nothing you type leaves your Mac.
- Ask Siri to "Apply Quiet in AirFlow", or use the Apply Fan Preset and Get Fan Status actions in Shortcuts and Spotlight.
- Presets are stored as a YAML file that you can read and edit. You can export presets to a `.yaml` file and import them on another Mac.
- AirFlow checks for a newer version by itself and installs it when you agree. Every update is signed, and AirFlow refuses one that isn't.
- AirFlow uses Liquid Glass throughout, follows Light Mode and Dark Mode, and uses your accent color. Fan speeds and temperatures are set in a monospaced face, so a number that changes doesn't move the text beside it.

## Using AirFlow

| To do this | Do this |
| --- | --- |
| Change presets | Click the fan in the menu bar, then click a preset. |
| Open the window | Click the fan in the menu bar, then click Open AirFlow. |
| Change how a fan runs | Select a preset you made in the sidebar. Click Automatic, Constant, or Sensor-Based under the fan. |
| Change a fan curve | Drag either handle on the curve, or click the arrows beside "Starts rising at" and "Full speed at". |
| Use a preset | Select it in the sidebar, then click Apply. |
| Make a preset | Click the Add button at the bottom of the sidebar. The new preset starts as a copy of the selected one. |
| Describe a preset | Click the light bulb at the bottom of the sidebar. |
| Rename a preset | Click the pencil beside its name. |
| Export or import presets | Click the More button at the bottom of the sidebar, or choose File > Export Presets or File > Import Presets. |
| Add a rule | Click Rules in the sidebar, then click Add Rule. Drag a rule to change its place. The first rule that matches wins. |
| Let rules run | Turn on Autopilot on the Rules page. |
| Turn on fan control | Click Turn On Fan Control, then turn on AirFlow in System Settings > General > Login Items & Extensions. |
| Open AirFlow at login | Choose AirFlow > Settings > General. |
| Check for an update | Choose AirFlow > Check for Updates, or click Check for Updates in Settings > About. |

## Fan control and safety

Reading fans and sensors needs no permission. Changing a fan's speed does, so AirFlow uses a small helper that runs as an administrator. You can decline the helper and use AirFlow to monitor only.

- The helper accepts requests only from a copy of AirFlow that the same developer signed.
- The helper keeps every speed between the fan's own minimum and maximum.
- The helper returns the fans to macOS when AirFlow quits, when AirFlow stops responding for 30 seconds, and when your Mac shuts the helper down.
- The safeguard returns the fans to macOS when the average CPU or GPU temperature reaches a limit you choose (95 °C at first), until the temperature falls 8 degrees below it.

Changing fan speeds changes how your Mac cools itself. You are responsible for the settings you choose. Quit other fan control software before you use AirFlow, because two apps that set the same fan work against each other.

## Privacy

AirFlow doesn't collect any data. Its one network connection is the check for a newer version, which reads a list of releases from GitHub and sends nothing about you or your Mac. You can turn the check off in Settings > About. Apple Intelligence runs on your Mac. Your presets and rules are stored in your Library folder, where you can delete them at any time.

## The presets file

AirFlow keeps your presets in `~/Library/Application Support/AirFlow/presets.yaml`. An exported file has the same format:

```yaml
airflow: 1
presets:
  - name: Quiet
    icon: coffee
    summary: Fans stay at their minimum until the CPU is hot.
    fans:
      mode: sensor
      sensor: cpu average
      start: 70
      full: 95
    overrides:
      - fan: 2
        mode: constant
        rpm: 3200
```

| Key | Meaning |
| --- | --- |
| `fans` | How every fan runs. |
| `overrides` | A different setting for one fan. Fans are counted from 1. |
| `mode` | `automatic`, `constant`, or `sensor`. |
| `rpm` or `percent` | For `constant`: a speed, or a share of the fan's range from 0 to 100. |
| `sensor` | For `sensor`: a part and `average` or `hottest`, such as `gpu hottest`, or `key` and an SMC key, such as `key TaLP`. The parts are `cpu`, `gpu`, `memory`, `storage`, `battery`, `enclosure`, `power`, and `wireless`. |
| `start` and `full` | For `sensor`: the temperatures, in degrees Celsius, where the fan starts to rise and where it reaches full speed. |

AirFlow checks every value in a file it reads. A number outside its range is moved into range, and a file that AirFlow can't read is refused with the reason. An imported preset never replaces one you have: it gets its own name. If the presets file itself can't be read, AirFlow sets it aside as `presets.yaml.unreadable` and starts again with the presets it ships with.

## Requirements

- macOS 26 or later, on a Mac with Apple silicon
- Apple Intelligence, for drafting presets and rules and for explaining readings. Everything else works without it.
- To build AirFlow: Xcode 26 or later, [Rust](https://rustup.rs), and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Building AirFlow

```
scripts/build.sh
open build/DerivedData/Build/Products/Debug/AirFlow.app
```

A plain build is signed ad hoc. It monitors, and it keeps presets and rules, but it can't install the helper, because the helper trusts only an app that a developer team signed. To build a copy that can control fans, sign it with a developer identity from your keychain:

```
scripts/build.sh --sign
```

To run the tests:

```
scripts/test.sh
```

The tests never read or change a real fan. The backend's tests use a made-up SMC, and the app's tests use a recorder in place of the helper.

AirFlow is two parts. The backend is Rust, in `backend/`: it reads the SMC, names the sensors, sets fan speeds, and is the helper. The app is Swift and SwiftUI, in `AirFlow/`, and links the backend through a C interface. XcodeGen generates the Xcode project from `project.yml`, and the repository doesn't include it.

AirFlow uses Swift Package Manager and Cargo for its dependencies. [Lottie](https://github.com/airbnb/lottie-ios) plays the animations, [Yams](https://github.com/jpsim/Yams) reads YAML, and [Sparkle](https://github.com/sparkle-project/Sparkle) installs updates. The backend uses [block2](https://github.com/madsmtm/objc2) and [libc](https://github.com/rust-lang/libc). `scripts/make-animations.py` generates the animation files, and `scripts/make-icons.py` writes the icons.

## License

AirFlow is available under the MIT License. See [LICENSE](LICENSE).

Text is set in [Hedvig Letters Sans](https://github.com/KanonFoundry/HedvigLetters) and readings in [IBM Plex Mono](https://github.com/IBM/plex), both under the SIL Open Font License 1.1. The app icon, the menu bar icon, and the turning fan use the fan from [Bootstrap Icons](https://github.com/twbs/icons), under the MIT License. Every other icon is from [Ant Design Icons](https://github.com/ant-design/ant-design-icons), under the MIT License. [Lottie](https://github.com/airbnb/lottie-ios) is licensed under Apache 2.0. [Sparkle](https://github.com/sparkle-project/Sparkle) is licensed under the MIT License. [Yams](https://github.com/jpsim/Yams), [objc2](https://github.com/madsmtm/objc2), and [libc](https://github.com/rust-lang/libc) are licensed under the MIT License. The [licenses/](licenses) folder contains each license, and the app carries a copy of that folder.

© 2026 Kevin Chen.
