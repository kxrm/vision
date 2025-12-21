#!/usr/bin/env python3
"""List visible windows using Quartz CGWindowListCopyWindowInfo."""

import sys
import json
import Quartz
from Quartz import (
    CGWindowListCopyWindowInfo,
    kCGWindowListOptionOnScreenOnly,
    kCGWindowListExcludeDesktopElements,
    kCGNullWindowID
)


def get_displays():
    """Get all displays with their bounds."""
    max_displays = 10
    (err, active_displays, num_displays) = Quartz.CGGetActiveDisplayList(max_displays, None, None)

    displays = []
    if err == 0 and num_displays > 0:
        for i, display_id in enumerate(active_displays[:num_displays]):
            bounds = Quartz.CGDisplayBounds(display_id)
            is_main = Quartz.CGDisplayIsMain(display_id)
            displays.append({
                'display_num': i + 1,
                'display_id': display_id,
                'x': int(bounds.origin.x),
                'y': int(bounds.origin.y),
                'width': int(bounds.size.width),
                'height': int(bounds.size.height),
                'is_main': bool(is_main)
            })
    return displays


def find_window_display(window_bounds, displays):
    """Determine which display a window is primarily on."""
    win_center_x = window_bounds['x'] + window_bounds['width'] / 2
    win_center_y = window_bounds['y'] + window_bounds['height'] / 2

    for disp in displays:
        # Check if window center is within this display
        if (disp['x'] <= win_center_x < disp['x'] + disp['width'] and
            disp['y'] <= win_center_y < disp['y'] + disp['height']):
            return disp

    # Fallback to first display
    return displays[0] if displays else None


def window_to_grid(window_bounds, display):
    """Convert window bounds to grid percentages relative to display."""
    if not display:
        return None

    # Calculate grid percentages
    rel_x = window_bounds['x'] - display['x']
    rel_y = window_bounds['y'] - display['y']

    grid_x = (rel_x / display['width']) * 100
    grid_y = (rel_y / display['height']) * 100
    grid_w = (window_bounds['width'] / display['width']) * 100
    grid_h = (window_bounds['height'] / display['height']) * 100

    # Center point
    center_x = grid_x + grid_w / 2
    center_y = grid_y + grid_h / 2

    return {
        'x': round(grid_x, 1),
        'y': round(grid_y, 1),
        'width': round(grid_w, 1),
        'height': round(grid_h, 1),
        'center_x': round(center_x, 1),
        'center_y': round(center_y, 1)
    }

def get_windows(app_filter=None):
    """
    Get list of visible windows.

    Args:
        app_filter: Optional app name to filter by (case-insensitive partial match)

    Returns:
        List of dicts with window_id, app, title, bounds (x, y, width, height)
    """
    options = kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements
    window_list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)

    windows = []
    for window in window_list:
        # Skip windows without owner name (system elements)
        owner = window.get('kCGWindowOwnerName', '')
        if not owner:
            continue

        # Skip menu bar and other system UI
        layer = window.get('kCGWindowLayer', 0)
        if layer < 0 or layer > 100:  # Normal windows are typically layer 0
            continue

        window_id = window.get('kCGWindowNumber', 0)
        title = window.get('kCGWindowName', '') or ''

        # Get bounds
        bounds = window.get('kCGWindowBounds', {})
        x = bounds.get('X', 0)
        y = bounds.get('Y', 0)
        width = bounds.get('Width', 0)
        height = bounds.get('Height', 0)

        # Skip very small windows (likely UI elements)
        if width < 50 or height < 50:
            continue

        # Apply app filter if specified
        if app_filter:
            if app_filter.lower() not in owner.lower():
                continue

        windows.append({
            'window_id': window_id,
            'app': owner,
            'title': title,
            'bounds': {
                'x': int(x),
                'y': int(y),
                'width': int(width),
                'height': int(height)
            }
        })

    return windows

def format_windows(windows, output_format='text'):
    """Format window list for output."""
    if output_format == 'json':
        return json.dumps(windows, indent=2)

    # Text format
    lines = []
    for w in windows:
        bounds = w['bounds']
        title = w['title'][:40] if w['title'] else '(no title)'
        lines.append(f"{w['window_id']:>8}  {w['app']:<25} {title:<42} {bounds['width']}x{bounds['height']}")

    if lines:
        header = f"{'ID':>8}  {'Application':<25} {'Title':<42} Size"
        return header + "\n" + "-" * len(header) + "\n" + "\n".join(lines)
    return "No windows found"

def main():
    import argparse
    parser = argparse.ArgumentParser(description='List visible windows')
    parser.add_argument('--app', '-a', help='Filter by app name (partial match)')
    parser.add_argument('--json', '-j', action='store_true', help='Output as JSON')
    parser.add_argument('--id-only', action='store_true', help='Output only window ID (first match)')
    parser.add_argument('--where', action='store_true',
                        help='Show which display and grid position (use with --app)')
    parser.add_argument('--bounds', action='store_true',
                        help='Output pixel bounds as x,y,w,h (for OCR region filtering)')
    args = parser.parse_args()

    windows = get_windows(app_filter=args.app)
    displays = get_displays()

    if args.where:
        # Show display and grid position for the app
        if not windows:
            print(f"NOT_FOUND: No window for '{args.app}'", file=sys.stderr)
            sys.exit(1)

        w = windows[0]
        display = find_window_display(w['bounds'], displays)
        grid = window_to_grid(w['bounds'], display)

        if display and grid:
            main_str = " [MAIN]" if display['is_main'] else ""
            print(f"APP: {w['app']}")
            print(f"DISPLAY: {display['display_num']}{main_str}")
            print(f"BOUNDS: {w['bounds']['x']},{w['bounds']['y']},{w['bounds']['width']},{w['bounds']['height']}")
            print(f"GRID: {grid['x']},{grid['y']},{grid['width']},{grid['height']}")
            print(f"CENTER: {grid['center_x']},{grid['center_y']}")
        else:
            print("ERROR: Could not determine display", file=sys.stderr)
            sys.exit(1)

    elif args.bounds:
        # Output just the pixel bounds (for scripting)
        if not windows:
            sys.exit(1)
        w = windows[0]
        print(f"{w['bounds']['x']},{w['bounds']['y']},{w['bounds']['width']},{w['bounds']['height']}")

    elif args.id_only:
        if windows:
            print(windows[0]['window_id'])
        else:
            sys.exit(1)
    elif args.json:
        print(format_windows(windows, 'json'))
    else:
        print(format_windows(windows, 'text'))


if __name__ == "__main__":
    main()
