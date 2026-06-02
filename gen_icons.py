#!/usr/bin/env python3
"""Generate app icons for NesTimer — clock with lock/shield accent."""
import os
from PIL import Image, ImageDraw, ImageFont

# Brand colors
BG_START = (88, 101, 242)   # indigo/blue
BG_END = (168, 85, 247)     # purple
FG = (255, 255, 255)
ACCENT = (251, 191, 36)     # amber for highlights

def make_icon(size: int, variant: str = "app") -> Image.Image:
    """Create an icon at the given size.
    variant: 'app' (clock + lock), 'agent' (clock + person), 'controller' (clock + gear)
    """
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # Rounded-square background with gradient
    radius = int(size * 0.22)
    # Draw gradient manually by stacking rects
    for y in range(size):
        t = y / size
        r = int(BG_START[0] * (1 - t) + BG_END[0] * t)
        g = int(BG_START[1] * (1 - t) + BG_END[1] * t)
        b = int(BG_START[2] * (1 - t) + BG_END[2] * t)
        d.line([(0, y), (size, y)], fill=(r, g, b))

    # Apply rounded corners via mask
    mask = Image.new("L", (size, size), 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle([0, 0, size, size], radius=radius, fill=255)
    img.putalpha(mask)

    # Clock face
    cx, cy = size // 2, int(size * 0.48)
    clock_r = int(size * 0.32)
    # White ring
    ring_w = max(2, int(size * 0.035))
    d.ellipse(
        [cx - clock_r, cy - clock_r, cx + clock_r, cy + clock_r],
        outline=FG, width=ring_w
    )

    # Clock hands — showing ~10:10 (classic clock pose)
    hand_w = max(2, int(size * 0.035))
    # Hour hand (shorter) pointing to 10
    import math
    def hand(angle_deg, length_ratio):
        a = math.radians(angle_deg - 90)
        x = cx + int(math.cos(a) * clock_r * length_ratio)
        y = cy + int(math.sin(a) * clock_r * length_ratio)
        d.line([cx, cy, x, y], fill=FG, width=hand_w)
    hand(300, 0.55)   # hour → 10 (300°)
    hand(60, 0.75)    # minute → 2 (60°)

    # Center dot
    dot_r = max(2, int(size * 0.04))
    d.ellipse([cx - dot_r, cy - dot_r, cx + dot_r, cy + dot_r], fill=ACCENT)

    # Hour markers (12, 3, 6, 9)
    marker_r = max(2, int(size * 0.025))
    for angle in [0, 90, 180, 270]:
        a = math.radians(angle - 90)
        mx = cx + int(math.cos(a) * clock_r * 0.85)
        my = cy + int(math.sin(a) * clock_r * 0.85)
        d.ellipse([mx - marker_r, my - marker_r, mx + marker_r, my + marker_r], fill=FG)

    # Accent badge bottom-right — varies by variant
    badge_cx = int(size * 0.78)
    badge_cy = int(size * 0.82)
    badge_r = int(size * 0.18)
    # Amber circle
    d.ellipse(
        [badge_cx - badge_r, badge_cy - badge_r, badge_cx + badge_r, badge_cy + badge_r],
        fill=ACCENT, outline=FG, width=max(2, int(size * 0.02))
    )

    # Symbol inside badge
    if variant == "app":
        # Lock shape
        lw = int(badge_r * 1.0)
        lh = int(badge_r * 0.7)
        lx = badge_cx - lw // 2
        ly = badge_cy - lh // 2 + int(badge_r * 0.1)
        d.rounded_rectangle([lx, ly, lx + lw, ly + lh],
                            radius=max(2, int(badge_r * 0.15)), fill=(40, 30, 80))
        # Shackle
        sh_r = int(badge_r * 0.4)
        sh_w = max(2, int(size * 0.025))
        d.arc([badge_cx - sh_r, badge_cy - sh_r - int(badge_r * 0.1),
               badge_cx + sh_r, badge_cy + sh_r - int(badge_r * 0.1)],
              start=180, end=360, fill=(40, 30, 80), width=sh_w)
    elif variant == "agent":
        # Eye/watcher symbol
        ew = int(badge_r * 1.2)
        eh = int(badge_r * 0.7)
        d.ellipse([badge_cx - ew // 2, badge_cy - eh // 2,
                   badge_cx + ew // 2, badge_cy + eh // 2], fill=(40, 30, 80))
        pr = int(badge_r * 0.3)
        d.ellipse([badge_cx - pr, badge_cy - pr, badge_cx + pr, badge_cy + pr], fill=FG)
    elif variant == "controller":
        # Gear simplified as star/plus
        gw = max(2, int(size * 0.035))
        d.line([badge_cx - int(badge_r * 0.6), badge_cy,
                badge_cx + int(badge_r * 0.6), badge_cy], fill=(40, 30, 80), width=gw)
        d.line([badge_cx, badge_cy - int(badge_r * 0.6),
                badge_cx, badge_cy + int(badge_r * 0.6)], fill=(40, 30, 80), width=gw)
        cr = int(badge_r * 0.3)
        d.ellipse([badge_cx - cr, badge_cy - cr, badge_cx + cr, badge_cy + cr], fill=(40, 30, 80))

    return img


def flatten_ios(icon: Image.Image) -> Image.Image:
    """iOS app icons must be a full opaque square (no alpha) — App Store rejects
    transparency (error 90717). Composite the rounded icon over a full gradient
    so the transparent corners are filled seamlessly; iOS masks corners itself."""
    size = icon.width
    bg = Image.new("RGB", (size, size))
    px = bg.load()
    for y in range(size):
        t = y / size
        r = int(BG_START[0] * (1 - t) + BG_END[0] * t)
        g = int(BG_START[1] * (1 - t) + BG_END[1] * t)
        b = int(BG_START[2] * (1 - t) + BG_END[2] * t)
        for x in range(size):
            px[x, y] = (r, g, b)
    bg.paste(icon, (0, 0), icon)
    return bg  # RGB => no alpha channel


def make_iconset(output_dir: str, variant: str):
    os.makedirs(output_dir, exist_ok=True)
    # macOS sizes (alpha allowed — rounded corners + shadow look)
    sizes = [16, 32, 64, 128, 256, 512, 1024]
    for s in sizes:
        icon = make_icon(s, variant)
        icon.save(os.path.join(output_dir, f"icon_{s}.png"))
    # iOS marketing icon: 1024 flattened, no alpha (App Store requirement)
    flatten_ios(make_icon(1024, variant)).save(
        os.path.join(output_dir, "icon_1024_ios.png"))
    print(f"✓ Generated {variant} icons in {output_dir}")


if __name__ == "__main__":
    base = os.path.dirname(os.path.abspath(__file__))
    make_iconset(os.path.join(base, "icons/parent"), "controller")
    make_iconset(os.path.join(base, "icons/agent"), "agent")

    # Preview
    preview = Image.new("RGBA", (1024 * 3 + 40, 1024), (255, 255, 255, 0))
    preview.paste(make_icon(1024, "controller"), (0, 0))
    preview.paste(make_icon(1024, "agent"), (1024 + 20, 0))
    preview.paste(make_icon(1024, "app"), (2048 + 40, 0))
    preview.thumbnail((900, 300))
    preview.save(os.path.join(base, "icons/preview.png"))
    print(f"✓ Preview at {os.path.join(base, 'icons/preview.png')}")
