#!/usr/bin/env python3
"""Generate a colorful, fun UltraXReal app icon at all macOS sizes."""

from PIL import Image, ImageDraw, ImageFont, ImageFilter
import math
import os

def create_icon(size):
    """Create the UltraXReal icon at the given pixel size."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    pad = size * 0.04
    r = size * 0.22  # corner radius

    # Background: rich gradient from deep purple to electric blue
    for y in range(size):
        t = y / size
        # Purple (88, 28, 135) -> Blue (15, 82, 186) -> Cyan (6, 182, 212)
        if t < 0.5:
            t2 = t * 2
            red = int(88 + (15 - 88) * t2)
            green = int(28 + (82 - 28) * t2)
            blue = int(135 + (186 - 135) * t2)
        else:
            t2 = (t - 0.5) * 2
            red = int(15 + (6 - 15) * t2)
            green = int(82 + (182 - 82) * t2)
            blue = int(186 + (212 - 186) * t2)
        draw.line([(int(pad), y), (size - int(pad), y)], fill=(red, green, blue, 255))

    # Apply rounded rectangle mask
    mask = Image.new("L", (size, size), 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.rounded_rectangle(
        [int(pad), int(pad), size - int(pad), size - int(pad)],
        radius=int(r),
        fill=255,
    )
    img.putalpha(mask)

    # Re-draw on masked image
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    # Draw gradient background with rounded rect
    for y in range(size):
        t = y / size
        if t < 0.5:
            t2 = t * 2
            red = int(88 + (15 - 88) * t2)
            green = int(28 + (82 - 28) * t2)
            blue = int(135 + (186 - 135) * t2)
        else:
            t2 = (t - 0.5) * 2
            red = int(15 + (6 - 15) * t2)
            green = int(82 + (182 - 82) * t2)
            blue = int(186 + (212 - 186) * t2)
        for x in range(size):
            if mask.getpixel((x, y)) > 0:
                canvas.putpixel((x, y), (red, green, blue, 255))

    draw = ImageDraw.Draw(canvas)

    # === Draw ultrawide monitor shape ===
    cx, cy = size * 0.5, size * 0.42
    mw = size * 0.72  # monitor width (ultrawide!)
    mh = size * 0.30  # monitor height
    mr = size * 0.03  # monitor corner radius
    bezel = size * 0.015

    # Monitor outer frame (dark)
    draw.rounded_rectangle(
        [cx - mw/2, cy - mh/2, cx + mw/2, cy + mh/2],
        radius=int(mr),
        fill=(20, 20, 40, 255),
    )

    # Monitor screen area
    sx, sy = cx - mw/2 + bezel*2, cy - mh/2 + bezel*2
    sw, sh = mw - bezel*4, mh - bezel*4

    # Rainbow gradient on screen - horizontal bands of color
    colors = [
        (255, 59, 48),    # Red
        (255, 149, 0),    # Orange
        (255, 204, 0),    # Yellow
        (52, 199, 89),    # Green
        (0, 199, 190),    # Teal
        (48, 176, 255),   # Blue
        (88, 86, 214),    # Indigo
        (175, 82, 222),   # Purple
    ]

    screen_left = int(sx)
    screen_right = int(sx + sw)
    screen_top = int(sy)
    screen_bottom = int(sy + sh)

    # Draw vertical rainbow stripes on the screen
    num_stripes = len(colors)
    stripe_width = sw / num_stripes
    for i, color in enumerate(colors):
        x1 = int(sx + i * stripe_width)
        x2 = int(sx + (i + 1) * stripe_width)
        # Slight gradient within each stripe
        for x in range(x1, min(x2 + 1, screen_right)):
            blend = (x - x1) / max(stripe_width, 1)
            next_color = colors[(i + 1) % num_stripes]
            r = int(color[0] + (next_color[0] - color[0]) * blend)
            g = int(color[1] + (next_color[1] - color[1]) * blend)
            b = int(color[2] + (next_color[2] - color[2]) * blend)
            draw.line([(x, screen_top), (x, screen_bottom)], fill=(r, g, b, 255))

    # Add a subtle white glow/reflection on the screen
    for y in range(screen_top, min(screen_top + int(sh * 0.3), screen_bottom)):
        alpha = int(60 * (1 - (y - screen_top) / (sh * 0.3)))
        draw.line([(screen_left, y), (screen_right, y)], fill=(255, 255, 255, alpha))

    # Monitor stand
    stand_w = size * 0.08
    stand_h = size * 0.10
    stand_x = cx - stand_w/2
    stand_y = cy + mh/2
    draw.rectangle(
        [stand_x, stand_y, stand_x + stand_w, stand_y + stand_h],
        fill=(30, 30, 50, 255),
    )

    # Monitor base
    base_w = size * 0.22
    base_h = size * 0.025
    base_r = size * 0.012
    draw.rounded_rectangle(
        [cx - base_w/2, stand_y + stand_h, cx + base_w/2, stand_y + stand_h + base_h],
        radius=int(base_r),
        fill=(30, 30, 50, 255),
    )

    # === Draw stylized AR glasses below the monitor ===
    gy = size * 0.78
    gw = size * 0.45
    gh = size * 0.09

    # Left lens
    lens_w = gw * 0.40
    lens_h = gh
    lens_r = size * 0.02
    draw.rounded_rectangle(
        [cx - gw/2, gy - gh/2, cx - gw/2 + lens_w, gy + gh/2],
        radius=int(lens_r),
        fill=(255, 255, 255, 40),
        outline=(255, 255, 255, 160),
        width=max(1, int(size * 0.005)),
    )

    # Right lens
    draw.rounded_rectangle(
        [cx + gw/2 - lens_w, gy - gh/2, cx + gw/2, gy + gh/2],
        radius=int(lens_r),
        fill=(255, 255, 255, 40),
        outline=(255, 255, 255, 160),
        width=max(1, int(size * 0.005)),
    )

    # Bridge
    bridge_y = gy
    draw.arc(
        [cx - gw * 0.12, gy - gh * 0.6, cx + gw * 0.12, gy + gh * 0.3],
        start=200, end=340,
        fill=(255, 255, 255, 160),
        width=max(1, int(size * 0.005)),
    )

    # Temple arms (sides)
    arm_len = size * 0.06
    arm_w = max(1, int(size * 0.005))
    draw.line(
        [(cx - gw/2, gy), (cx - gw/2 - arm_len, gy - size * 0.02)],
        fill=(255, 255, 255, 140),
        width=arm_w,
    )
    draw.line(
        [(cx + gw/2, gy), (cx + gw/2 + arm_len, gy - size * 0.02)],
        fill=(255, 255, 255, 140),
        width=arm_w,
    )

    # === Add "21:9" text below glasses ===
    text_y = size * 0.88
    try:
        font_size = int(size * 0.07)
        font = ImageFont.truetype("/System/Library/Fonts/SFCompact.ttf", font_size)
    except (OSError, IOError):
        try:
            font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", font_size)
        except (OSError, IOError):
            font = ImageFont.load_default()

    text = "21:9"
    bbox = draw.textbbox((0, 0), text, font=font)
    tw = bbox[2] - bbox[0]
    draw.text(
        (cx - tw/2, text_y),
        text,
        fill=(255, 255, 255, 200),
        font=font,
    )

    return canvas


def main():
    # macOS icon sizes: name -> (pixel_size)
    sizes = {
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    }

    iconset_dir = os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "..", "UltraXReal", "UltraXReal", "Assets.xcassets",
        "AppIcon.appiconset",
    )
    os.makedirs(iconset_dir, exist_ok=True)

    # Also create .iconset for iconutil
    iconset_path = os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "..", "UltraXReal.iconset",
    )
    os.makedirs(iconset_path, exist_ok=True)

    # Generate at max size and downscale for quality
    master = create_icon(1024)

    for name, px in sizes.items():
        icon = master.resize((px, px), Image.LANCZOS)
        # Save to iconset
        icon.save(os.path.join(iconset_path, name))
        # Save to xcassets
        icon.save(os.path.join(iconset_dir, name))
        print(f"  Created {name} ({px}x{px})")

    # Save a preview
    preview_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "icon_preview.png")
    master.save(preview_path)
    print(f"\n  Preview saved to {preview_path}")
    print(f"  Iconset saved to {iconset_path}")


if __name__ == "__main__":
    main()
