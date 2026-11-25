#!/usr/bin/env python3
"""This script writes AirFlow's Lottie animations into AirFlow/Resources/Animations.

Every file contains only plain shape layers, stroked or filled in white, so the app can tint
them at run time. Each file has one "reduced motion" marker on the frame that the app shows when nothing
may move. A one-shot also stops on that frame. Edit the geometry here. Run the script. Commit both
the script and the JSON.

    python3 scripts/make-animations.py
"""

import json
import math
import pathlib

import fan_geometry

OUT = pathlib.Path(__file__).resolve().parent.parent / "AirFlow" / "Resources" / "Animations"
FPS = 60
STILL_MARKER = "reduced motion"  # the name Lottie players look for


def static(value):
    return {"a": 0, "k": value}


def keyframes(frames, ease_out=(0.33, 0), ease_in=(0.67, 1)):
    """frames is a list of (time, value) pairs. Each value is a number or a list."""
    result = []
    for index, (time, value) in enumerate(frames):
        value = value if isinstance(value, list) else [value]
        frame = {"t": time, "s": value}
        if index < len(frames) - 1:
            frame["o"] = {"x": [ease_out[0]], "y": [ease_out[1]]}
            frame["i"] = {"x": [ease_in[0]], "y": [ease_in[1]]}
        result.append(frame)
    return {"a": 1, "k": result}


def linear(frames):
    return keyframes(frames, ease_out=(0, 0), ease_in=(1, 1))


def stroke(width):
    return {
        "ty": "st", "nm": "Stroke 1",
        "c": static([1, 1, 1, 1]), "o": static(100), "w": static(width),
        "lc": 2, "lj": 2,
    }


def transform():
    return {
        "ty": "tr",
        "p": static([0, 0]), "a": static([0, 0]), "s": static([100, 100]),
        "r": static(0), "o": static(100), "sk": static(0), "sa": static(0),
    }


def group(name, items):
    return {"ty": "gr", "nm": name, "it": items + [transform()]}


def layer(name, index, shapes, out_point, position, rotation=None, scale=None, opacity=None, start=0):
    return {
        "ddd": 0, "ind": index, "ty": 4, "nm": name, "sr": 1,
        "ks": {
            "o": opacity if opacity else static(100),
            "r": rotation if rotation else static(0),
            "p": static([position[0], position[1], 0]),
            "a": static([0, 0, 0]),
            "s": scale if scale else static([100, 100, 100]),
        },
        "ao": 0,
        "shapes": shapes,
        "ip": start, "op": out_point, "st": 0, "bm": 0,
    }


def document(name, width, height, out_point, still, layers):
    """The app shows the still frame when nothing may move. A one-shot stops on that frame."""
    return {
        "v": "5.7.4", "fr": FPS, "ip": 0, "op": out_point, "w": width, "h": height,
        "nm": name, "ddd": 0, "assets": [], "layers": layers,
        "markers": [{"cm": STILL_MARKER, "tm": still, "dr": 0}],
    }


def bezier(vertices, ins, outs, closed):
    return {"ty": "sh", "nm": "Path 1", "ks": static({"i": ins, "o": outs, "v": vertices, "c": closed})}


def polyline(points):
    zero = [[0, 0] for _ in points]
    return bezier([list(point) for point in points], zero, zero, False)


def trim(end, start=None):
    return {"ty": "tm", "nm": "Trim Paths 1", "s": start if start else static(0), "e": end, "o": static(0), "m": 1}


def fill():
    return {"ty": "fl", "nm": "Fill 1", "c": static([1, 1, 1, 1]), "o": static(100), "r": 1}


def rotor():
    """The blades turn once a second inside a housing that stays still. The app changes how
    fast the layer's time runs, so the same file shows a fan at any speed."""
    canvas = 120
    unit = 112 / fan_geometry.VIEW_BOX

    def place(point):
        return (point[0] - fan_geometry.CENTER) * unit, (point[1] - fan_geometry.CENTER) * unit

    shapes = []
    for start, curves in fan_geometry.subpaths(fan_geometry.BLADES):
        vertices = [place(start)] + [place(curve[2]) for curve in curves]
        outs = [(0, 0) for _ in vertices]
        ins = [(0, 0) for _ in vertices]
        for number, (first, second, _) in enumerate(curves):
            control, other = place(first), place(second)
            outs[number] = (control[0] - vertices[number][0], control[1] - vertices[number][1])
            ins[number + 1] = (other[0] - vertices[number + 1][0], other[1] - vertices[number + 1][1])
        # A shape that ends where it began closes on its first vertex.
        if math.dist(vertices[0], vertices[-1]) < 1e-6:
            ins[0] = ins[-1]
            vertices, ins, outs = vertices[:-1], ins[:-1], outs[:-1]
        rounded = [[[round(x, 3), round(y, 3)] for x, y in values] for values in (vertices, ins, outs)]
        shapes.append(bezier(rounded[0], rounded[1], rounded[2], True))

    turn = FPS
    blades = layer(
        "Blades", 1, [group("Blades", shapes + [fill()])], turn, (canvas / 2, canvas / 2),
        rotation=linear([(0, 0), (turn, 360)]),
    )
    diameter = round(2 * fan_geometry.HOUSING_RADIUS * unit, 3)
    ring = {"ty": "el", "nm": "Ellipse Path 1", "p": static([0, 0]), "s": static([diameter, diameter]), "d": 1}
    housing = layer(
        "Housing", 2, [group("Housing", [ring, stroke(fan_geometry.HOUSING_WIDTH * unit)])], turn, (canvas / 2, canvas / 2)
    )
    return document("AirFlow rotor", canvas, canvas, turn, 0, [blades, housing])


def breeze():
    """Three lines of air draw across, hold, and leave the way they came."""
    canvas = 120
    rows = [(38, 26, 92, 0), (60, 16, 104, 8), (82, 34, 84, 16)]
    drawn, hold_until, gone, loop_end = 36, 78, 112, 132
    layers = []
    for index, (y, left, right, delay) in enumerate(rows):
        line = polyline([(left, y), (right, y)])
        ends = keyframes([(delay, 0), (delay + drawn, 100)], ease_out=(0.3, 0), ease_in=(0.15, 1))
        starts = keyframes([(hold_until + delay, 0), (gone + delay, 100)], ease_out=(0.4, 0), ease_in=(0.2, 1))
        layers.append(layer(f"Line {index + 1}", index + 1, [group("Line", [line, trim(ends, starts), stroke(7)])], loop_end, (0, 0)))
    return document("AirFlow breeze", canvas, canvas, loop_end, 60, layers)


def done():
    """A ring draws on, then a check draws on inside it with a small pop."""
    ring_shape = {"ty": "el", "nm": "Ellipse Path 1", "p": static([0, 0]), "s": static([44, 44]), "d": 1}
    ring_end = keyframes([(0, 0), (26, 100)], ease_out=(0.3, 0), ease_in=(0.2, 1))
    ring = layer("Ring", 1, [group("Ring", [ring_shape, trim(ring_end), stroke(3.5)])], 60, (30, 30), rotation=static(-90))

    check_end = keyframes([(14, 0), (34, 100)], ease_out=(0.3, 0), ease_in=(0.1, 1))
    pop = keyframes([(14, [70, 70, 100]), (32, [108, 108, 100]), (46, [100, 100, 100])], ease_out=(0.3, 0), ease_in=(0.2, 1))
    fade = keyframes([(14, 0), (22, 100)])
    check_line = polyline([(-9.5, 0.5), (-3, 7), (10.5, -7)])
    check = layer("Check", 2, [group("Check", [check_line, trim(check_end), stroke(4)])], 60, (30, 30), scale=pop, opacity=fade, start=14)
    return document("AirFlow done", 60, 60, 60, 46, [check, ring])


def sparkle(radius, pinch=0.72):
    """A four-pointed star whose sides curve in toward its center."""
    reach = radius * pinch
    vertices = [[0, -radius], [radius, 0], [0, radius], [-radius, 0]]
    outs = [[0, reach], [-reach, 0], [0, -reach], [reach, 0]]
    ins = [[0, reach], [-reach, 0], [0, -reach], [reach, 0]]
    return bezier(vertices, ins, outs, True)


def spark():
    """Three stars take turns swelling while the model on the Mac works."""
    canvas, loop_end = 120, 96
    stars = [((50, 66), 34, 0), ((90, 34), 15, 24), ((92, 92), 10, 48)]
    layers = []
    for index, (center, radius, delay) in enumerate(stars):
        times = [delay - loop_end, delay - loop_end + 24, delay, delay + 24, delay + loop_end, delay + loop_end + 24]
        sizes = [62, 100, 62, 100, 62, 100]
        fades = [45, 100, 45, 100, 45, 100]
        pulse = keyframes([(time, [size, size, 100]) for time, size in zip(times, sizes)], ease_out=(0.4, 0), ease_in=(0.6, 1))
        fade = keyframes(list(zip(times, fades)), ease_out=(0.4, 0), ease_in=(0.6, 1))
        layers.append(layer(f"Star {index + 1}", index + 1, [group("Star", [sparkle(radius), fill()])], loop_end, center, scale=pulse, opacity=fade))
    return document("AirFlow spark", canvas, canvas, loop_end, 24, layers)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for name, build in (("rotor", rotor), ("breeze", breeze), ("done", done), ("spark", spark)):
        path = OUT / f"{name}.json"
        path.write_text(json.dumps(build(), separators=(",", ":")) + "\n")
        print(f"wrote {path.relative_to(OUT.parent.parent.parent)} ({path.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
