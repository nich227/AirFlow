---
version: 1
slug: "airflow-views-mainwindow-swift"
primary_target: "AirFlow/Views/MainWindow.swift"
related_targets: ["AirFlow/Views/MenuPanel.swift","AirFlow/Views/Settings/SettingsView.swift"]
---

# The AirFlow window and menu bar panel

Scope: the main window (`AirFlow/Views/MainWindow.swift` and the pages it shows), the menu bar panel (`AirFlow/Views/MenuPanel.swift`), and Settings. Mode: Operate.

Audience and job: a Mac owner who wants a quieter or cooler Mac. They glance at the menu bar, change presets in the panel, and tune a preset or write a rule in the window.

Constraints the user set: Liquid Glass, Ant Design components and icons drawn in that glass ("transparent not just flat"), self-made Lottie animations, the Bootstrap Icons fan as the mark and app icon, and no copy of the Macs Fan Control layout. The window structure was dealt by `concept-seed` and locked by the user: Sidebar by preset.

## Direction contract

THESIS: A preset is an object a person owns, and the window is a library of presets with the Mac's live state beside whichever one is open. It refuses the category's arrangement: two flat tables and a modal dialog per fan, where the one custom state is lost when another preset is chosen.

OWN-WORLD: A translucent window that shows the desktop, with every Ant Design component as a pane of Liquid Glass: Card (one per fan, one per inspector section), Tag (capsule, tinted by state), Alert (tinted by state), Segmented, Slider, Statistic in IBM Plex Mono. Icons are Ant Design's outlined set at one weight. Color does one job: Ant's functional palette as a five-step temperature scale (cyan, green, gold, volcano, red), always beside a number. The accent is the system's. Text is Hedvig Letters Sans and every reading is IBM Plex Mono, both chosen by the user.

STORY: The person sees which preset is active and who chose it, reads what each fan is doing and why in one sentence, applies another preset in one click, or edits a rule in place and watches the live point move along the curve.

FIRST VIEWPORT: 1200 by 760. Glass sidebar, 220 wide: Presets (Automatic, Full Blast, the person's own), Automation (Rules), Monitor (Sensors), and New, Describe, and Import or Export at the bottom. Detail: the preset's icon, name, and sentence, an Active tag or an Apply button in the toolbar, then one glass card per fan: turning rotor, name, sentence, RPM, a track from minimum to maximum, a segmented control, and the curve with two handles and the live point. Inspector, 280 wide: temperatures by part in one card, the last 15 minutes in another, updated every second.

FORM: Sidebar by preset, index 2 of 7 on the ordered list, dealt as an alternate and locked by the user. Seed key 2f064797. Signature move: the fan curve with its live operating point, and a rotor that turns at the fan's own relative speed.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
