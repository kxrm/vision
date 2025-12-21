#!/usr/bin/env python3
"""Add percentage grid overlay or crosshairs to an image for position estimation."""

import sys
from PIL import Image, ImageDraw, ImageFont


def add_crosshairs(input_path, output_path=None, target_x=None, target_y=None):
    """Add prominent crosshairs to an image.

    Args:
        input_path: Path to the image
        output_path: Output path (default: adds _crosshairs suffix)
        target_x: X coordinate for crosshairs (default: center)
        target_y: Y coordinate for crosshairs (default: center)

    If target_x/target_y are provided, crosshairs are drawn at those pixel
    coordinates. Otherwise, crosshairs are drawn at the image center.
    """
    if output_path is None:
        parts = input_path.rsplit('.', 1)
        output_path = f"{parts[0]}_crosshairs.{parts[1]}" if len(parts) > 1 else f"{input_path}_crosshairs"

    img = Image.open(input_path)
    draw = ImageDraw.Draw(img, 'RGBA')

    width, height = img.size
    center_x = target_x if target_x is not None else width // 2
    center_y = target_y if target_y is not None else height // 2

    # Draw prominent crosshairs with multiple colors for visibility on any background

    # Black outline (widest, drawn first)
    draw.line([(0, center_y), (width, center_y)], fill=(0, 0, 0, 255), width=5)
    draw.line([(center_x, 0), (center_x, height)], fill=(0, 0, 0, 255), width=5)

    # White middle layer
    draw.line([(0, center_y), (width, center_y)], fill=(255, 255, 255, 255), width=3)
    draw.line([(center_x, 0), (center_x, height)], fill=(255, 255, 255, 255), width=3)

    # Magenta core
    draw.line([(0, center_y), (width, center_y)], fill=(255, 0, 255, 255), width=1)
    draw.line([(center_x, 0), (center_x, height)], fill=(255, 0, 255, 255), width=1)

    # 45-degree X pattern in cyan (contrasting color) near center
    diag_len = 40
    # Cyan X with black outline
    for color, width_val in [((0, 0, 0, 255), 4), ((0, 255, 255, 255), 2)]:
        draw.line([(center_x - diag_len, center_y - diag_len),
                   (center_x + diag_len, center_y + diag_len)], fill=color, width=width_val)
        draw.line([(center_x + diag_len, center_y - diag_len),
                   (center_x - diag_len, center_y + diag_len)], fill=color, width=width_val)

    # Multi-ring target at center for maximum visibility
    # Outer black ring
    radius = 12
    draw.ellipse([center_x - radius, center_y - radius,
                  center_x + radius, center_y + radius],
                 outline=(0, 0, 0, 255), width=3)
    # White ring
    radius = 10
    draw.ellipse([center_x - radius, center_y - radius,
                  center_x + radius, center_y + radius],
                 outline=(255, 255, 255, 255), width=2)
    # Magenta ring
    radius = 7
    draw.ellipse([center_x - radius, center_y - radius,
                  center_x + radius, center_y + radius],
                 outline=(255, 0, 255, 255), width=2)

    # Center dot: black outline + yellow fill + red center for visibility
    draw.ellipse([center_x - 5, center_y - 5, center_x + 5, center_y + 5],
                 fill=(0, 0, 0, 255))
    draw.ellipse([center_x - 4, center_y - 4, center_x + 4, center_y + 4],
                 fill=(255, 255, 0, 255))
    draw.ellipse([center_x - 2, center_y - 2, center_x + 2, center_y + 2],
                 fill=(255, 0, 0, 255))

    # Label
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 12)
    except:
        font = ImageFont.load_default()

    label = "CLICK POINT"
    bbox = draw.textbbox((0, 0), label, font=font)
    text_w = bbox[2] - bbox[0]
    text_x = center_x - text_w // 2
    text_y = center_y + radius + 5

    # Background for label
    draw.rectangle([text_x - 3, text_y - 1, text_x + text_w + 3, text_y + 14],
                   fill=(0, 0, 0, 200))
    draw.text((text_x, text_y), label, fill=(255, 0, 255, 255), font=font)

    # Save (convert RGBA to RGB for JPEG compatibility)
    if output_path.lower().endswith(('.jpg', '.jpeg')):
        if img.mode == 'RGBA':
            background = Image.new('RGB', img.size, (255, 255, 255))
            background.paste(img, mask=img.split()[3])
            img = background
        elif img.mode != 'RGB':
            img = img.convert('RGB')

    img.save(output_path)
    print(f"Crosshairs overlay saved: {output_path}")
    return output_path


def add_grid_overlay(input_path, output_path=None):
    """Add a percentage grid overlay to help estimate object positions."""

    if output_path is None:
        # Insert _grid before extension
        parts = input_path.rsplit('.', 1)
        output_path = f"{parts[0]}_grid.{parts[1]}" if len(parts) > 1 else f"{input_path}_grid"

    # Open image
    img = Image.open(input_path)
    draw = ImageDraw.Draw(img, 'RGBA')

    width, height = img.size

    # Grid lines at 0%, 25%, 50%, 75%, 100%
    percentages = [0, 25, 50, 75, 100]

    # Colors
    line_color = (255, 255, 0, 180)  # Yellow, semi-transparent
    center_color = (255, 0, 0, 200)  # Red for center lines
    text_color = (255, 255, 255, 255)  # White
    text_bg = (0, 0, 0, 180)  # Black background for text

    # Try to use a monospace font, fall back to default
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 14)
        font_small = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 11)
    except:
        font = ImageFont.load_default()
        font_small = font

    # Draw vertical lines (for X percentage)
    for pct in percentages:
        x = int(width * pct / 100)
        color = center_color if pct == 50 else line_color
        line_width = 2 if pct == 50 else 1
        draw.line([(x, 0), (x, height)], fill=color, width=line_width)

        # Label at top
        label = f"{pct}%"
        bbox = draw.textbbox((0, 0), label, font=font_small)
        text_w = bbox[2] - bbox[0]
        text_h = bbox[3] - bbox[1]
        text_x = x - text_w // 2
        text_y = 5

        # Background rectangle
        draw.rectangle([text_x - 2, text_y - 1, text_x + text_w + 2, text_y + text_h + 1], fill=text_bg)
        draw.text((text_x, text_y), label, fill=text_color, font=font_small)

    # Draw horizontal lines (for Y percentage)
    for pct in percentages:
        y = int(height * pct / 100)
        color = center_color if pct == 50 else line_color
        line_width = 2 if pct == 50 else 1
        draw.line([(0, y), (width, y)], fill=color, width=line_width)

        # Label on left
        label = f"{pct}%"
        bbox = draw.textbbox((0, 0), label, font=font_small)
        text_w = bbox[2] - bbox[0]
        text_h = bbox[3] - bbox[1]
        text_x = 5
        text_y = y - text_h // 2

        # Background rectangle
        draw.rectangle([text_x - 2, text_y - 1, text_x + text_w + 2, text_y + text_h + 1], fill=text_bg)
        draw.text((text_x, text_y), label, fill=text_color, font=font_small)

    # Add 10% grid lines (lighter, for finer estimation)
    fine_color = (255, 255, 0, 80)  # Very faint yellow
    for pct in range(10, 100, 10):
        if pct not in percentages:  # Skip 25, 50, 75 (already drawn)
            x = int(width * pct / 100)
            draw.line([(x, 0), (x, height)], fill=fine_color, width=1)
            y = int(height * pct / 100)
            draw.line([(0, y), (width, y)], fill=fine_color, width=1)

    # Add corner coordinates helper
    helpers = [
        ("(0,0)", 5, 20),
        ("(100,0)", width - 50, 20),
        ("(0,100)", 5, height - 20),
        ("(100,100)", width - 65, height - 20),
        ("CENTER (50,50)", width // 2 - 45, height // 2 + 5),
    ]

    for text, x, y in helpers:
        bbox = draw.textbbox((0, 0), text, font=font_small)
        text_w = bbox[2] - bbox[0]
        text_h = bbox[3] - bbox[1]
        draw.rectangle([x - 2, y - 1, x + text_w + 2, y + text_h + 1], fill=text_bg)
        draw.text((x, y), text, fill=text_color, font=font_small)

    # Add usage hint at bottom
    hint = "Grid: X% from left, Y% from top | Use --calc-frame <left> <top> <right> <bottom>"
    bbox = draw.textbbox((0, 0), hint, font=font_small)
    text_w = bbox[2] - bbox[0]
    text_h = bbox[3] - bbox[1]
    text_x = width // 2 - text_w // 2
    text_y = height - text_h - 8
    draw.rectangle([text_x - 4, text_y - 2, text_x + text_w + 4, text_y + text_h + 2], fill=text_bg)
    draw.text((text_x, text_y), hint, fill=text_color, font=font_small)

    # Save (convert RGBA to RGB for JPEG compatibility)
    if output_path.lower().endswith(('.jpg', '.jpeg')) and img.mode == 'RGBA':
        # Create white background and composite
        background = Image.new('RGB', img.size, (255, 255, 255))
        background.paste(img, mask=img.split()[3])  # Use alpha channel as mask
        img = background
    img.save(output_path)
    print(f"Grid overlay saved: {output_path}")
    return output_path

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: grid_overlay.py [OPTIONS] <input_image> [output_image]")
        print("  --crosshairs           Add crosshairs at center")
        print("  --crosshairs X,Y       Add crosshairs at pixel coordinates X,Y")
        print("  --crosshairs-grid X,Y  Add crosshairs at grid percentage X%,Y%")
        print("  (default)              Add percentage grid overlay")
        sys.exit(1)

    args = sys.argv[1:]
    use_crosshairs = False
    target_x = None
    target_y = None
    use_grid_coords = False

    if args[0] == "--crosshairs":
        use_crosshairs = True
        args = args[1:]
        # Check if coordinates provided
        if args and ',' in args[0] and not args[0].endswith(('.jpg', '.png', '.jpeg')):
            coords = args[0].split(',')
            target_x = int(coords[0])
            target_y = int(coords[1])
            args = args[1:]
    elif args[0] == "--crosshairs-grid":
        use_crosshairs = True
        use_grid_coords = True
        args = args[1:]
        if args and ',' in args[0]:
            coords = args[0].split(',')
            target_x = float(coords[0])  # Will be converted to pixels after loading image
            target_y = float(coords[1])
            args = args[1:]

    if not args:
        print("ERROR: No input image specified")
        sys.exit(1)

    input_path = args[0]
    output_path = args[1] if len(args) > 1 else None

    if use_crosshairs:
        # If grid coordinates, need to convert after knowing image size
        if use_grid_coords and target_x is not None:
            img = Image.open(input_path)
            width, height = img.size
            img.close()
            target_x = int(width * target_x / 100)
            target_y = int(height * target_y / 100)
        add_crosshairs(input_path, output_path, target_x, target_y)
    else:
        add_grid_overlay(input_path, output_path)
