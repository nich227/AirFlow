#!/usr/bin/env python3
"""This script writes the icons in AirFlow's asset catalog and the app icon's artwork.

AirFlow's own mark is the fan from Bootstrap Icons (MIT), kept in scripts/fan_geometry.py. Every
other icon is an outlined icon from Ant Design Icons (MIT), copied from a checkout of that
repository:

    git clone --depth 1 https://github.com/ant-design/ant-design-icons /tmp/ant-design-icons
    python3 scripts/make-icons.py /tmp/ant-design-icons

Without the path, the script writes only the mark. Add a name to ANT_ICONS to bring in another
icon. Each one becomes a template image named ant-<name>, which takes the color of its context.

The app icon is an Icon Composer document. Its blades and its housing are separate layers, so
each is its own piece of Liquid Glass.
"""

import json
import pathlib
import re
import sys

import fan_geometry

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "AirFlow" / "Resources" / "Assets.xcassets"
APP_ICON = ROOT / "AirFlow" / "Resources" / "AppIcon.icon" / "Assets"

ANT_ICONS = [
    # Presets
    "sync", "thunderbolt", "coffee", "rocket", "compass", "moon", "sun", "fire", "code",
    "video-camera", "experiment", "laptop", "desktop", "home", "sound", "car", "cloud",
    "dashboard", "sliders", "heart", "star", "aim",
    # Navigation and triggers
    "branches", "line-chart", "appstore", "clock-circle", "robot", "bulb",
    # Actions and states
    "plus", "delete", "copy", "edit", "check", "check-circle", "close-circle", "exclamation-circle",
    "info-circle", "warning", "safety-certificate", "setting", "poweroff", "ellipsis", "holder",
    "pause-circle", "undo", "send", "export", "lock", "down",
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


def main():
    write_imageset("MenuBarIcon", "fan.svg", fan_geometry.svg(18))
    APP_ICON.mkdir(parents=True, exist_ok=True)
    for stale in APP_ICON.glob("*.svg"):
        stale.unlink()
    (APP_ICON / "blades.svg").write_text(fan_geometry.svg(1024, parts=(fan_geometry.BLADES,)))
    (APP_ICON / "housing.svg").write_text(fan_geometry.svg(1024, parts=(fan_geometry.HOUSING,)))
    print("wrote the mark")

    if len(sys.argv) < 2:
        return
    outlined = pathlib.Path(sys.argv[1]) / "packages" / "icons-svg" / "svg" / "outlined"
    for name in ANT_ICONS:
        write_imageset(f"ant-{name}", f"{name}.svg", ant_svg((outlined / f"{name}.svg").read_text()))
    print(f"wrote {len(ANT_ICONS)} Ant Design icons")


if __name__ == "__main__":
    main()
