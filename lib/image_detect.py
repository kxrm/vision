#!/usr/bin/env python3
"""
Image region detection using macOS Vision framework.
Detects large content images (product photos, article images, hero images)
while filtering out icons, avatars, and logos.
"""

import sys
import json
import argparse
import hashlib
from pathlib import Path
from typing import List, Dict, Optional

import Quartz
from Foundation import NSURL
import objc
from PIL import Image

# Add lib directory to path for sibling imports
_lib_dir = Path(__file__).parent
if str(_lib_dir) not in sys.path:
    sys.path.insert(0, str(_lib_dir))

from image_resize import resize_for_claude

# Load Vision framework
objc.loadBundle('Vision', globals(),
                bundle_path='/System/Library/Frameworks/Vision.framework')


def detect_rectangles(image_path: str, min_size_pct: float = 3.0) -> List[Dict]:
    """
    Detect rectangular regions in image using Apple Vision.

    Args:
        image_path: Path to screenshot
        min_size_pct: Minimum size as percentage of image (default 3%)

    Returns:
        List of rectangle observations with bounds
    """
    # Load image via Quartz
    image_url = NSURL.fileURLWithPath_(image_path)
    image_source = Quartz.CGImageSourceCreateWithURL(image_url, None)
    if not image_source:
        return []

    cg_image = Quartz.CGImageSourceCreateImageAtIndex(image_source, 0, None)
    if not cg_image:
        return []

    img_width = Quartz.CGImageGetWidth(cg_image)
    img_height = Quartz.CGImageGetHeight(cg_image)

    # Create request handler
    request_handler = VNImageRequestHandler.alloc().initWithCGImage_options_(
        cg_image, None
    )

    # Create rectangle detection request
    request = VNDetectRectanglesRequest.alloc().init()
    request.setMaximumObservations_(50)  # Limit to 50 rectangles
    request.setMinimumSize_(min_size_pct / 100.0)  # Minimum as fraction
    request.setQuadratureTolerance_(15.0)  # Allow 15-degree deviation from 90
    request.setMinimumAspectRatio_(0.2)  # Allow tall/wide rectangles
    request.setMaximumAspectRatio_(5.0)

    # Perform detection
    success = request_handler.performRequests_error_([request], None)
    if not success:
        return []

    rectangles = []
    results = request.results()
    if not results:
        return []

    for observation in results:
        bbox = observation.boundingBox()
        # Convert from Vision coords (bottom-left origin) to top-left origin percentages
        x_pct = bbox.origin.x * 100
        y_pct = (1 - bbox.origin.y - bbox.size.height) * 100
        w_pct = bbox.size.width * 100
        h_pct = bbox.size.height * 100

        rectangles.append({
            'bounds_pct': {
                'x': round(x_pct, 2),
                'y': round(y_pct, 2),
                'width': round(w_pct, 2),
                'height': round(h_pct, 2)
            },
            'confidence': float(observation.confidence()),
            'pixel_size': {
                'width': int(w_pct * img_width / 100),
                'height': int(h_pct * img_height / 100)
            },
            'image_size': {
                'width': img_width,
                'height': img_height
            }
        })

    return rectangles


def is_image_region(image: Image.Image, region: Dict,
                    variance_threshold: float = 400.0) -> bool:
    """
    Determine if a region is likely a content image vs UI element.

    Uses color variance analysis - images have high color variance,
    solid UI elements (buttons, text blocks) have low variance.

    Args:
        image: PIL Image object
        region: Region dict with bounds_pct
        variance_threshold: Minimum color variance to be considered an image

    Returns:
        True if region appears to be a content image
    """
    bounds = region['bounds_pct']
    img_w, img_h = image.size

    # Convert percentage to pixels
    x = int(bounds['x'] * img_w / 100)
    y = int(bounds['y'] * img_h / 100)
    w = int(bounds['width'] * img_w / 100)
    h = int(bounds['height'] * img_h / 100)

    # Ensure valid bounds
    x = max(0, min(x, img_w - 1))
    y = max(0, min(y, img_h - 1))
    w = max(1, min(w, img_w - x))
    h = max(1, min(h, img_h - y))

    # Crop region
    try:
        crop = image.crop((x, y, x + w, y + h))
    except Exception:
        return False

    # Analyze color variance
    try:
        crop_rgb = crop.convert('RGB')
    except Exception:
        return False

    pixels = list(crop_rgb.getdata())

    if len(pixels) < 100:
        return False

    # Sample pixels for efficiency
    sample_size = min(1000, len(pixels))
    step = max(1, len(pixels) // sample_size)
    sampled = pixels[::step]

    if len(sampled) < 50:
        return False

    # Calculate variance across RGB channels
    r_vals = [p[0] for p in sampled]
    g_vals = [p[1] for p in sampled]
    b_vals = [p[2] for p in sampled]

    def variance(values):
        if not values:
            return 0
        mean = sum(values) / len(values)
        return sum((v - mean) ** 2 for v in values) / len(values)

    total_variance = variance(r_vals) + variance(g_vals) + variance(b_vals)

    return total_variance > variance_threshold


def filter_by_size(regions: List[Dict],
                   min_width_px: int = 100,
                   min_height_px: int = 100,
                   min_area_pct: float = 1.0) -> List[Dict]:
    """
    Filter regions by minimum size requirements.

    Args:
        regions: List of detected regions
        min_width_px: Minimum width in pixels
        min_height_px: Minimum height in pixels
        min_area_pct: Minimum area as percentage of image

    Returns:
        Filtered list of regions meeting size criteria
    """
    filtered = []
    for region in regions:
        px_size = region.get('pixel_size', {})
        bounds = region.get('bounds_pct', {})

        # Check pixel dimensions
        if px_size.get('width', 0) < min_width_px:
            continue
        if px_size.get('height', 0) < min_height_px:
            continue

        # Check area percentage
        area_pct = bounds.get('width', 0) * bounds.get('height', 0) / 100
        if area_pct < min_area_pct:
            continue

        filtered.append(region)

    return filtered


def remove_overlapping(regions: List[Dict], overlap_threshold: float = 0.5) -> List[Dict]:
    """
    Remove overlapping regions, keeping the larger ones.

    Args:
        regions: List of detected regions
        overlap_threshold: Minimum overlap ratio to consider duplicate

    Returns:
        Filtered list with overlaps removed
    """
    if not regions:
        return []

    # Sort by area (largest first)
    sorted_regions = sorted(
        regions,
        key=lambda r: r['bounds_pct']['width'] * r['bounds_pct']['height'],
        reverse=True
    )

    kept = []
    for region in sorted_regions:
        b = region['bounds_pct']
        r1 = (b['x'], b['y'], b['x'] + b['width'], b['y'] + b['height'])

        is_overlap = False
        for kept_region in kept:
            kb = kept_region['bounds_pct']
            r2 = (kb['x'], kb['y'], kb['x'] + kb['width'], kb['y'] + kb['height'])

            # Calculate intersection
            ix1 = max(r1[0], r2[0])
            iy1 = max(r1[1], r2[1])
            ix2 = min(r1[2], r2[2])
            iy2 = min(r1[3], r2[3])

            if ix1 < ix2 and iy1 < iy2:
                intersection = (ix2 - ix1) * (iy2 - iy1)
                area1 = (r1[2] - r1[0]) * (r1[3] - r1[1])

                if area1 > 0 and intersection / area1 > overlap_threshold:
                    is_overlap = True
                    break

        if not is_overlap:
            kept.append(region)

    return kept


def extract_image(image: Image.Image, region: Dict,
                  output_dir: str = "/tmp", resize: bool = True) -> str:
    """
    Extract detected image region to a file.

    Args:
        image: Source PIL Image
        region: Region dict with bounds_pct
        output_dir: Directory for extracted images
        resize: Resize to 1568px max for Claude API (default True)

    Returns:
        Path to extracted image file
    """
    bounds = region['bounds_pct']
    img_w, img_h = image.size

    x = int(bounds['x'] * img_w / 100)
    y = int(bounds['y'] * img_h / 100)
    w = int(bounds['width'] * img_w / 100)
    h = int(bounds['height'] * img_h / 100)

    # Ensure valid bounds
    x = max(0, min(x, img_w - 1))
    y = max(0, min(y, img_h - 1))
    w = max(1, min(w, img_w - x))
    h = max(1, min(h, img_h - y))

    crop = image.crop((x, y, x + w, y + h))

    # Generate unique filename based on content hash
    crop_bytes = crop.tobytes()
    hash_suffix = hashlib.md5(crop_bytes).hexdigest()[:8]
    filename = f"img_{hash_suffix}.jpg"
    output_path = Path(output_dir) / filename

    # Save as JPEG
    if crop.mode == 'RGBA':
        crop = crop.convert('RGB')
    crop.save(output_path, 'JPEG', quality=85)

    # Resize for Claude API if enabled (default: resize to 1568px max)
    if resize:
        resize_for_claude(str(output_path))

    return str(output_path)


def generate_description(region: Dict) -> str:
    """
    Generate a simple positional description for the image.

    Uses heuristics based on position and size.

    Args:
        region: Region dict with bounds and size info

    Returns:
        Brief description string
    """
    bounds = region['bounds_pct']

    # Determine size category
    area = bounds['width'] * bounds['height'] / 100
    if area > 25:
        size_cat = "large"
    elif area > 8:
        size_cat = "medium"
    else:
        size_cat = "small"

    # Determine position category
    y_center = bounds['y'] + bounds['height'] / 2
    x_center = bounds['x'] + bounds['width'] / 2

    if y_center < 25:
        v_pos = "top"
    elif y_center > 75:
        v_pos = "bottom"
    else:
        v_pos = "center"

    if x_center < 33:
        h_pos = "left"
    elif x_center > 67:
        h_pos = "right"
    else:
        h_pos = ""

    # Wide images at top are likely hero images
    if v_pos == "top" and bounds['width'] > 50:
        return "Hero image"

    # Generate description
    if h_pos:
        pos_str = f"{v_pos}-{h_pos}"
    else:
        pos_str = v_pos

    return f"Content image ({size_cat}, {pos_str})"


def is_colorful(pixels: list, threshold: float = 15.0) -> bool:
    """
    Check if pixels have color variety (not just grayscale).

    Photos have varied hues, text is mostly achromatic (R≈G≈B).

    Args:
        pixels: List of RGB tuples
        threshold: Minimum average color difference

    Returns:
        True if the region has actual colors (not just grayscale)
    """
    if not pixels:
        return False

    # Calculate average "colorfulness" - how much R, G, B differ from each other
    color_diffs = []
    for r, g, b in pixels:
        # Max difference between channels
        diff = max(abs(r - g), abs(g - b), abs(r - b))
        color_diffs.append(diff)

    avg_diff = sum(color_diffs) / len(color_diffs)
    return avg_diff > threshold


def scan_for_image_regions(image: Image.Image,
                           grid_size: int = 50,
                           min_width_px: int = 100,
                           min_height_px: int = 100,
                           variance_threshold: float = 400.0,
                           skip_top_pct: float = 10.0,
                           max_region_pct: float = 30.0) -> List[Dict]:
    """
    Scan image in a grid pattern to find regions with photo-like content.

    This complements rectangle detection by finding images that don't have
    crisp borders (like photos embedded in web pages).

    Args:
        image: PIL Image
        grid_size: Size of grid cells in pixels
        min_width_px: Minimum region width
        min_height_px: Minimum region height
        variance_threshold: Color variance threshold
        skip_top_pct: Skip top N% of image (browser chrome)
        max_region_pct: Maximum region size as % of image (skip if larger)

    Returns:
        List of detected image regions
    """
    img_w, img_h = image.size
    rgb_image = image.convert('RGB')

    # Create grid of cells and mark those with high variance
    cols = img_w // grid_size
    rows = img_h // grid_size

    if cols < 2 or rows < 2:
        return []

    # Calculate starting row to skip browser chrome
    skip_rows = int(rows * skip_top_pct / 100)

    # Analyze each cell - require BOTH variance AND colorfulness
    photo_cells = set()

    for row in range(skip_rows, rows):
        for col in range(cols):
            x = col * grid_size
            y = row * grid_size

            # Get cell pixels
            cell = rgb_image.crop((x, y, x + grid_size, y + grid_size))
            pixels = list(cell.getdata())

            if len(pixels) < 50:
                continue

            # Sample for efficiency
            step = max(1, len(pixels) // 100)
            sampled = pixels[::step]

            r_vals = [p[0] for p in sampled]
            g_vals = [p[1] for p in sampled]
            b_vals = [p[2] for p in sampled]

            def variance(values):
                if not values:
                    return 0
                mean = sum(values) / len(values)
                return sum((v - mean) ** 2 for v in values) / len(values)

            total_var = variance(r_vals) + variance(g_vals) + variance(b_vals)

            # Must have high variance AND actual color (not just B&W text)
            if total_var > variance_threshold and is_colorful(sampled, threshold=12.0):
                photo_cells.add((row, col))

    if not photo_cells:
        return []

    # Find connected regions of colorful cells
    visited = set()
    regions = []

    def flood_fill(start_row, start_col):
        """Find connected region starting from cell."""
        stack = [(start_row, start_col)]
        cells = []

        while stack:
            r, c = stack.pop()
            if (r, c) in visited:
                continue
            if (r, c) not in photo_cells:
                continue

            visited.add((r, c))
            cells.append((r, c))

            # Check 4 neighbors
            for dr, dc in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
                nr, nc = r + dr, c + dc
                if 0 <= nr < rows and 0 <= nc < cols:
                    if (nr, nc) not in visited and (nr, nc) in photo_cells:
                        stack.append((nr, nc))

        return cells

    for (r, c) in photo_cells:
        if (r, c) not in visited:
            region_cells = flood_fill(r, c)
            if region_cells:
                regions.append(region_cells)

    # Convert cell regions to bounding boxes
    results = []
    for region_cells in regions:
        if not region_cells:
            continue

        min_row = min(c[0] for c in region_cells)
        max_row = max(c[0] for c in region_cells)
        min_col = min(c[1] for c in region_cells)
        max_col = max(c[1] for c in region_cells)

        # Convert to pixels
        x = min_col * grid_size
        y = min_row * grid_size
        w = (max_col - min_col + 1) * grid_size
        h = (max_row - min_row + 1) * grid_size

        # Filter by size (too small)
        if w < min_width_px or h < min_height_px:
            continue

        # Filter by size (too large - likely captured whole content area)
        w_pct = w / img_w * 100
        h_pct = h / img_h * 100
        area_pct = w_pct * h_pct / 100
        if area_pct > max_region_pct:
            continue

        # Convert to percentages
        results.append({
            'bounds_pct': {
                'x': round(x / img_w * 100, 2),
                'y': round(y / img_h * 100, 2),
                'width': round(w_pct, 2),
                'height': round(h_pct, 2)
            },
            'pixel_size': {
                'width': w,
                'height': h
            }
        })

    return results


def detect_images(image_path: str,
                  min_width_px: int = 100,
                  min_height_px: int = 100,
                  min_area_pct: float = 1.0,
                  extract: bool = True,
                  output_dir: str = "/tmp",
                  resize: bool = True) -> List[Dict]:
    """
    Main pipeline: detect, filter, extract, and describe images.

    Uses hybrid approach:
    1. Rectangle detection for images with clear borders
    2. Grid-based variance scanning for photos without clear borders

    Args:
        image_path: Path to screenshot
        min_width_px: Minimum image width
        min_height_px: Minimum image height
        min_area_pct: Minimum area percentage
        extract: Whether to extract images to files
        output_dir: Directory for extracted images
        resize: Resize extracted images for Claude API (default True)

    Returns:
        List of detected images with paths and descriptions
    """
    # Load image
    try:
        pil_image = Image.open(image_path)
    except Exception as e:
        print(f"ERROR: Failed to open image: {e}", file=sys.stderr)
        return []

    all_regions = []

    # Method 1: Rectangle detection (good for bordered images, logos)
    rectangles = detect_rectangles(image_path)
    if rectangles:
        sized = filter_by_size(rectangles, min_width_px, min_height_px, min_area_pct)
        for region in sized:
            if is_image_region(pil_image, region):
                all_regions.append(region)

    # Method 2: Grid-based scanning (good for photos without clear borders)
    grid_regions = scan_for_image_regions(
        pil_image,
        grid_size=40,
        min_width_px=min_width_px,
        min_height_px=min_height_px,
        variance_threshold=400.0
    )
    all_regions.extend(grid_regions)

    if not all_regions:
        return []

    # Remove overlapping regions (keep larger ones)
    non_overlapping = remove_overlapping(all_regions)

    # Stage 5: Build results
    images = []
    for region in non_overlapping:
        # Calculate center for grid coordinates
        bounds = region['bounds_pct']
        center_x = bounds['x'] + bounds['width'] / 2
        center_y = bounds['y'] + bounds['height'] / 2

        result = {
            'type': 'image',
            'center_pct': {
                'x': round(center_x, 1),
                'y': round(center_y, 1)
            },
            'bounds_pct': bounds,
            'pixel_size': region['pixel_size']
        }

        # Extract image to file
        if extract:
            result['path'] = extract_image(pil_image, region, output_dir, resize=resize)

        # Generate description
        result['description'] = generate_description(region)

        images.append(result)

    # Sort by position (top-to-bottom, left-to-right)
    images.sort(key=lambda i: (i['center_pct']['y'], i['center_pct']['x']))

    return images


def main():
    parser = argparse.ArgumentParser(
        description='Detect images in screenshots for LLM browsing'
    )
    parser.add_argument('image', help='Path to image file')
    parser.add_argument('--min-width', type=int, default=100,
                        help='Minimum image width in pixels (default: 100)')
    parser.add_argument('--min-height', type=int, default=100,
                        help='Minimum image height in pixels (default: 100)')
    parser.add_argument('--min-area', type=float, default=1.0,
                        help='Minimum area as percentage (default: 1.0)')
    parser.add_argument('--no-extract', action='store_true',
                        help='Skip extracting images to files')
    parser.add_argument('--no-resize', action='store_true',
                        help='Skip resizing for Claude API (keep full resolution)')
    parser.add_argument('--output-dir', default='/tmp',
                        help='Directory for extracted images (default: /tmp)')
    parser.add_argument('--json', action='store_true',
                        help='Output as JSON')

    args = parser.parse_args()

    if not Path(args.image).exists():
        print(f"ERROR: Image not found: {args.image}", file=sys.stderr)
        sys.exit(1)

    images = detect_images(
        args.image,
        min_width_px=args.min_width,
        min_height_px=args.min_height,
        min_area_pct=args.min_area,
        extract=not args.no_extract,
        output_dir=args.output_dir,
        resize=not args.no_resize
    )

    if args.json:
        print(json.dumps(images, indent=2))
    else:
        if not images:
            print("No images detected")
        else:
            for img in images:
                x = img['center_pct']['x']
                y = img['center_pct']['y']
                desc = img.get('description', 'Image')
                path = img.get('path', '')
                print(f"[{x},{y}] [IMAGE:{path} \"{desc}\"]")


if __name__ == "__main__":
    main()
