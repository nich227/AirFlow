#!/usr/bin/env python3
"""This script writes the icons in AirFlow's asset catalog and the app icon's artwork.

AirFlow's own mark is the fan from Bootstrap Icons (MIT), kept in scripts/fan_geometry.py. Every
other icon is an outlined icon from Ant Design Icons (MIT), copied from a checkout of that
repository:

    git clone --depth 1 https://github.com/ant-design/ant-design-icons /tmp/ant-design-icons
    python3 scripts/make-icons.py /tmp/ant-design-icons

Without the path, the script writes only the mark, the sparkles, and the airplane. Add a name to ANT_ICONS to
bring in another icon. Each one becomes a template image named ant-<name>, which takes the color
of its context.

The sparkles and the airplane are AirFlow's own drawings, in the weight of Ant Design's outlined
icons, because that set has neither. The sparkles mark Adaptive and everything Apple Intelligence
does, and the airplane is the Travel preset's icon. The images are named ant-sparkles and
ant-airplane, so a preset can carry them like any other icon.

The app icon is an Icon Composer document. Its blades and its housing are separate layers, so
each is its own piece of Liquid Glass.
"""

import json
import pathlib
import re
import subprocess
import sys

import fan_geometry

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "AirFlow" / "Resources" / "Assets.xcassets"
APP_ICON = ROOT / "AirFlow" / "Resources" / "AppIcon.icon" / "Assets"

ANT_ICONS = [
    # Presets
    "sync", "thunderbolt", "coffee", "rocket", "compass", "moon", "sun", "fire", "code",
    "video-camera", "experiment", "laptop", "desktop", "home", "sound", "car", "cloud",
    "dashboard", "sliders", "heart", "star",
    # Navigation and triggers
    "branches", "line-chart", "appstore", "clock-circle", "robot",
    # Actions and states
    "plus", "delete", "copy", "edit", "check", "check-circle", "close-circle", "exclamation-circle",
    "info-circle", "warning", "safety-certificate", "setting", "poweroff", "ellipsis", "holder",
    "pause-circle", "undo", "send", "export", "lock", "down", "search",
]

TEMPLATE_CONTENTS = {
    "images": [{"filename": None, "idiom": "universal"}],
    "info": {"author": "xcode", "version": 1},
    "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"},
}


def write_imageset(name, filename, svg):
    folder = CATALOG / f"{name}.imageset"
    folder.mkdir(parents=True, exist_ok=True)
    for stale in folder.glob("*.svg"):
        stale.unlink()
    (folder / filename).write_text(svg)
    contents = json.loads(json.dumps(TEMPLATE_CONTENTS))
    contents["images"][0]["filename"] = filename
    (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def ant_svg(source):
    """An Ant Design icon reduced to its view box and paths, filled black."""
    view_box = re.search(r'viewBox="([^"]+)"', source)
    paths = re.findall(r'<path[^>]*\sd="([^"]+)"', source)
    if not view_box or not paths:
        raise ValueError("no view box or path")
    body = "".join(f'<path fill="#000000" d="{data}"/>' for data in paths)
    return (
        '<?xml version="1.0" standalone="no"?>\n'
        f'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="{view_box.group(1)}">\n'
        f"  {body}\n</svg>\n"
    )


def star(cx, cy, radius, pinch=0.18):
    """A four-pointed star: its points on the axes, and its sides drawn in toward the center."""
    tips = [(cx, cy - radius), (cx + radius, cy), (cx, cy + radius), (cx - radius, cy)]
    bends = [(cx + s * pinch * radius, cy + t * pinch * radius) for s, t in ((1, -1), (1, 1), (-1, 1), (-1, -1))]
    path = f"M{tips[0][0]:.0f} {tips[0][1]:.0f}"
    for index, bend in enumerate(bends):
        tip = tips[(index + 1) % 4]
        path += f"Q{bend[0]:.0f} {bend[1]:.0f} {tip[0]:.0f} {tip[1]:.0f}"
    return path + "Z"


def sparkles_svg():
    """One large star in outline and two small ones, on Ant Design's 1024 grid."""
    large = star(430, 580, 350) + star(430, 580, 350 * 0.62)
    small = star(790, 250, 170) + star(800, 800, 120)
    return (
        '<?xml version="1.0" standalone="no"?>\n'
        '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 1024 1024">\n'
        f'  <path fill="#000000" fill-rule="evenodd" d="{large}"/>\n'
        f'  <path fill="#000000" d="{small}"/>\n'
        '</svg>\n'
    )


def airplane_svg():
    """An airplane seen from above, flying up and to the right, in outline."""
    return (
        '<?xml version="1.0" standalone="no"?>\n'
        '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 1024 1024">\n'
        '  <path fill="none" stroke="#000000" stroke-width="68" stroke-linejoin="round" '
        'd="M793 231L786 338L633 490L703 866L646 923L493 630L369 735L391 872L350 914L262 762L110 674L152 633L289 655L394 531L101 378L158 321L534 391L686 238Z"/>\n'
        '</svg>\n'
    )


# The fan's color in each palette's app icon, in the icon's Light and Dark renditions: the palette's
# accent (ColorPalette.accent in the app), and a brighter step of it on the dark plate. The first is
# the app's own icon. Every icon is an Icon Composer document, so macOS draws it in Liquid Glass.
PALETTES = {
    "": ("#2F7DE0", "#6AABF3"),  # Aqua
    "Cyberpunk": ("#D800FF", "#E45CFF"),
    "Aurora": ("#0D9488", "#2DD4BF"), "Matrix": ("#008F11", "#00FF41"), "Girlypop": ("#DB2777", "#F472B6"),
    "Synthwave": ("#C2259B", "#FF7EDB"), "Nord": ("#4C6E96", "#88C0D0"), "Catppuccin": ("#8839EF", "#CBA6F7"),
    "VSCode": ("#005FB8", "#4DAAFC"), "Monokai": ("#7B52C8", "#AE81FF"), "Solarized": ("#268BD2", "#268BD2"),
    "Darcula": ("#2675BF", "#589DF6"),
}


def icon_color(hex_color):
    channels = ",".join(f"{int(hex_color[i:i + 2], 16) / 255:.5f}" for i in (1, 3, 5))
    return f"extended-srgb:{channels},1.00000"


def write_accent_icons():
    """Colors the whole fan of AppIcon.icon in the first palette's color, and writes a copy of it
    for each other palette."""
    resources = APP_ICON.parent.parent
    base = json.loads((APP_ICON.parent / "icon.json").read_text())
    for name, (light, dark) in PALETTES.items():
        document = json.loads(json.dumps(base))
        for group in document["groups"]:
            for layer in group["layers"]:
                layer["fill-specializations"] = [
                    {"value": {"solid": icon_color(light)}},
                    {"appearance": "dark", "value": {"solid": icon_color(dark)}},
                ]
        folder = resources / f"AppIcon{name}.icon"
        (folder / "Assets").mkdir(parents=True, exist_ok=True)
        (folder / "icon.json").write_text(json.dumps(document, indent=2) + "\n")
        for part in ("blades.svg", "housing.svg"):
            (folder / "Assets" / part).write_text((APP_ICON / part).read_text())


def icon_tool():
    """Icon Composer's command-line tool, which draws a document as macOS would."""
    developer = subprocess.run(["xcode-select", "-p"], capture_output=True, text=True, check=True).stdout.strip()
    tool = pathlib.Path(developer).parent / "Applications" / "Icon Composer.app" / "Contents" / "Executables" / "ictool"
    return tool if tool.exists() else None


def write_dark_dock_icons():
    """Draws the Dark rendition of each icon that AirFlow sets in the Dock itself, as a picture.

    macOS draws only an app's first icon in the person's icon style. An icon that the app sets while
    it runs is a picture, so the Dark one is a picture of its own (DockRainbowDark and so on).
    """
    tool = icon_tool()
    if tool is None:
        print("Icon Composer's ictool was not found, so the dark Dock icons were left as they are")
        return
    resources = APP_ICON.parent.parent
    for name in ["Rainbow", *[name for name in PALETTES if name]]:
        folder = CATALOG / f"Dock{name}Dark.imageset"
        folder.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            [str(tool), str(resources / f"AppIcon{name}.icon"), "--export-image", "--output-file", str(folder / "icon.png"),
             "--platform", "macOS", "--rendition", "Dark", "--width", "256", "--height", "256", "--scale", "2"],
            check=True, capture_output=True,
        )
        contents = {
            "images": [{"idiom": "mac", "filename": "icon.png", "scale": "2x"}],
            "info": {"author": "xcode", "version": 1},
        }
        (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def main():
    write_imageset("MenuBarIcon", "fan.svg", fan_geometry.svg(18))
    # The Dock icon paints the blades in the person's accent, so each part is also an image.
    write_imageset("MarkBlades", "blades.svg", fan_geometry.svg(824, parts=(fan_geometry.BLADES,)))
    write_imageset("MarkHousing", "housing.svg", fan_geometry.svg(824, parts=(fan_geometry.HOUSING,)))
    write_imageset("ant-sparkles", "sparkles.svg", sparkles_svg())
    write_imageset("ant-airplane", "airplane.svg", airplane_svg())
    APP_ICON.mkdir(parents=True, exist_ok=True)
    for stale in APP_ICON.glob("*.svg"):
        stale.unlink()
    (APP_ICON / "blades.svg").write_text(fan_geometry.svg(1024, parts=(fan_geometry.BLADES,)))
    (APP_ICON / "housing.svg").write_text(fan_geometry.svg(1024, parts=(fan_geometry.HOUSING,)))
    write_accent_icons()
    write_dark_dock_icons()
    print("wrote the mark, the sparkles, the airplane, and an app icon for each palette")

    if len(sys.argv) < 2:
        return
    outlined = pathlib.Path(sys.argv[1]) / "packages" / "icons-svg" / "svg" / "outlined"
    for name in ANT_ICONS:
        write_imageset(f"ant-{name}", f"{name}.svg", ant_svg((outlined / f"{name}.svg").read_text()))
    print(f"wrote {len(ANT_ICONS)} Ant Design icons")


if __name__ == "__main__":
    main()
