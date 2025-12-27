#!/usr/bin/env python3
"""
Element detection for small UI components (icons, buttons).
Uses Vision framework rectangle detection + contrast analysis.
"""

import sys
import json
import argparse
import hashlib
from pathlib import Path
from typing import List, Dict, Tuple, Optional
import subprocess

import Quartz
from Foundation import NSURL
import objc
from PIL import Image, ImageFilter, ImageStat

# Load Vision framework
objc.loadBundle('Vision', globals(),
                bundle_path='/System/Library/Frameworks/Vision.framework')


def detect_small_rectangles(image_path: str, min_size_pct: float = 0.5) -> List[Dict]:
    """
    Detect small rectangular regions (icons, buttons) using Vision framework.

    Args:
        image_path: Path to cropped region image
        min_size_pct: Minimum size as percentage (default 0.5% for small icons)

    Returns:
        List of detected rectangles with bounds
    """
    image_url = NSURL.fileURLWithPath_(image_path)
    image_source = Quartz.CGImageSourceCreateWithURL(image_url, None)
    if not image_source:
        return []

    cg_image = Quartz.CGImageSourceCreateImageAtIndex(image_source, 0, None)
    if not cg_image:
        return []

    img_width = Quartz.CGImageGetWidth(cg_image)
    img_height = Quartz.CGImageGetHeight(cg_image)

    request_handler = VNImageRequestHandler.alloc().initWithCGImage_options_(
        cg_image, None
    )

    request = VNDetectRectanglesRequest.alloc().init()
    request.setMaximumObservations_(30)
    request.setMinimumSize_(min_size_pct / 100.0)
    request.setQuadratureTolerance_(20.0)  # More tolerance for rounded corners
    request.setMinimumAspectRatio_(0.3)
    request.setMaximumAspectRatio_(3.0)

    success = request_handler.performRequests_error_([request], None)
    if not success:
        return []

    rectangles = []
    results = request.results()
    if not results:
        return []

    for observation in results:
        bbox = observation.boundingBox()
        # Convert from Vision coords (bottom-left) to top-left percentages
        x_pct = bbox.origin.x * 100
        y_pct = (1 - bbox.origin.y - bbox.size.height) * 100
        w_pct = bbox.size.width * 100
        h_pct = bbox.size.height * 100

        rectangles.append({
            'x': round(x_pct, 1),
            'y': round(y_pct, 1),
            'w': round(w_pct, 1),
            'h': round(h_pct, 1),
            'confidence': float(observation.confidence()),
            'source': 'vision'
        })

    return rectangles


def detect_contrast_regions(image_path: str, min_size_px: int = 12, max_size_px: int = 60) -> List[Dict]:
    """
    Detect high-contrast regions using PIL edge detection.
    Good for finding icons that may not have clear rectangular borders.

    Args:
        image_path: Path to image
        min_size_px: Minimum region size in pixels
        max_size_px: Maximum region size in pixels

    Returns:
        List of detected regions
    """
    img = Image.open(image_path)
    width, height = img.size

    # Convert to grayscale and find edges
    gray = img.convert('L')
    edges = gray.filter(ImageFilter.FIND_EDGES)

    # Scan for high-edge-density regions using a grid
    cell_size = 16  # pixels per cell
    regions = []

    for y in range(0, height - cell_size, cell_size // 2):
        for x in range(0, width - cell_size, cell_size // 2):
            # Get edge density in this cell
            cell = edges.crop((x, y, x + cell_size, y + cell_size))
            stat = ImageStat.Stat(cell)
            edge_mean = stat.mean[0]

            # High edge density indicates potential element boundary
            # Lower threshold (20) catches subtle icons like moon/sun toggles
            if edge_mean > 20:
                regions.append({
                    'x': round(x * 100 / width, 1),
                    'y': round(y * 100 / height, 1),
                    'w': round(cell_size * 100 / width, 1),
                    'h': round(cell_size * 100 / height, 1),
                    'edge_density': round(edge_mean, 1),
                    'source': 'contrast'
                })

    # Cluster overlapping/adjacent regions into elements
    # Use tight margin (0.5%) to avoid merging distant elements
    # min_cluster_size=1 allows single-cell icons (small toggles)
    return cluster_regions(regions, overlap_margin_pct=0.5, min_cluster_size=1)


def cluster_regions(regions: List[Dict], overlap_margin_pct: float = 2.0,
                    min_cluster_size: int = 2) -> List[Dict]:
    """
    Cluster regions using bounding box overlap/adjacency (union-find).

    Groups overlapping or adjacent regions into single bounding boxes.
    Better than pure distance-based for grid-scanned regions.

    Args:
        regions: List of detected regions with x, y, w, h
        overlap_margin_pct: Extra margin for "near-touching" detection
        min_cluster_size: Minimum regions to form a valid cluster (filters noise)

    Returns:
        List of clustered/merged regions
    """
    if not regions:
        return []

    def boxes_overlap(r1, r2, margin):
        """Check if two bounding boxes overlap or are within margin."""
        # Expand r1 by margin
        r1_left = r1['x'] - margin
        r1_right = r1['x'] + r1['w'] + margin
        r1_top = r1['y'] - margin
        r1_bottom = r1['y'] + r1['h'] + margin

        r2_left = r2['x']
        r2_right = r2['x'] + r2['w']
        r2_top = r2['y']
        r2_bottom = r2['y'] + r2['h']

        # Check for overlap
        return not (r1_right < r2_left or r2_right < r1_left or
                    r1_bottom < r2_top or r2_bottom < r1_top)

    n = len(regions)

    # Union-find to group overlapping regions
    parent = list(range(n))

    def find(i):
        if parent[i] != i:
            parent[i] = find(parent[i])
        return parent[i]

    def union(i, j):
        pi, pj = find(i), find(j)
        if pi != pj:
            parent[pi] = pj

    # Group regions that overlap or touch
    for i in range(n):
        for j in range(i + 1, n):
            if boxes_overlap(regions[i], regions[j], overlap_margin_pct):
                union(i, j)

    # Collect clusters
    from collections import defaultdict
    clusters = defaultdict(list)
    for i in range(n):
        clusters[find(i)].append(regions[i])

    # Merge each cluster into single bounding box, filter by size
    merged = []
    for cluster in clusters.values():
        # Filter noise: require minimum number of source regions
        if len(cluster) < min_cluster_size:
            continue

        min_x = min(r['x'] for r in cluster)
        min_y = min(r['y'] for r in cluster)
        max_x = max(r['x'] + r['w'] for r in cluster)
        max_y = max(r['y'] + r['h'] for r in cluster)

        merged.append({
            'x': round(min_x, 1),
            'y': round(min_y, 1),
            'w': round(max_x - min_x, 1),
            'h': round(max_y - min_y, 1),
            'source': 'clustered',
            'region_count': len(cluster)
        })

    # Sort by x position (left to right)
    merged = sorted(merged, key=lambda r: r['x'])

    return merged


def detect_elements(image_path: str,
                   min_size_pct: float = 1.0,
                   max_size_pct: float = 50.0) -> List[Dict]:
    """
    Detect UI elements in an image region.

    Combines Vision rectangle detection with contrast analysis.

    Args:
        image_path: Path to image (should be a cropped region)
        min_size_pct: Minimum element size as % of image
        max_size_pct: Maximum element size as % of image

    Returns:
        List of elements with id, bbox, and type
    """
    # Try Vision rectangle detection first
    rectangles = detect_small_rectangles(image_path, min_size_pct=0.5)

    # Add contrast-based detection
    contrast_regions = detect_contrast_regions(image_path)

    # Combine and deduplicate
    all_regions = rectangles + contrast_regions

    # Filter by size
    filtered = []
    for r in all_regions:
        area = r['w'] * r['h']
        if min_size_pct <= area <= max_size_pct * max_size_pct:
            # Also filter out very elongated shapes (probably not icons)
            aspect = max(r['w'], r['h']) / max(min(r['w'], r['h']), 0.1)
            if aspect < 4:  # Roughly square-ish
                filtered.append(r)

    # Filter out elements touching region edges (likely boundary artifacts)
    filtered = filter_edge_elements(filtered, edge_margin_pct=2.0)

    # Sort left-to-right, top-to-bottom
    filtered = sorted(filtered, key=lambda r: (r['y'] // 10, r['x']))

    # Assign IDs and determine type
    elements = []
    for i, r in enumerate(filtered, 1):
        elem = {
            'id': i,
            'bbox': [r['x'], r['y'], r['w'], r['h']],
            'type': classify_element(r)
        }
        elements.append(elem)

    return elements


def filter_edge_elements(regions: List[Dict], edge_margin_pct: float = 2.0,
                         filter_bottom: bool = False) -> List[Dict]:
    """
    Filter out elements that touch the region boundary.

    By default, only filters TOP edge (browser chrome) since bottom toolbars
    contain legitimate icons (dark mode toggles, settings, etc.).

    Args:
        regions: List of regions with x, y, w, h (percentages 0-100)
        edge_margin_pct: How close to edge counts as "touching" (default 2%)
        filter_bottom: Also filter bottom edge (default False - keeps toolbar icons)

    Returns:
        Filtered list excluding edge-touching elements
    """
    filtered = []
    for r in regions:
        x, y, w, h = r['x'], r['y'], r['w'], r['h']

        # Only filter top edge by default (browser chrome artifacts)
        # Bottom toolbars contain legitimate icons we want to detect
        touches_top = y < edge_margin_pct

        if not touches_top:
            filtered.append(r)

    return filtered


def classify_element(region: Dict) -> str:
    """Classify element type based on size and shape."""
    w, h = region['w'], region['h']
    area = w * h

    if area < 4:
        return 'small-icon'
    elif area < 16:
        return 'icon'
    elif area < 50:
        return 'button'
    else:
        return 'region'


def describe_icon(crop: Image.Image) -> str:
    """
    Generate a short description of an icon based on fast visual analysis.

    Args:
        crop: PIL Image of the icon

    Returns:
        Short description string (color info only - fast)
    """
    # Get basic color info
    if crop.mode != 'RGB':
        crop_rgb = crop.convert('RGB')
    else:
        crop_rgb = crop

    # Sample colors (subsample for speed)
    pixels = list(crop_rgb.getdata())[::4]  # Every 4th pixel
    if not pixels:
        return ""

    # Find dominant color (most common non-gray color)
    from collections import Counter
    color_counts = Counter()
    for r, g, b in pixels:
        # Check if it's a saturated color (not gray)
        max_c, min_c = max(r, g, b), min(r, g, b)
        if max_c - min_c > 50:  # Has color saturation
            if r > g and r > b:
                color_counts['red'] += 1
            elif g > r and g > b:
                color_counts['green'] += 1
            elif b > r and b > g:
                color_counts['blue'] += 1
            elif r > 180 and g > 180 and b < 120:
                color_counts['yellow'] += 1
            elif r > 180 and b > 180 and g < 120:
                color_counts['magenta'] += 1
            elif g > 180 and b > 180 and r < 120:
                color_counts['cyan'] += 1
            elif r > 200 and g > 100 and g < 180 and b < 100:
                color_counts['orange'] += 1

    if color_counts:
        # Return dominant color if significant
        dominant, count = color_counts.most_common(1)[0]
        if count > len(pixels) * 0.1:  # At least 10% of pixels
            return dominant

    return ""


def extract_icon(image: Image.Image, bbox: List[float],
                 output_dir: str = "/tmp", max_size: int = 128) -> Tuple[str, str]:
    """
    Extract icon region to a file for LLM viewing.

    Args:
        image: Source PIL Image
        bbox: Bounding box as [x, y, w, h] in percentages
        output_dir: Directory for extracted icons
        max_size: Maximum dimension in pixels (default 128)

    Returns:
        Tuple of (path to extracted icon file, description)
    """
    img_w, img_h = image.size

    x = int(bbox[0] * img_w / 100)
    y = int(bbox[1] * img_h / 100)
    w = int(bbox[2] * img_w / 100)
    h = int(bbox[3] * img_h / 100)

    # Add small padding around icon (2px)
    pad = 2
    x = max(0, x - pad)
    y = max(0, y - pad)
    w = min(img_w - x, w + 2 * pad)
    h = min(img_h - y, h + 2 * pad)

    # Ensure valid bounds
    if w < 4 or h < 4:
        return "", ""

    crop = image.crop((x, y, x + w, y + h))

    # Generate description before resizing (better quality for analysis)
    description = describe_icon(crop)

    # Resize if larger than max_size while preserving aspect ratio
    if max(crop.width, crop.height) > max_size:
        ratio = max_size / max(crop.width, crop.height)
        new_w = max(1, int(crop.width * ratio))
        new_h = max(1, int(crop.height * ratio))
        crop = crop.resize((new_w, new_h), Image.Resampling.LANCZOS)

    # Generate unique filename based on content hash
    crop_bytes = crop.tobytes()
    hash_suffix = hashlib.md5(crop_bytes).hexdigest()[:8]
    filename = f"icon_{hash_suffix}.jpg"
    output_path = Path(output_dir) / filename

    # Save as JPEG
    if crop.mode == 'RGBA':
        crop = crop.convert('RGB')
    crop.save(output_path, 'JPEG', quality=90)

    return str(output_path), description


def detect_and_extract_icons(image_path: str,
                             min_size_pct: float = 0.5,
                             max_size_pct: float = 8.0,
                             output_dir: str = "/tmp") -> List[Dict]:
    """
    Detect and extract icons from an image.

    Args:
        image_path: Path to image
        min_size_pct: Minimum element size as % of image area
        max_size_pct: Maximum element size as % of image area
        output_dir: Directory for extracted icon images

    Returns:
        List of icons with bbox, type, and path to extracted image
    """
    # Load image for extraction
    try:
        image = Image.open(image_path)
    except Exception:
        return []

    # Detect elements using existing pipeline
    elements = detect_elements(image_path, min_size_pct, max_size_pct * max_size_pct)

    # Filter to only icon-sized elements and extract them
    icons = []
    for elem in elements:
        if elem['type'] in ('small-icon', 'icon', 'button'):
            bbox = elem['bbox']
            path, description = extract_icon(image, bbox, output_dir)
            if path:
                icon_data = {
                    'bbox': bbox,
                    'type': elem['type'],
                    'path': path
                }
                if description:
                    icon_data['desc'] = description
                icons.append(icon_data)

    return icons


def main():
    parser = argparse.ArgumentParser(description='Detect UI elements in image region')
    parser.add_argument('--image', required=True, help='Path to image')
    parser.add_argument('--json', action='store_true', help='Output as JSON')
    parser.add_argument('--extract', action='store_true',
                        help='Extract icons to files (returns paths)')
    parser.add_argument('--output-dir', default='/tmp',
                        help='Directory for extracted icons (default: /tmp)')
    parser.add_argument('--min-size', type=float, default=0.5,
                        help='Min element size %% (default: 0.5)')
    parser.add_argument('--max-size', type=float, default=8.0,
                        help='Max element size %% for icons (default: 8.0)')

    args = parser.parse_args()

    if args.extract:
        # Detect and extract icons to files
        icons = detect_and_extract_icons(
            args.image,
            min_size_pct=args.min_size,
            max_size_pct=args.max_size,
            output_dir=args.output_dir
        )

        if args.json:
            print(json.dumps(icons, indent=2))
        else:
            for icon in icons:
                bbox = ','.join(str(round(v, 1)) for v in icon['bbox'])
                print(f"[{bbox}] {icon['type']} -> {icon['path']}")
    else:
        # Detection only (no extraction)
        elements = detect_elements(
            args.image,
            min_size_pct=args.min_size,
            max_size_pct=args.max_size * args.max_size  # Convert to area
        )

        if args.json:
            print(json.dumps(elements, indent=2))
        else:
            for elem in elements:
                bbox = ','.join(str(round(v, 1)) for v in elem['bbox'])
                print(f"[{elem['id']}] {bbox} {elem['type']}")


if __name__ == '__main__':
    main()
