"""The geometry of AirFlow's mark: the fan from Bootstrap Icons (MIT).

    https://icons.getbootstrap.com/icons/fan/

The app icon and the menu bar icon use the icon's two paths as they are. The rotor animation
needs the same shapes as Bezier curves, so this module also reads SVG path data. It handles the
commands the icon uses: move, line, cubic and quadratic curves, arcs, and close.
"""

import math

VIEW_BOX = 16
CENTER = VIEW_BOX / 2

# The blades and the hub.
BLADES = (
    "M10 3c0 1.313-.304 2.508-.8 3.4a2 2 0 0 0-1.484-.38c-.28-.982-.91-2.04-1.838-2.969a8 8 0 0 "
    "0-.491-.454A6 6 0 0 1 8 2c.691 0 1.355.117 1.973.332Q10 2.661 10 3m0 5q0 .11-.012.217c1.018-.019 "
    "2.2-.353 3.331-1.006a8 8 0 0 0 .57-.361 6 6 0 0 0-2.53-3.823 9 9 0 0 1-.145.64c-.34 1.269-.944 "
    "2.346-1.656 3.079.277.343.442.78.442 1.254m-.137.728a2 2 0 0 1-1.07 1.109c.525.87 1.405 1.725 "
    "2.535 2.377q.3.174.605.317a6 6 0 0 0 2.053-4.111q-.311.11-.641.199c-1.264.339-2.493.356-3.482.11ZM8 "
    "10c-.45 0-.866-.149-1.2-.4-.494.89-.796 2.082-.796 3.391q0 .346.027.678A6 6 0 0 0 8 14c.94 0 "
    "1.83-.216 2.623-.602a8 8 0 0 1-.497-.458c-.925-.926-1.555-1.981-1.836-2.96Q8.149 10 8 10M6 8q0-.12.014-.239c-1.02.017-2.205.351-3.34 "
    "1.007a8 8 0 0 0-.568.359 6 6 0 0 0 2.525 3.839 8 8 0 0 1 .148-.653c.34-1.267.94-2.342 "
    "1.65-3.075A2 2 0 0 1 6 8m-3.347-.632c1.267-.34 2.498-.355 3.488-.107.196-.494.583-.89 "
    "1.07-1.1-.524-.874-1.406-1.733-2.541-2.388a8 8 0 0 0-.594-.312 6 6 0 0 0-2.06 4.106q.309-.11.637-.199M8 "
    "9a1 1 0 1 0 0-2 1 1 0 0 0 0 2"
)

# The housing: a ring one unit wide, centered on a radius of 7.5.
HOUSING = "M8 15A7 7 0 1 1 8 1a7 7 0 0 1 0 14m0 1A8 8 0 1 0 8 0a8 8 0 0 0 0 16"
HOUSING_RADIUS = 7.5
HOUSING_WIDTH = 1


def svg(size, parts=(BLADES, HOUSING)):
    """The mark, or some of its parts, as an SVG filled black. Every part keeps the same view
    box, so parts drawn as separate layers line up."""
    paths = "".join(f'  <path fill="#000000" d="{data}"/>\n' for data in parts)
    return (
        '<?xml version="1.0" standalone="no"?>\n'
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 {VIEW_BOX} {VIEW_BOX}">\n'
        f"{paths}</svg>\n"
    )


class Reader:
    """Reads numbers and arc flags out of SVG path data."""

    def __init__(self, text):
        self.text = text
        self.at = 0

    def skip(self):
        while self.at < len(self.text) and self.text[self.at] in " ,\n\t":
            self.at += 1

    def command(self):
        """The next command letter, or None when a number comes next."""
        self.skip()
        if self.at < len(self.text) and self.text[self.at].isalpha():
            self.at += 1
            return self.text[self.at - 1]
        return None

    def done(self):
        self.skip()
        return self.at >= len(self.text)

    def number(self):
        self.skip()
        start = self.at
        if self.text[self.at] in "+-":
            self.at += 1
        seen_point = False
        while self.at < len(self.text) and (self.text[self.at].isdigit() or (self.text[self.at] == "." and not seen_point)):
            seen_point = seen_point or self.text[self.at] == "."
            self.at += 1
        return float(self.text[start:self.at])

    def flag(self):
        """An arc flag is one digit, and the next number may follow it with no space."""
        self.skip()
        self.at += 1
        return self.text[self.at - 1] == "1"


def arc_to_cubics(start, rx, ry, rotation, large, sweep, end):
    """An elliptical arc from the SVG endpoint form, as cubic curves of at most a quarter turn."""
    if start == end:
        return []
    if rx == 0 or ry == 0:
        return [(start, end, end)]
    phi = math.radians(rotation)
    cos, sin = math.cos(phi), math.sin(phi)
    dx, dy = (start[0] - end[0]) / 2, (start[1] - end[1]) / 2
    x1, y1 = cos * dx + sin * dy, -sin * dx + cos * dy
    rx, ry = abs(rx), abs(ry)
    stretch = (x1 / rx) ** 2 + (y1 / ry) ** 2
    if stretch > 1:
        rx, ry = rx * math.sqrt(stretch), ry * math.sqrt(stretch)
    numerator = max(rx**2 * ry**2 - rx**2 * y1**2 - ry**2 * x1**2, 0)
    factor = math.sqrt(numerator / (rx**2 * y1**2 + ry**2 * x1**2)) * (-1 if large == sweep else 1)
    cx1, cy1 = factor * rx * y1 / ry, -factor * ry * x1 / rx
    cx = cos * cx1 - sin * cy1 + (start[0] + end[0]) / 2
    cy = sin * cx1 + cos * cy1 + (start[1] + end[1]) / 2

    def angle(ux, uy, vx, vy):
        value = math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        return value

    theta = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
    delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
    if not sweep and delta > 0:
        delta -= 2 * math.pi
    elif sweep and delta < 0:
        delta += 2 * math.pi

    pieces = max(1, math.ceil(abs(delta) / (math.pi / 2) - 1e-9))
    step = delta / pieces
    handle = 4 / 3 * math.tan(step / 4)

    def point(t):
        return (cx + rx * math.cos(t) * cos - ry * math.sin(t) * sin, cy + rx * math.cos(t) * sin + ry * math.sin(t) * cos)

    def tangent(t):
        return (-rx * math.sin(t) * cos - ry * math.cos(t) * sin, -rx * math.sin(t) * sin + ry * math.cos(t) * cos)

    cubics = []
    for index in range(pieces):
        t0, t1 = theta + index * step, theta + (index + 1) * step
        p0, p1 = point(t0), point(t1)
        d0, d1 = tangent(t0), tangent(t1)
        cubics.append((
            (p0[0] + handle * d0[0], p0[1] + handle * d0[1]),
            (p1[0] - handle * d1[0], p1[1] - handle * d1[1]),
            p1 if index < pieces - 1 else end,
        ))
    return cubics


def subpaths(data):
    """The path as a list of closed shapes. Each is a start point and a list of cubic curves,
    (control, control, end), in the icon's own coordinates."""
    reader = Reader(data)
    shapes, start, current, curves = [], None, (0.0, 0.0), []
    command = None

    def finish():
        if start is not None and curves:
            shapes.append((start, list(curves)))

    while not reader.done():
        command = reader.command() or ("L" if command == "M" else "l" if command == "m" else command)
        relative = command.islower()
        kind = command.upper()

        def point():
            x, y = reader.number(), reader.number()
            return (current[0] + x, current[1] + y) if relative else (x, y)

        if kind == "M":
            finish()
            current = point()
            start, curves = current, []
        elif kind == "L":
            end = point()
            curves.append((current, end, end))
            current = end
        elif kind == "C":
            first, second, end = point(), point(), point()
            curves.append((first, second, end))
            current = end
        elif kind == "Q":
            control, end = point(), point()
            first = (current[0] + 2 / 3 * (control[0] - current[0]), current[1] + 2 / 3 * (control[1] - current[1]))
            second = (end[0] + 2 / 3 * (control[0] - end[0]), end[1] + 2 / 3 * (control[1] - end[1]))
            curves.append((first, second, end))
            current = end
        elif kind == "A":
            rx, ry, rotation = reader.number(), reader.number(), reader.number()
            large, sweep = reader.flag(), reader.flag()
            end = point()
            curves.extend(arc_to_cubics(current, rx, ry, rotation, large, sweep, end))
            current = end
        elif kind == "Z":
            finish()
            current = start
            # Path data may continue after a close with no new move, from the same start point.
            curves = []
        else:
            raise ValueError(f"unsupported path command {command}")
    finish()
    return shapes
