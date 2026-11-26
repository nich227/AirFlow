---
name: AirFlow
description: Fan control for the Mac in Liquid Glass, with Ant Design's components and a temperature scale that always sits beside a number.
colors:
  accent: "system accent"
  temp-cool: "#08979C"
  temp-cool-dark: "#36CFC9"
  temp-mild: "#389E0D"
  temp-mild-dark: "#73D13D"
  temp-warm: "#AD6800"
  temp-warm-dark: "#FFC53D"
  temp-hot: "#D4380D"
  temp-hot-dark: "#FF7A45"
  temp-critical: "#CF1322"
  temp-critical-dark: "#FF4D4F"
typography:
  display:
    fontFamily: "Hedvig Letters Sans"
    fontSize: 24
    fontWeight: 400
  title:
    fontFamily: "Hedvig Letters Sans"
    fontSize: 16
    fontWeight: 400
  statistic:
    fontFamily: "IBM Plex Mono"
    fontSize: 24
    fontWeight: 500
  body:
    fontFamily: "Hedvig Letters Sans"
    fontSize: 13
    fontWeight: 400
  label:
    fontFamily: "Hedvig Letters Sans"
    fontSize: 12
    fontWeight: 400
  caption:
    fontFamily: "Hedvig Letters Sans"
    fontSize: 11
    fontWeight: 400
rounded:
  xs: 4
  sm: 6
  md: 8
  card: 16
spacing:
  xxs: 4
  xs: 8
  sm: 12
  md: 16
  lg: 24
  xl: 32
  xxl: 48
---

# Design System: AirFlow

This file defines how AirFlow looks and moves. Every token has a Swift definition in `AirFlow/Utilities/Theme.swift`. Every surface must match this file.

## Overview

**Creative North Star: "Glass Over Air"**

AirFlow is a translucent window. The desktop shows through it, and every component on it is a pane of Liquid Glass. The components are Ant Design's: card, tag, alert, statistic, segmented control, slider. Ant Design gives them their roles and their spacing, and Liquid Glass gives them their material. Nothing is a flat fill.

The interface is for reading a state and changing it. A person must see which preset is active, what each fan is doing, and why. Thus, color has one job, which is temperature, and it never appears without the number it describes.

AirFlow does not use the layout of Macs Fan Control: two flat tables and a dialog for each fan.

**Key Characteristics:**

- A translucent window with glass components. No opaque panels, and no card inside a card.
- One icon set at one weight (Ant Design's outlined icons) and one mark (the fan).
- A five-step temperature scale that is the only color with meaning.
- Two faces that the app carries: Hedvig Letters Sans for text, and IBM Plex Mono for every reading, so a number that changes never moves its neighbors.
- Motion that shows a state: a rotor turns as fast as its fan.

## Colors

The window has no color of its own. The glass takes the color of what is behind it, and the system appearance makes it light or dark.

### Primary

- **Accent** (`Color.accentColor`): the color the person picked in System Settings. It marks the selection, the Apply button, the filled part of a fan's track, the curve's handles, and the Active tag. Multicolor resolves to blue.

### Temperature scale

Ant Design's functional colors, one step for each band. Each step has a darker Light Mode value, so that a dot or a line holds 3:1 against a light window.

| Band | Word | Light | Dark | Ant Design name |
|---|---|---|---|---|
| `cool` | Cool | `#08979C` | `#36CFC9` | cyan |
| `mild` | Normal | `#389E0D` | `#73D13D` | green |
| `warm` | Warm | `#AD6800` | `#FFC53D` | gold |
| `hot` | Hot | `#D4380D` | `#FF7A45` | volcano |
| `critical` | Very Hot | `#CF1322` | `#FF4D4F` | red |

A reading's band depends on the part it belongs to (`TemperatureBand.thresholds`). The CPU and GPU change bands at 50, 70, 85, and 95 °C. The battery changes at 30, 35, 40, and 45 °C. Storage changes at 40, 50, 60, and 70 °C. Every other part changes at 45, 55, 65, and 80 °C.

The scale appears in the status dot beside a temperature, the ground under a fan curve, and the live point on the curve. It also appears in the two lines of the history chart (CPU in `hot`, GPU in `cool`). The alerts use three of its steps: `mild` for success, `warm` for caution, and `critical` for an error.

### Neutral

| Token | Value | With Increase Contrast | Use |
|---|---|---|---|
| `fill` | label color at 0.06 | 0.12 | Quiet grounds |
| `fillStrong` | label color at 0.11 | 0.22 | A fan track's empty part, a hovered row in the menu bar panel |
| `hairline` | label color at 0.12 | 0.40 | Dividers, the curve's grid |

Text is `.primary` or `.secondary`. Never set text to white or black.

### Named Rules

**The Number Rule.** A temperature color never appears alone. A dot sits beside a temperature, and the curve's ground sits under a labeled axis. VoiceOver reads the band's word.

**The One Accent Rule.** The accent means "this is selected" or "this acts". It never decorates.

## Typography

**Text:** Hedvig Letters Sans. It has one weight, so the roles differ by size and by primary or secondary color, never by weight.

**Readings:** IBM Plex Mono, regular and medium. A reading is a number a person reads off the Mac or sets for it. It can be a fan speed with its RPM unit, a temperature, a percentage, a time on an axis, or an SMC key. A reading inside a sentence uses IBM Plex Mono too (`Text(readings:)`).

The app carries both faces in `AirFlow/Resources/Fonts`, under the SIL Open Font License. The person chose both.

| Role | Size | Use | Swift |
|---|---|---|---|
| Display | 24 | A page's heading: the preset's name, Rules | `.airFont(.display)` |
| Title | 16 | A fan's name, an empty state's title | `.airFont(.title)` |
| Statistic | 24, IBM Plex Mono medium | A fan's speed | `.airFont(.statistic)` |
| Body | 13 | Sentences, rows, controls | `.airFont(.body)` |
| Label | 12 | Section titles, tags | `.airFont(.label)` |
| Caption | 11 | Axis titles, notes | `.airFont(.caption)` |
| A reading at any role's size | the role's size, IBM Plex Mono | Temperatures, the RPM unit, a track's limits, both axes of the curve, the charts' axes | `.readingFont(.body)` |

Rules:

- Every reading uses IBM Plex Mono. Use `readingFont` for a value that stands alone and `Text(readings:)` for a sentence that holds one.
- Settings keeps the system's look for its numbers: they use `monospacedDigit()`.
- AirFlow draws its own segmented control and select (`AntSegmented`, `AntSelect`), because the system's cannot use the app's typeface. What the system still draws stays in the system font: a menu's items, a table's header, a stepper's arrows, the time fields, and Settings' controls.
- No text is smaller than 11 points.

## Elevation

AirFlow has no shadows of its own. Depth comes from Liquid Glass, which the system lights and shades. There are two layers: the translucent window (`containerBackground(.thinMaterial, for: .window)`), and the glass components on it.

## Components

AirFlow draws each Ant Design component in glass through `antGlass` (`Theme.swift`), which is `glassEffect` with a shape and an optional tint at 0.28 opacity.

| Component | Ant Design | Glass | Use |
|---|---|---|---|
| `GlassCard` | Card | Clear, radius 16, padding 16 | One for each fan. One for the temperatures and one for the history in the inspector. |
| `StateTag` | Tag | Capsule, tinted | Active, Matches Now, and the kind of work on the Adaptive page |
| `StatusBanner` | Alert | Radius 16, tinted by kind | Monitoring Only, Allow the Helper, Safeguard Is On, a failure, Fan Control Is On |
| `Statistic` | Statistic | None | A fan's speed with its unit, in IBM Plex Mono |
| `StatusDot` | Badge | None | A temperature's band |
| `FanTrack` | Progress | None | The fan's range. The fill is the current speed, and the mark is the speed AirFlow asked for. |
| `CurveEditor` | (AirFlow's own) | Handles are interactive glass circles | A sensor rule as speed against temperature, with the live point |
| `AntSegmented` | Segmented | A flat track, with a pane of accent glass under the selected segment | How a fan runs: Automatic, Constant, Sensor-Based |
| `AntSelect` | Select | A quiet fill, as wide as the chosen option's text. The menu is the system's. | A sensor, a preset, an app, or a power source in a sentence |
| Slider, Stepper, Toggle, time field | The same | The system's | Native controls, unstyled |
| Buttons | Button | `.glass`, and `.glassProminent` for Apply, Draft, and Save | |

Rules:

- A card never contains another card. A fan's readings and its controls share one card.
- A page's root scrolls (`ScrollView` or `Table`).
- A rule is one sentence that a person edits in place: When [this] use [preset].
- An empty state has a drawing, a title, and what to do next.
- The sidebar, the toolbar, the inspector, the menu bar panel, and Settings are the system's own glass.

## Layout and spacing

- Space: `4 8 12 16 24 32 48` (`Space.xxs` through `Space.xxl`), Ant Design's steps on a 4 point grid.
- Radius: `4 6 8` (`Radius.xs`, `sm`, `md`) and 16 for a glass card (`Radius.card`). A tag is a capsule.
- Icons: `14 16 20 28 44 72` (`IconSize.inline`, `row`, `title`, `state`, `rotor`, `illustration`).
- The window opens at 1200 by 760 and is at least 1120 wide: sidebar 220, inspector 280. A page's content is at most 720 wide and is centered.
- The menu bar panel is 340 wide. Settings is 520 wide.

## Icons

The mark is the fan from Bootstrap Icons: a housing with six blades. It is the app icon, the menu bar icon, and the rotor. The app icon is an Icon Composer document (`AppIcon.icon`). The blades and the housing are separate glass layers with specular highlights. The blades are cyan (`#08979C`, and `#36CFC9` in the dark appearance), on a white or near-black ground.

Every other icon is an outlined icon from Ant Design Icons, drawn as a template image through `AntIcon`. AirFlow uses no SF Symbols in its own views. The two actions that appear in Shortcuts and Spotlight name SF Symbols, because those surfaces belong to the system.

## Motion

| Token | Curve | Duration | Use |
|---|---|---|---|
| `Anim.quick` | ease-out | 0.2 | Press and quick state changes |
| `Anim.standard` | cubic-bezier(0.16, 1, 0.3, 1) | 0.35 | A panel or a section that appears |

### The drawn animations

AirFlow draws its own animations. `scripts/make-animations.py` generates each file, and nothing is downloaded.

| File | Canvas | Length | Plays | What happens | Still frame |
|---|---|---|---|---|---|
| `rotor.json` | 120 × 120 | 1 s | Loop, beside each fan | The blades turn once inside a housing that stays still. The app changes how fast the layer's time runs: 0.35 turns a second at the fan's minimum, 2.75 at its maximum, and none when the fan is stopped. | The first frame |
| `breeze.json` | 120 × 120 | 2.2 s | Loop, in an empty state | Three lines of air draw across, hold, and leave the way they came. | The three lines, at 1 s |
| `spark.json` | 120 × 120 | 1.6 s | Loop, while the model works | Three four-pointed stars take turns swelling. | The largest star at full size |
| `done.json` | 60 × 60 | 1 s | Once, when fan control comes on | A ring draws on, then a check draws on inside it with a small pop. | The ring and the check |

All use white strokes or fills, tinted at run time through `AirAnimation`. Every drawn animation uses this component.

### Rules

- Motion shows a state. A rotor's speed is its fan's speed, and a stopped fan does not turn.
- Nothing animates while it is off screen. Every `AirAnimation` takes `isActive`.
- Reduce Motion turns every animation off. Each Lottie file shows its still frame.
- Lottie uses only its Core Animation engine, so the app does no work for each frame.

## Voice

All AirFlow text follows Apple's conventions. Menu items, buttons, toggles, and headings use title-style capitalization (Turn On Fan Control, Sensor-Based). Sentences and messages use sentence style and address the person directly. On the Mac, people click and choose. A message that explains a consequence wraps and never truncates. An error says what failed and what to do next.

Each fan has one sentence that says what it is doing: "Follows CPU Average, from 70° to full speed at 95°." A preset that is not active adds what it would do: "It would be set to 2,010 RPM."

## Accessibility

- VoiceOver: a fan's track reads its speed, its share of the range, and the speed asked for. A temperature reads its value, its unit, and its band's word. The curve reads both temperatures and where the sensor is. Icons that repeat the text beside them are hidden.
- Keyboard: the curve's two temperatures also have steppers. Command-Return applies the selected preset.
- Opening the window never puts the keyboard in a text field. A preset's name is text until the person clicks the pencil.
- Increase Contrast: the fills and the curve's ground use stronger opacities.
- Reduce Transparency: macOS makes the glass opaque.
- Reduce Motion: see Motion.
- Color is never the only signal. See the Number Rule.

## Coherence checklist

A surface matches this design only if all of these hold:

- [ ] Components are glass through `antGlass`, `GlassCard`, `StateTag`, or `StatusBanner`. No card is inside a card.
- [ ] Color with meaning comes from the temperature scale and sits beside a number. Selection and action use the accent.
- [ ] Text is Hedvig Letters Sans through `airFont`, and every reading is IBM Plex Mono through `readingFont` or `Text(readings:)`.
- [ ] Spacing, radius, and icon sizes come from the ramps.
- [ ] Icons are Ant Design's, through `AntIcon`. The mark is the fan.
- [ ] Animations are Lottie files through `AirAnimation`, and nothing moves with Reduce Motion on.
- [ ] Copy is in Apple's register.
- [ ] Every control has a VoiceOver name, and the surface works from the keyboard.
- [ ] The page's root scrolls.
