#!/usr/bin/env python3
"""
Shared OCR text finder for vision tools.
Returns bounding box coordinates for text on screen.

Usage:
    find_text.py "search text" [options]

Options:
    --in-app NAME       Filter to app window, return app-relative coords
    --near TEXT         Find match closest to anchor text (recommended)
    --instance N        Select Nth match (fallback, less reliable)
    --display N         Target display number (default: 1)

Output:
    On success: x,y,w,h (percentages, app-relative if --in-app)
    On error: ERROR: message (to stderr), exit 1
    On multiple matches without disambiguation: MULTIPLE_MATCHES (to stderr), exit 1
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

# Get the directory containing this script
LIB_DIR = Path(__file__).parent
BIN_DIR = LIB_DIR.parent / "bin"
SCREENSHOT_SH = BIN_DIR / "screenshot.sh"
OCR_FIND_PY = LIB_DIR / "ocr_find.py"


def take_screenshot(output_path: str, display: int = None, in_app: str = None) -> bool:
    """Take a screenshot using screenshot.sh.

    Always uses --full-res for OCR operations (needs original resolution).
    """
    cmd = [str(SCREENSHOT_SH), "--output", output_path, "--full-res"]
    if in_app:
        cmd.extend(["--in-app", in_app])
    elif display:
        cmd.extend(["--display", str(display)])

    result = subprocess.run(cmd, capture_output=True, text=True)
    return result.returncode == 0 and os.path.exists(output_path)


def run_ocr(image_path: str, search_text: str, near_text: str = None,
            instance: int = None, return_all: bool = False) -> dict | list | None:
    """Run OCR using ocr_find.py and return results."""
    cmd = [sys.executable, str(OCR_FIND_PY), image_path, "--find", search_text, "--json"]

    if near_text:
        cmd.extend(["--near", near_text])
    elif return_all:
        cmd.append("--all")
    elif instance:
        cmd.extend(["--instance", str(instance)])

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        return None

    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return None


def find_text(search_text: str, in_app: str = None, near_text: str = None,
              instance: int = 1, display: int = 1, instance_explicit: bool = False) -> str | None:
    """
    Find text on screen and return bounding box coordinates.

    Returns: "x,y,w,h" string (percentages) on success
    Returns None and prints error to stderr on failure
    """
    temp_files = []
    try:
        # Take screenshot
        temp_screenshot = tempfile.NamedTemporaryFile(suffix=".jpg", delete=False)
        temp_screenshot.close()
        temp_files.append(temp_screenshot.name)

        # When --in-app is set, always use app-only screenshot
        # This ensures we only see text actually visible in that app's window
        if in_app:
            if not take_screenshot(temp_screenshot.name, in_app=in_app):
                print(f"ERROR: Failed to capture screenshot for {in_app}", file=sys.stderr)
                return None

            # Run OCR on app-only screenshot
            if near_text:
                result = run_ocr(temp_screenshot.name, search_text, near_text=near_text)
                if not result:
                    print(f"NOT_FOUND: '{search_text}' near '{near_text}'", file=sys.stderr)
                    return None
                # Single result from --near
                b = result["bounds_pct"]
                return f"{b['x']:.1f},{b['y']:.1f},{b['width']:.1f},{b['height']:.1f}"
            else:
                # Get all matches for instance selection
                matches = run_ocr(temp_screenshot.name, search_text, return_all=True)
                if not matches:
                    print(f"NOT_FOUND: '{search_text}'", file=sys.stderr)
                    return None

                # Handle multiple matches
                if len(matches) > 1 and not instance_explicit:
                    print(f"MULTIPLE_MATCHES: Found {len(matches)} matches. Use --near to select by context (recommended):", file=sys.stderr)
                    for i, m in enumerate(matches, 1):
                        b = m["bounds_pct"]
                        text_preview = m.get("text", "")[:40]
                        print(f"  {i}. \"{text_preview}\" at ({b['x']:.1f}%,{b['y']:.1f}%)", file=sys.stderr)
                    print("", file=sys.stderr)
                    print("Usage: --near \"unique nearby text\" --find-text \"target\"", file=sys.stderr)
                    print("  --near finds the match closest to anchor text (spatial proximity)", file=sys.stderr)
                    print("  --instance N selects by position (less reliable, use as fallback)", file=sys.stderr)
                    return None

                # Get requested instance
                idx = instance - 1
                if idx >= len(matches):
                    print(f"ERROR: Only {len(matches)} matches, requested instance {instance}", file=sys.stderr)
                    return None

                b = matches[idx]["bounds_pct"]
                return f"{b['x']:.1f},{b['y']:.1f},{b['width']:.1f},{b['height']:.1f}"

        # No --in-app: take display screenshot
        if not take_screenshot(temp_screenshot.name, display=display):
            print(f"ERROR: Failed to capture screenshot", file=sys.stderr)
            return None

        # Run OCR
        if near_text:
            result = run_ocr(temp_screenshot.name, search_text, near_text=near_text)
            if not result:
                print(f"NOT_FOUND: '{search_text}' near '{near_text}'", file=sys.stderr)
                return None
            b = result["bounds_pct"]
            return f"{b['x']:.1f},{b['y']:.1f},{b['width']:.1f},{b['height']:.1f}"
        else:
            result = run_ocr(temp_screenshot.name, search_text, instance=instance)
            if not result:
                print(f"NOT_FOUND: '{search_text}'", file=sys.stderr)
                return None
            b = result["bounds_pct"]
            return f"{b['x']:.1f},{b['y']:.1f},{b['width']:.1f},{b['height']:.1f}"

    finally:
        # Clean up temp files
        for f in temp_files:
            try:
                os.unlink(f)
            except OSError:
                pass


def main():
    parser = argparse.ArgumentParser(
        description="Find text on screen using OCR",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Output:
  On success: x,y,w,h (percentages, app-relative if --in-app)
  On error: ERROR: message (to stderr), exit 1

Examples:
  find_text.py "Submit"
  find_text.py "Submit" --in-app Firefox
  find_text.py "comments" --near "Pure Silicon" --in-app Firefox
"""
    )
    parser.add_argument("search_text", help="Text to search for")
    parser.add_argument("--in-app", "-a", help="Filter to app window, return app-relative coords")
    parser.add_argument("--near", "-n", help="Find match closest to anchor text (recommended)")
    parser.add_argument("--instance", "-i", type=int, default=1,
                        help="Select Nth match (fallback, less reliable than --near)")
    parser.add_argument("--display", "-d", type=int, default=1,
                        help="Target display number (default: 1)")

    args = parser.parse_args()

    # Check if instance was explicitly provided (via CLI arg or env var)
    instance_explicit = "--instance" in sys.argv or "-i" in sys.argv or \
                        os.environ.get("INSTANCE_EXPLICIT", "") == "1"

    result = find_text(
        args.search_text,
        in_app=args.in_app,
        near_text=args.near,
        instance=args.instance,
        display=args.display,
        instance_explicit=instance_explicit
    )

    if result:
        print(result)
        sys.exit(0)
    else:
        sys.exit(1)


if __name__ == "__main__":
    main()
