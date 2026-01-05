#!/bin/bash
# Desktop interaction utility for Claude vision capabilities
# Enables mouse clicks, keyboard input, and app control

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PYTHON="$PROJECT_ROOT/venv/bin/python"
LIB_DIR="$PROJECT_ROOT/lib"
OCR_FIND="$LIB_DIR/ocr_find.py"
IMAGE_DETECT="$LIB_DIR/image_detect.py"
ELEMENT_DETECT="$LIB_DIR/element_detect.py"
SCREENSHOT="$SCRIPT_DIR/screenshot.sh"
WINDOW_LIST="$LIB_DIR/window_list.py"
UI_ELEMENTS="$LIB_DIR/ui_elements.py"
FIREFOX_TABS="$LIB_DIR/firefox_tabs.py"
CLIPBOARD_PY="$LIB_DIR/clipboard.py"

# Current display settings (can be overridden with --display)
DISPLAY_NUM=""
DISPLAY_X_OFFSET=0
DISPLAY_Y_OFFSET=0
DISPLAY_WIDTH=2560
DISPLAY_HEIGHT=1440

# Persistent target app file (stores last --in-app target for auto-reactivation)
TARGET_APP_FILE="/tmp/interact_target_app_$(id -u)"

# Auto-wait timeout for smart waits (can be overridden with --auto-wait-timeout)
AUTO_WAIT_TIMEOUT=3000

# OCR timeout for text search operations (default 10s to allow for app activation + screenshot + OCR)
OCR_TIMEOUT="${OCR_TIMEOUT:-10}"

# Read page timeout in seconds (OCR + image detection + icon detection can be slow)
READ_PAGE_TIMEOUT="${READ_PAGE_TIMEOUT:-10}"

# Image detection for --read-page (enabled by default, disable with --no-images)
DETECT_IMAGES=1

# Icon detection for --read-page (enabled by default, disable with --no-icons)
DETECT_ICONS=1

# Typing configuration (safe mode prevents macOS shortcut collisions)
TYPE_DELAY="${TYPE_DELAY:-30}"  # Default 30ms inter-character delay
TYPE_FAST=""                     # Set to 1 for legacy cliclick behavior (faster but may trigger shortcuts)

# Drag configuration (smooth, human-like drags using Quartz)
DRAG_DURATION="${DRAG_DURATION:-1.6}"  # Total drag duration in seconds (higher = slower, more visible)
DRAG_EASING="${DRAG_EASING:-ease-in-out}"  # Easing: linear, ease-in, ease-out, ease-in-out
DRAG_STEPS="${DRAG_STEPS:-60}"  # Number of interpolation steps (higher = smoother)

# Arc drag parameters (set via --arc position:tension)
ARC_POSITION=""   # ±1 to ±179: sign=direction, magnitude=apex location
ARC_TENSION=""    # Shape: negative=straighter, 0=circle, positive=L-corner

# Drag chaining state (for continuous paths in chains)
DRAG_MOUSE_DOWN=""  # Set to "1" when mouse is held from previous drag

# Region filter for --read-page output (persistent, set via --region x1,y1,x2,y2)
REGION=""

# Aspect ratio correction (for drawing shapes with equal proportions)
ASPECT_CORRECT=""  # Set to "1" to use square coordinate space

# Unified click modifiers (set via --double, --right, --triple, --toggle, --info)
CLICK_DOUBLE=""
CLICK_RIGHT=""
CLICK_TRIPLE=""
CLICK_TOGGLE=""
CLICK_INFO=""

# Run a command with timeout (macOS compatible)
# Usage: run_with_timeout <timeout_sec> <command> [args...]
# Returns: command output on success, empty string on timeout
run_with_timeout() {
    local timeout_sec="$1"
    shift
    local output_file="/tmp/timeout_cmd_$$.out"

    # Run command in background
    "$@" > "$output_file" 2>&1 &
    local cmd_pid=$!

    # Wait with timeout (use 0.2s granularity for more responsive timeout)
    local waited=0
    local max_iterations=$((timeout_sec * 5))  # 5 iterations per second (0.2s each)
    while kill -0 $cmd_pid 2>/dev/null && [[ $waited -lt $max_iterations ]]; do
        sleep 0.2
        waited=$((waited + 1))
    done

    # Check if still running (timed out)
    if kill -0 $cmd_pid 2>/dev/null; then
        # Try SIGTERM first
        kill $cmd_pid 2>/dev/null
        sleep 0.5
        # If still running, use SIGKILL (needed for processes stuck in C library calls)
        if kill -0 $cmd_pid 2>/dev/null; then
            kill -9 $cmd_pid 2>/dev/null
        fi
        wait $cmd_pid 2>/dev/null
        rm -f "$output_file"
        return 124  # timeout exit code
    fi

    wait $cmd_pid
    local exit_code=$?

    if [[ -f "$output_file" ]]; then
        cat "$output_file"
        rm -f "$output_file"
    fi

    return $exit_code
}

# Set target app and persist to file
set_target_app() {
    local app="$1"
    echo "$app" > "$TARGET_APP_FILE"
    IN_APP="$app"
    activate_app "$app" > /dev/null 2>&1
}

# Restore target app from file and reactivate (called before OCR/scroll operations)
restore_target_app() {
    if [[ -z "$IN_APP" && -f "$TARGET_APP_FILE" ]]; then
        IN_APP=$(cat "$TARGET_APP_FILE")
        echo "Restoring target app: $IN_APP" >&2
        activate_app "$IN_APP" > /dev/null 2>&1
        sleep 0.2  # Brief pause for app to come to front
    elif [[ -z "$IN_APP" ]]; then
        echo "WARNING: No target app set. Use --in-app <app> to set context." >&2
        echo "         Operating on full screen (may find text in wrong windows)." >&2
    fi
}

# Clear target app
clear_target_app() {
    rm -f "$TARGET_APP_FILE"
    IN_APP=""
}

# Flag to suppress auto-read when inside a chain (chain handles it at the end)
IN_CHAIN=""

# Track last click position for visual feedback (app-relative percentages)
LAST_CLICK_X=""
LAST_CLICK_Y=""

# Auto-read page after navigation actions when IN_APP is set
# Call this at the end of click_grid, scroll_at, etc.
# Skipped when IN_CHAIN is set (chain does auto-read at end instead)
auto_read_page() {
    if [[ -n "$IN_APP" && -z "$IN_CHAIN" ]]; then
        sleep 0.5  # Wait for page to update after action
        echo "---" >&2

        # Run read_page with timeout to avoid hanging on OCR
        local timeout_sec="$READ_PAGE_TIMEOUT"
        local read_output=""
        local read_pid

        # Start read_page in background (pass REGION if set)
        read_page "$IN_APP" "false" "false" "" "$REGION" &
        read_pid=$!

        # Wait with timeout
        local waited=0
        while kill -0 $read_pid 2>/dev/null && [[ $waited -lt $timeout_sec ]]; do
            sleep 1
            waited=$((waited + 1))
        done

        # Check if still running (timed out)
        if kill -0 $read_pid 2>/dev/null; then
            # Kill the process and all its children
            pkill -P $read_pid 2>/dev/null
            kill $read_pid 2>/dev/null
            sleep 0.3
            # Force kill if still running (needed for processes stuck in C library calls)
            if kill -0 $read_pid 2>/dev/null; then
                pkill -9 -P $read_pid 2>/dev/null
                kill -9 $read_pid 2>/dev/null
            fi
            wait $read_pid 2>/dev/null
            echo "WARNING: auto_read_page timed out after ${timeout_sec}s (OCR may be slow)" >&2
            echo "@page $IN_APP display:${DISPLAY_NUM:-1}" >&2
            echo "[Page content unavailable - timeout]" >&2
        else
            wait $read_pid 2>/dev/null
        fi
        echo "---" >&2
    fi
}

# Get display info using Python/Quartz
get_display_info() {
    "$PYTHON" << 'PYEOF'
import Quartz
import sys

max_displays = 10
(err, active_displays, num_displays) = Quartz.CGGetActiveDisplayList(max_displays, None, None)

if err == 0 and num_displays > 0:
    for i, display_id in enumerate(active_displays[:num_displays]):
        bounds = Quartz.CGDisplayBounds(display_id)
        main = Quartz.CGDisplayIsMain(display_id)
        # Output: display_num width height x_offset y_offset is_main
        print(f"{i+1} {int(bounds.size.width)} {int(bounds.size.height)} {int(bounds.origin.x)} {int(bounds.origin.y)} {1 if main else 0}")
PYEOF
}

# Set display parameters for coordinate conversion
set_display() {
    local display_num="$1"
    local info=$(get_display_info | grep "^$display_num ")

    if [[ -z "$info" ]]; then
        echo "ERROR: Display $display_num not found"
        get_display_info | while read num w h x y main; do
            local main_str=""
            [[ "$main" == "1" ]] && main_str=" [MAIN]"
            echo "  Display $num: ${w}x${h} at ($x,$y)$main_str"
        done
        return 1
    fi

    read DISPLAY_NUM DISPLAY_WIDTH DISPLAY_HEIGHT DISPLAY_X_OFFSET DISPLAY_Y_OFFSET _ <<< "$info"
    return 0
}

# Get main display info (default)
get_main_display() {
    local info=$(get_display_info | grep " 1$")
    if [[ -n "$info" ]]; then
        read DISPLAY_NUM DISPLAY_WIDTH DISPLAY_HEIGHT DISPLAY_X_OFFSET DISPLAY_Y_OFFSET _ <<< "$info"
    fi
}

# Convert grid percentage to absolute pixel coordinates
# Returns coordinates formatted for cliclick (with = prefix for negative values)
# When ASPECT_CORRECT is set, uses a centered square coordinate space
grid_to_pixel() {
    local grid_x="$1"
    local grid_y="$2"

    local rel_x rel_y

    if [[ -n "$ASPECT_CORRECT" ]]; then
        # Use square coordinate space (centered)
        # Find smaller dimension, center the square region
        local min_dim=$((DISPLAY_WIDTH < DISPLAY_HEIGHT ? DISPLAY_WIDTH : DISPLAY_HEIGHT))
        local center_offset_x=$(( (DISPLAY_WIDTH - min_dim) / 2 ))
        local center_offset_y=$(( (DISPLAY_HEIGHT - min_dim) / 2 ))

        rel_x=$(echo "$center_offset_x + $grid_x * $min_dim / 100" | bc)
        rel_y=$(echo "$center_offset_y + $grid_y * $min_dim / 100" | bc)
    else
        # Standard: map to full display dimensions
        rel_x=$(echo "$grid_x * $DISPLAY_WIDTH / 100" | bc)
        rel_y=$(echo "$grid_y * $DISPLAY_HEIGHT / 100" | bc)
    fi

    local pixel_x=$(echo "$DISPLAY_X_OFFSET + $rel_x" | bc)
    local pixel_y=$(echo "$DISPLAY_Y_OFFSET + $rel_y" | bc)

    # cliclick needs = prefix for absolute negative values
    local cli_x="$pixel_x"
    local cli_y="$pixel_y"
    [[ $pixel_x -lt 0 ]] && cli_x="=$pixel_x"
    [[ $pixel_y -lt 0 ]] && cli_y="=$pixel_y"

    # Return both raw pixels (for display) and cliclick-formatted coords
    echo "$pixel_x $pixel_y $cli_x $cli_y"
}

# Convert grid coordinates to absolute pixel position
# Supports: x,y (point) or x,y,w,h (bounding box - auto-centers)
# Uses globals: IN_APP, REGION, ASPECT_CORRECT, DISPLAY_*, PYTHON, WINDOW_LIST
# Returns: "pixel_x pixel_y cli_x cli_y" (space-separated), or empty on error
# Outputs context messages to stderr
grid_coords_to_pixel() {
    local coords="$1"

    # Parse coordinates - support both x,y and x,y,w,h formats
    IFS=',' read -r grid_x grid_y grid_w grid_h <<< "$coords"

    if [[ -z "$grid_x" || -z "$grid_y" ]]; then
        return 1
    fi

    # If bounding box format (x,y,w,h), calculate center point
    if [[ -n "$grid_w" && -n "$grid_h" ]]; then
        grid_x=$(awk "BEGIN {printf \"%.1f\", $grid_x + $grid_w / 2}")
        grid_y=$(awk "BEGIN {printf \"%.1f\", $grid_y + $grid_h / 2}")
        echo "Box coords → center ($grid_x,$grid_y)" >&2
    fi

    local pixel_x pixel_y

    # Handle IN_APP coordinate translation
    if [[ -n "$IN_APP" ]]; then
        local where=$("$PYTHON" "$WINDOW_LIST" --app "$IN_APP" --where 2>&1)
        if ! echo "$where" | grep -q "No window found"; then
            local bounds=$(echo "$where" | grep "^BOUNDS:" | sed 's/BOUNDS: //')
            if [[ -n "$bounds" ]]; then
                IFS=',' read -r win_x win_y win_w win_h <<< "$bounds"

                # Calculate drawing area (respects REGION if set)
                local draw_x draw_y draw_w draw_h
                if [[ -n "$REGION" ]]; then
                    IFS=',' read -r rx1 ry1 rx2 ry2 <<< "$REGION"
                    draw_x=$(awk "BEGIN {print int($win_x + $rx1 * $win_w / 100)}")
                    draw_y=$(awk "BEGIN {print int($win_y + $ry1 * $win_h / 100)}")
                    draw_w=$(awk "BEGIN {print int(($rx2 - $rx1) * $win_w / 100)}")
                    draw_h=$(awk "BEGIN {print int(($ry2 - $ry1) * $win_h / 100)}")
                else
                    draw_x=$win_x
                    draw_y=$win_y
                    draw_w=$win_w
                    draw_h=$win_h
                fi

                # Calculate absolute pixel position
                if [[ -n "$ASPECT_CORRECT" ]]; then
                    local min_dim=$((draw_w < draw_h ? draw_w : draw_h))
                    local off_x=$(( (draw_w - min_dim) / 2 ))
                    local off_y=$(( (draw_h - min_dim) / 2 ))
                    pixel_x=$(awk "BEGIN {print int($draw_x + $off_x + $grid_x * $min_dim / 100)}")
                    pixel_y=$(awk "BEGIN {print int($draw_y + $off_y + $grid_y * $min_dim / 100)}")
                    echo "Aspect coords ($grid_x,$grid_y) in ${min_dim}x${min_dim} square → pixel ($pixel_x,$pixel_y)" >&2
                else
                    pixel_x=$(awk "BEGIN {print int($draw_x + $grid_x * $draw_w / 100)}")
                    pixel_y=$(awk "BEGIN {print int($draw_y + $grid_y * $draw_h / 100)}")
                    echo "App coords ($grid_x,$grid_y) in '$IN_APP' → pixel ($pixel_x,$pixel_y)" >&2
                fi
            fi
        else
            echo "WARNING: No window found for '$IN_APP', using display-relative" >&2
        fi
    fi

    # Fallback to display-relative if not set by IN_APP path
    if [[ -z "$pixel_x" ]]; then
        if [[ -n "$ASPECT_CORRECT" ]]; then
            local min_dim=$((DISPLAY_WIDTH < DISPLAY_HEIGHT ? DISPLAY_WIDTH : DISPLAY_HEIGHT))
            local off_x=$(( (DISPLAY_WIDTH - min_dim) / 2 ))
            local off_y=$(( (DISPLAY_HEIGHT - min_dim) / 2 ))
            pixel_x=$(awk "BEGIN {print int($DISPLAY_X_OFFSET + $off_x + $grid_x * $min_dim / 100)}")
            pixel_y=$(awk "BEGIN {print int($DISPLAY_Y_OFFSET + $off_y + $grid_y * $min_dim / 100)}")
            echo "Display aspect coords ($grid_x,$grid_y) → pixel ($pixel_x,$pixel_y)" >&2
        else
            pixel_x=$(awk "BEGIN {print int($DISPLAY_X_OFFSET + $grid_x * $DISPLAY_WIDTH / 100)}")
            pixel_y=$(awk "BEGIN {print int($DISPLAY_Y_OFFSET + $grid_y * $DISPLAY_HEIGHT / 100)}")
            echo "Display coords ($grid_x%,$grid_y%) → pixel ($pixel_x,$pixel_y)" >&2
        fi
    fi

    # Format for cliclick (= prefix for negative values)
    local cli_x="$pixel_x"
    local cli_y="$pixel_y"
    [[ $pixel_x -lt 0 ]] && cli_x="=$pixel_x"
    [[ $pixel_y -lt 0 ]] && cli_y="=$pixel_y"

    echo "$pixel_x $pixel_y $cli_x $cli_y"
}

# Show help
show_help() {
    cat << 'EOF'
Desktop Interaction Utility

USAGE:
    interact.sh [OPTIONS]

LLM-FRIENDLY FEATURES (automatic when --in-app is set):
    • App-scoped OCR: --click and --find-text filter results to ONLY the
      target app's window (ignores text in terminal or other windows)
    • Auto-wait: Navigation actions (click, key:return, back/forward) automatically
      wait for page to stabilize - no manual wait: commands needed. Waits timeout
      after 3000ms (configurable via --auto-wait-timeout) with a warning, not a hang.
    • Auto-read: Chains and standalone clicks/scrolls automatically return page
      content with clickable [x,y,w,h] bounding boxes (use with --click)
    • Coord translation: Coordinates from --read-page are app-relative and
      auto-translated by --click when --in-app is set

    IMPORTANT: Always set --in-app first! Without it, OCR searches the entire
    screen and may find text in the wrong window (like your terminal).

    Two ways to interact with UI elements:
      • OCR-based (--click "text"): Works with any visible text
      • Accessibility-based (--toggle, --info): Works with UI controls
        like toggles and info buttons that don't have clickable text

    Typical LLM workflow:
      1. ./interact.sh --in-app "System Settings"
         → Sets target app (persists across commands)
      2. ./interact.sh --click "Accessibility"
         → Finds and clicks text, filtered to app window only
      3. ./interact.sh --click --toggle "Mouse Keys"
         → Clicks toggle switch near "Mouse Keys" label (accessibility API)
      4. ./interact.sh --click --info "Mouse Keys"
         → Clicks info (i) button near "Mouse Keys" label (accessibility API)
      5. ./interact.sh --click 35.4,32.4
         → Auto-translates app coords, clicks, returns new page content

DISPLAY SELECTION:
    --display <n>             Target specific display for grid coordinates
                              (Use screenshot.sh --list-displays to see available)

TIMEOUT SETTINGS:
    --auto-wait-timeout <ms>  Set timeout for smart waits after navigation actions
                              (default: 3000ms). Affects auto-wait after clicks and
                              page read operations. If timeout is reached, command
                              continues with a warning instead of hanging.

CLICKING (unified --click command):
    --click <target>          Click on target (auto-detects text vs coordinates)
                              Text: --click "Submit Button"
                              Coords: --click 50,50 or --click 50,50,10,5 (box → center)
                              Pixels: --click px:1200,500 (absolute pixel coordinates)
                              No target: --click (clicks at current cursor position)

    Click modifiers (combine with --click):
    --double                  Double-click (e.g., --click "file.txt" --double)
    --right                   Right-click (opens context menu)
    --triple                  Triple-click (select line/paragraph in text editors)
    --near <text>             Click target nearest to anchor text

    Special click modes:
    --toggle <label>          Click toggle switch near label (A11y API)
    --info <label>            Click info button near label (A11y API)

OTHER MOUSE ACTIONS:
    --move <x>,<y>            Move mouse to grid percentage
    --move-pixel <x>,<y>      Move mouse to absolute pixel coordinates
    --drag <coords>           Drag with smooth, visible movement (grid %)
                              Formats: x1,y1,x2,y2 (point to point)
                                       x1,y1,w,h,x2,y2 (box to point, auto-centers start)
                              Tip: Use --region + --read-page to get element coordinates
    --drag-speed <slow|normal|fast>  Set drag speed (default: normal)
                              slow=2.5s, normal=1.6s, fast=0.6s (uses ease-in-out)
    --arc <pos:tension>       Add curve to drag path (use with --drag)
                              pos: ±1 to ±179 (+ curves left, - curves right)
                                   magnitude = arc angle (90 = quarter circle)
                              tension=0: TRUE circular arc (mathematically perfect)
                              tension≠0: Bézier approximation (-100=flat, +100=L-corner)
                              Example: --drag 20,50,80,50 --arc 90:0  (perfect quarter circle)
    --drag-easing <type>      Set drag easing (default: ease-in-out)
                              linear (constant speed, best for precision drawing)
                              ease-in (slow start), ease-out (slow end)
                              ease-in-out (natural movement)
    --drag-steps <n>          Set drag smoothness (default: 60, range: 10-500)
                              More steps = smoother curves, slower execution
    --aspect [region]         Enable square coordinate space (for shapes)
                              Maps 0-100% to equal pixel distances in X and Y
                              Optional region: x1,y1,x2,y2 (from --read-page bounds)
                              Example: --aspect 3,16,64,98 (canvas bounds)
    --nudge <dx>,<dy>         Nudge cursor by pixel offset (e.g., 0,-5 = up 5px)
    --scroll <dir> [amt] [x,y]  Scroll at position (dir: up/down/left/right, amt: units)
    --scroll-in-app <app> <dir> [amt]  Scroll within app's window (auto-finds display)
    --verify <x>,<y> [size]   Move to position and take crosshair screenshot
    --verify <x>,<y>,<w>,<h> [size]  Auto-centers on bounding box (from --read-page)
                              Works with --in-app, --aspect, --region
                              (use to verify position before clicking)

WINDOW QUERIES:
    --where <app>             Find which display/position an app's window is on
    --list-windows            List all visible windows with their apps and positions

OCR TEXT OPERATIONS:
    --find-text <text>        Find text and return bounding box [x,y,w,h]
    --list-text               List all text visible on current display
    --read-page [app] [opts]  Extract all visible text in LLM-friendly format
                              App is optional if --in-app is set
                              Options: --classify (detect element types)
                                       --json (structured JSON output)
                                       --save-screenshot <path>
                                       --no-images (skip image detection)
                                       --no-icons (skip icon detection)
                                       --region x1,y1,x2,y2 (filter to % region)
    --near <text>             Select match closest to anchor text (RECOMMENDED for disambiguation)
                              Use when multiple matches exist - finds the one nearest to anchor.
                              Example: --near "share save" --find-text "comments" finds "comments"
                              in the action bar, not the header. Works with --click-text, --find-text.
    --instance <n>            Select Nth match by position (fallback, less reliable than --near)
    --in-app <app>            Set target app (persists across commands, auto-reactivates)
    --clear-target            Clear the persistent target app
    --activate-before <app>   Activate app before clicking (use with --click-text)

UI ELEMENT OPERATIONS (accessibility-based, works with native macOS apps):
    Use these when you need to click UI controls that aren't text (toggles, icons).
    Uses macOS Accessibility API - more reliable than OCR for native app controls.

    --click-toggle <label>    Click toggle/switch near text label (e.g., "Mouse Keys")
    --click-info <label>      Click info (i) button near text label
    --list-elements [type]    List interactive UI elements (toggle, button, info, slider)
                              Requires --in-app to be set. Types: toggle, button, info, slider

    When to use OCR vs Accessibility:
      • --click-text: Any visible text (links, menu items, button labels)
      • --click-toggle/--click-info: UI controls without clickable text (switches, icons)
      • --list-elements: Discover what UI controls exist and their coordinates

ATOMIC COMMAND CHAINS:
    --chain <cmd1> <cmd2>... [--screenshot [path]]
                              Execute multiple commands atomically with auto-delays
                              Format: "action:argument" (e.g., "open:Firefox")
                              Actions: open, activate, wait, click, click-text, click-text-near,
                                       type, key, combo, scroll, page-top, page-bottom, in-app,
                                       switch-tab, goto, back, back-no-close, forward, up,
                                       home, end, close-tab, select-next, select-prev, select-first,
                                       select-last, open-selection, select-all, play-pause,
                                       next-track, prev-track, volume-up, volume-down, mute,
                                       brightness-up, brightness-down, screenshot, clipboard-read,
                                       copy-text, copy-image, copy-file, wait-for-text,
                                       wait-for-change, verify-text
                              OCR clicks: click-text:X - click on text X
                                          click-text-near:X|Y - click text X nearest to Y
                                          right-click-text:X - right-click on text X
                                          right-click-text-near:X|Y - right-click X near Y
                              Dragging: drag:x1,y1,x2,y2 - smooth drag between points
                                        drag:x1,y1,w,h,x2,y2 - drag from box center to point
                                        arc:pos:tension - curve preceding drag (±1-179:±100)
                                        dragend: - explicit mouse release (breaks auto-chain)
                                        drag-easing:type - set easing (linear/ease-in/etc)
                                        drag-steps:N - set smoothness (10-500)
                                        aspect[:x1,y1,x2,y2] - square coords (opt region)
                                        Auto-chaining: consecutive drags stay connected
                                        Example circle: "drag:70,50,50,30" "arc:90:0" \
                                                        "drag:50,30,30,50" "arc:90:0" ...
                                        Use --region + --read-page to get element coordinates
                              Navigation: back - smart back (auto-closes if no history)
                                          back-no-close - simple back (no auto-close)
                                          forward, up - browser/Finder navigation
                                          close-tab - close current tab/window
                              Selection: select-next/prev - move selection in lists
                                         open-selection - open/activate selected item
                              Media: play-pause, next-track, prev-track - media playback
                                     volume-up[:N], volume-down[:N], mute - audio control
                                     brightness-up[:N], brightness-down[:N] - display
                              Scroll: scroll:dir[,amt] - uses in-app context if set
                                      scroll-capture:dir,amt,path - scroll and capture
                                      (amt can be: page, half, little, or number)
                              Page nav: page-top, page-bottom - scrolls to top/bottom
                              Tabs: switch-tab:term - search & switch to existing tab
                                    goto:term - find tab or navigate (lists if ambiguous)
                                    goto:term:N - select Nth match when multiple found
                              Wait/Verify: wait-for-text:pattern[,appear|gone][,timeout_ms]
                                           wait-for-change[:x,y,w,h][,timeout_ms]
                                           verify-text:pattern[,present|gone]
                                           Chain FAILS if condition not met (enables retry)
                              Screenshot: screenshot[:path] - capture screen mid-chain
                              Clipboard: clipboard-read - read and output clipboard
                                         copy-text:text - copy text to clipboard (clobbers)
                                         copy-image:path - copy image to clipboard
                                         copy-file:path - copy file to clipboard
                                         paste:text - type via paste (preserves clipboard)
                                           Use paste: instead of type: for URLs and special chars
                                           Faster than type:, preserves user's clipboard content
                              --screenshot [path] - capture screen at end of chain

KEYBOARD ACTIONS:
    --type <text>             Type text (safe mode with 30ms delay between chars)
    --type-delay <ms>         Set inter-character delay (default: 30ms)
    --type-fast               Use fast typing via cliclick (may trigger shortcuts)
    --key <key>               Press key (e.g., return, escape, tab)
    --combo <mod+key>         Key combination (e.g., cmd+t, cmd+shift+s)

APP CONTROL:
    --open <app>              Open/launch app (more reliable for apps not running)
    --activate <app>          Bring app to front (also launches if not running)
    --hide <app>              Hide app
    --quit <app>              Quit app

UTILITY:
    --wait <ms>               Wait milliseconds before next action
    --wait-for-new-window [s] Wait for new window, auto-set IN_APP (default: 10s timeout)
                              Use after --click "file" --double to detect launched app
    --screen-size             Show screen dimensions (for current display)
    --mouse-pos               Show current mouse position
    --list-displays           Show all displays with offsets
    --show-cursor             Force cursor visible (macOS hides during typing)

AUDIO/MEDIA CONTROL:
    --media-state             Show all media state (audio, now playing, brightness)
    --audio-state             Show current audio state (volume, muted)
    --audio-state-json        Audio state as JSON (for scripting)
    --volume <0-100>          Set output volume level
    --mute                    Toggle mute state
    --unmute                  Ensure audio is unmuted (no-op if already unmuted)
    --now-playing             Show currently playing media (title, artist, progress)
    --now-playing-json        Now playing info as JSON
    --brightness              Show display brightness (built-in display only)
    --brightness-json         Brightness as JSON

CLIPBOARD OPERATIONS:
    --clipboard               Read clipboard content (auto-detects type: text/image/files)
    --clipboard-type          Show clipboard content type (text/image/files/empty)
    --copy-text <string>      Copy text to clipboard
    --copy-image <path>       Copy image file to clipboard
    --copy-file <path>        Copy file reference to clipboard (for Finder paste)

WAIT/VERIFICATION (for reliable automation):
    --wait-for-text <pattern> [appear|gone] [timeout_ms]
                              Wait for text to appear/disappear (default: appear, 5000ms)
    --wait-for-change [x,y,w,h] [timeout_ms]
                              Wait for screen region to change (default: full screen, 5000ms)
    --verify-text <pattern> [present|gone]
                              Check if text is present/gone (returns exit code)

COORDINATE SYSTEM:
    Grid percentages: 0,0 = top-left, 100,100 = bottom-right

    Without --in-app: Coordinates are display-relative (full screen)
    With --in-app:    Coordinates are app-relative (within app window)
                      --read-page returns app-relative coords
                      --click auto-translates app-relative to screen coords

    Use --display to target a specific monitor
    Use screenshot.sh --display <n> --grid to see coordinates for that display

EXAMPLES:
    ./interact.sh --click 50,50              # Click center of main display
    ./interact.sh --click "Submit"           # Click on text (auto-detected)
    ./interact.sh --click px:-1200,500       # Click at absolute pixel coordinates
    ./interact.sh --click "file.txt" --double  # Double-click (open in Finder)
    ./interact.sh --click "Edit" --right     # Right-click (context menu)
    ./interact.sh --click --triple           # Triple-click at cursor (select line)
    ./interact.sh --type "Hello World"       # Type text (safe mode)
    ./interact.sh --combo cmd+t              # New browser tab

WINDOW QUERY EXAMPLES:
    # Find which display an app is on (do this BEFORE screenshotting!)
    ./interact.sh --where "System Settings"

    # List all visible windows
    ./interact.sh --list-windows

CLICK EXAMPLES:
    # Click text ONLY within a specific app's window (avoids terminal text)
    ./interact.sh --in-app "System Settings" --click "Accessibility"

    # Double-click to open file in Finder
    ./interact.sh --in-app Finder --click "document.pdf" --double

    # Right-click for context menu
    ./interact.sh --in-app Firefox --click "image.png" --right

    # Click with proximity disambiguation
    ./interact.sh --in-app Firefox --near "article title" --click "comments"

    # Find text without clicking (returns coordinates)
    ./interact.sh --in-app "System Settings" --find-text "Display"

VERIFICATION WORKFLOW (preview before clicking):
    # 1. Get coordinates from read-page
    ./interact.sh --in-app Firefox --read-page
    # → Returns: [45.2,67.8,10,5] Submit Button

    # 2. Verify with crosshairs (works with --in-app, --aspect, bounding boxes)
    ./interact.sh --in-app Firefox --verify 45.2,67.8,10,5
    # → Moves cursor to center of bounding box, takes crosshair screenshot
    # → View screenshot to confirm target is correct

    # 3. Click at verified position
    ./interact.sh --in-app Firefox --click 45.2,67.8,10,5

ATOMIC CHAIN EXAMPLES:
    # Navigate to URL in Firefox (no manual waits needed - auto-wait after return)
    ./interact.sh --chain "in-app:Firefox" "combo:cmd+l" "type:news.ycombinator.com" "key:return"
    # → Auto-waits for page load, returns page content with clickable coordinates

    # Click on text (with auto-wait and auto-read)
    ./interact.sh --chain "in-app:Firefox" "click:68 comments"
    # → Clicks, auto-waits, returns new page content

    # Double-click and right-click in chains
    ./interact.sh --chain "in-app:Finder" "click:document.pdf|double"
    ./interact.sh --chain "in-app:Firefox" "click:image.png|right"

    # Click with proximity in chains
    ./interact.sh --chain "in-app:Firefox" "click:comments|near:article title"

UI ELEMENT EXAMPLES (for toggles, info buttons, and other non-text controls):
    # Set target app first (required for all UI element commands)
    ./interact.sh --in-app "System Settings"

    # List all toggles in the current view
    ./interact.sh --list-elements toggle
    # → Shows: [89.8,57.8] AX_MOUSE_KEYS = 0.0

    # Click a toggle by its nearby text label
    ./interact.sh --click --toggle "Mouse Keys"
    # → Finds toggle on same row as "Mouse Keys" text, clicks it

    # Click an info (i) button to open settings detail
    ./interact.sh --click --info "Mouse Keys"
    # → Finds info button on same row as "Mouse Keys" text, clicks it

    # In chains
    ./interact.sh --chain "in-app:System Settings" "click:toggle:Mouse Keys"

TARGETING WORKFLOW (manual - use OCR instead when possible):
    1. ./interact.sh --display 2 --verify 54,64   # Move & verify with crosshairs
    2. (view screenshot to check if crosshairs are on target)
    3. ./interact.sh --nudge 0,-5                 # Adjust up 5 pixels if needed
    4. ./interact.sh --click                      # Click at current position

MULTI-MONITOR WORKFLOW:
    1. ./screenshot.sh --list-displays       # See display offsets
    2. ./screenshot.sh --display 2 --grid    # Screenshot display 2 with grid
    3. ./interact.sh --display 2 --click 54,35  # Click at grid position
    4. ./screenshot.sh --display 2           # Verify result

HELP:
    -h, --help                Show this help message
    -s, --status              Check dependencies and permissions
EOF
}

# Show status of dependencies and permissions
show_status() {
    echo "=== interact.sh Status ==="
    echo ""
    local all_ok=true

    # Dependencies
    echo "Dependencies:"

    # Python venv
    if [[ -f "$PYTHON" ]]; then
        local py_version=$("$PYTHON" --version 2>&1 | head -1)
        echo "  [OK] Python venv ($py_version)"
    else
        echo "  [MISSING] Python venv - Run: ./setup.sh"
        all_ok=false
    fi

    # cliclick
    if command -v cliclick &> /dev/null; then
        local cliclick_version=$(cliclick -V 2>&1 | head -1)
        echo "  [OK] cliclick $cliclick_version (mouse/keyboard)"
    else
        echo "  [MISSING] cliclick - Install with: brew install cliclick"
        all_ok=false
    fi

    # Pillow
    if [[ -f "$PYTHON" ]] && "$PYTHON" -c "import PIL" 2>/dev/null; then
        local pil_version=$("$PYTHON" -c "import PIL; print(PIL.__version__)" 2>/dev/null)
        echo "  [OK] Pillow $pil_version (image processing)"
    else
        echo "  [MISSING] Pillow - Run: ./setup.sh"
        all_ok=false
    fi

    # pyobjc-framework-Quartz
    if [[ -f "$PYTHON" ]] && "$PYTHON" -c "import Quartz" 2>/dev/null; then
        echo "  [OK] pyobjc-framework-Quartz (OCR, windows)"
    else
        echo "  [MISSING] pyobjc-framework-Quartz - Run: ./setup.sh"
        all_ok=false
    fi

    # pyobjc-framework-Cocoa (for Vision/OCR)
    if [[ -f "$PYTHON" ]] && "$PYTHON" -c "import Cocoa" 2>/dev/null; then
        echo "  [OK] pyobjc-framework-Cocoa (Vision/OCR)"
    else
        echo "  [MISSING] pyobjc-framework-Cocoa - Run: ./setup.sh"
        all_ok=false
    fi

    # lz4 (for Firefox tabs)
    if [[ -f "$PYTHON" ]] && "$PYTHON" -c "import lz4" 2>/dev/null; then
        echo "  [OK] lz4 (Firefox session reading)"
    else
        echo "  [MISSING] lz4 - Run: ./setup.sh"
        all_ok=false
    fi

    echo ""
    echo "Permissions:"

    # Screen Recording
    local test_file="/tmp/screenshot_permission_test_$$.png"
    screencapture -x "$test_file" 2>/dev/null
    if [[ -f "$test_file" ]]; then
        rm -f "$test_file"
        echo "  [OK] Screen Recording"
    else
        echo "  [DENIED] Screen Recording"
        echo "          Enable in: System Settings > Privacy & Security > Screen Recording"
        all_ok=false
    fi

    # Accessibility (test by trying to get frontmost app)
    local ax_test=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>&1)
    if [[ "$ax_test" != *"not allowed"* && "$ax_test" != *"error"* && -n "$ax_test" ]]; then
        echo "  [OK] Accessibility"
    else
        echo "  [DENIED] Accessibility"
        echo "          Enable in: System Settings > Privacy & Security > Accessibility"
        all_ok=false
    fi

    echo ""
    if $all_ok; then
        echo "Status: All checks passed"
    else
        echo "Status: Issues detected (see above)"
    fi
}

# Check for cliclick
check_cliclick() {
    if ! command -v cliclick &> /dev/null; then
        echo "ERROR: cliclick not found. Install with: brew install cliclick"
        exit 1
    fi
}

# Mouse click at grid coordinates
# Accepts either point (x,y) or box (x,y,w,h) - box auto-clicks center
click_grid() {
    local coords="$1"
    local click_type="${2:-c}"  # c=click, rc=right-click, dc=double-click

    # Restore target app if set
    restore_target_app

    # Parse coordinates - support both x,y and x,y,w,h formats
    IFS=',' read -r grid_x grid_y grid_w grid_h <<< "$coords"

    if [[ -z "$grid_x" || -z "$grid_y" ]]; then
        echo "ERROR: Invalid coordinates. Use format: x,y or x,y,w,h"
        return 1
    fi

    # If box format (x,y,w,h), calculate center point
    if [[ -n "$grid_w" && -n "$grid_h" ]]; then
        grid_x=$(awk "BEGIN {printf \"%.1f\", $grid_x + $grid_w / 2}")
        grid_y=$(awk "BEGIN {printf \"%.1f\", $grid_y + $grid_h / 2}")
        echo "Box coords → center ($grid_x,$grid_y)" >&2
    fi

    # Track click position for visual feedback in auto-read screenshots
    LAST_CLICK_X="$grid_x"
    LAST_CLICK_Y="$grid_y"

    # Translate app-relative coords to display-relative when IN_APP is set
    if [[ -n "$IN_APP" ]]; then
        local where=$("$PYTHON" "$WINDOW_LIST" --app "$IN_APP" --where 2>&1)
        if ! echo "$where" | grep -q "No window found"; then
            local bounds=$(echo "$where" | grep "^BOUNDS:" | sed 's/BOUNDS: //')
            if [[ -n "$bounds" ]]; then
                IFS=',' read -r win_x win_y win_w win_h <<< "$bounds"

                # When ASPECT_CORRECT is set with IN_APP, use app window dimensions for square space
                if [[ -n "$ASPECT_CORRECT" ]]; then
                    local min_dim=$((win_w < win_h ? win_w : win_h))
                    local offset_x=$(( (win_w - min_dim) / 2 ))
                    local offset_y=$(( (win_h - min_dim) / 2 ))

                    # Aspect coords → absolute pixel (centered square within app window)
                    local abs_x=$(awk "BEGIN {print int($win_x + $offset_x + $grid_x * $min_dim / 100)}")
                    local abs_y=$(awk "BEGIN {print int($win_y + $offset_y + $grid_y * $min_dim / 100)}")

                    echo "Aspect click ($grid_x,$grid_y) in ${min_dim}x${min_dim} square → pixel ($abs_x,$abs_y)" >&2

                    # Click directly at pixel - bypass grid_to_pixel
                    local cli_x="$abs_x"
                    local cli_y="$abs_y"
                    [[ $abs_x -lt 0 ]] && cli_x="=$abs_x"
                    [[ $abs_y -lt 0 ]] && cli_y="=$abs_y"

                    if [[ "$click_type" == "dc" ]]; then
                        cliclick "$click_type:$cli_x,$cli_y"
                    elif [[ "$click_type" == "tc" ]]; then
                        # Triple-click: 3 rapid clicks
                        cliclick "c:$cli_x,$cli_y" "c:$cli_x,$cli_y" "c:$cli_x,$cli_y"
                    else
                        cliclick "m:$cli_x,$cli_y" "$click_type:."
                    fi
                    auto_read_page
                    return 0
                fi

                # App-relative % → absolute pixel
                local abs_x=$(awk "BEGIN {print int($win_x + $grid_x * $win_w / 100)}")
                local abs_y=$(awk "BEGIN {print int($win_y + $grid_y * $win_h / 100)}")

                # Absolute pixel → display-relative %
                local orig_x="$grid_x"
                local orig_y="$grid_y"
                grid_x=$(awk "BEGIN {printf \"%.1f\", ($abs_x - $DISPLAY_X_OFFSET) * 100 / $DISPLAY_WIDTH}")
                grid_y=$(awk "BEGIN {printf \"%.1f\", ($abs_y - $DISPLAY_Y_OFFSET) * 100 / $DISPLAY_HEIGHT}")

                echo "Translated app coords ($orig_x,$orig_y) → display coords ($grid_x,$grid_y)" >&2
            fi
        fi
    fi

    local pixels=$(grid_to_pixel "$grid_x" "$grid_y")
    local pixel_x=$(echo "$pixels" | awk '{print $1}')
    local pixel_y=$(echo "$pixels" | awk '{print $2}')
    local cli_x=$(echo "$pixels" | awk '{print $3}')
    local cli_y=$(echo "$pixels" | awk '{print $4}')

    echo "Clicking at grid ($grid_x%, $grid_y%) = pixel ($pixel_x, $pixel_y)"
    # Use direct coordinates for double-click (dc) and triple-click (tc) to avoid timing issues
    # For other click types, move+click works fine
    if [[ "$click_type" == "dc" ]]; then
        cliclick "$click_type:$cli_x,$cli_y"
    elif [[ "$click_type" == "tc" ]]; then
        # Triple-click: 3 rapid clicks (cliclick doesn't support tc natively)
        cliclick "c:$cli_x,$cli_y" "c:$cli_x,$cli_y" "c:$cli_x,$cli_y"
    else
        cliclick "m:$cli_x,$cli_y" "$click_type:."
    fi

    # Auto-read page after click when IN_APP is set
    auto_read_page
}

# Mouse click at pixel coordinates
click_pixel() {
    local coords="$1"
    local click_type="${2:-c}"

    IFS=',' read -r pixel_x pixel_y <<< "$coords"

    if [[ -z "$pixel_x" || -z "$pixel_y" ]]; then
        echo "ERROR: Invalid coordinates. Use format: x,y (e.g., 800,400)"
        return 1
    fi

    # Format for cliclick (= prefix for absolute negative values)
    local cli_x="$pixel_x"
    local cli_y="$pixel_y"
    [[ $pixel_x -lt 0 ]] && cli_x="=$pixel_x"
    [[ $pixel_y -lt 0 ]] && cli_y="=$pixel_y"

    echo "Clicking at pixel ($pixel_x, $pixel_y)"
    # Use direct coordinates for double-click (dc) and triple-click (tc) to avoid timing issues
    if [[ "$click_type" == "dc" ]]; then
        cliclick "$click_type:$cli_x,$cli_y"
    elif [[ "$click_type" == "tc" ]]; then
        # Triple-click: 3 rapid clicks (cliclick doesn't support tc natively)
        cliclick "c:$cli_x,$cli_y" "c:$cli_x,$cli_y" "c:$cli_x,$cli_y"
    else
        cliclick "m:$cli_x,$cli_y" "$click_type:."
    fi
}

# Move mouse
move_mouse() {
    local coords="$1"
    local is_pixel="$2"

    IFS=',' read -r x y <<< "$coords"

    local pixel_x pixel_y cli_x cli_y
    if [[ "$is_pixel" == "true" ]]; then
        pixel_x="$x"
        pixel_y="$y"
        # Format for cliclick
        cli_x="$pixel_x"
        cli_y="$pixel_y"
        [[ $pixel_x -lt 0 ]] && cli_x="=$pixel_x"
        [[ $pixel_y -lt 0 ]] && cli_y="=$pixel_y"
        echo "Moving mouse to pixel ($pixel_x, $pixel_y)"
    else
        local pixels=$(grid_to_pixel "$x" "$y")
        pixel_x=$(echo "$pixels" | awk '{print $1}')
        pixel_y=$(echo "$pixels" | awk '{print $2}')
        cli_x=$(echo "$pixels" | awk '{print $3}')
        cli_y=$(echo "$pixels" | awk '{print $4}')
        echo "Moving mouse to grid ($x%, $y%) = pixel ($pixel_x, $pixel_y)"
    fi

    # cliclick move alone doesn't persist - use move + tiny nudge to make it stick
    # Calculate nudge in cliclick format
    local nudge_x=$((pixel_x + 1))
    local cli_nudge_x="$nudge_x"
    [[ $nudge_x -lt 0 ]] && cli_nudge_x="=$nudge_x"

    cliclick "m:$cli_x,$cli_y" "m:$cli_nudge_x,$cli_y" "m:$cli_x,$cli_y"
}

# Convert drag grid coordinates to absolute pixels
# Returns: abs_x1,abs_y1,abs_x2,abs_y2 or empty on error
# Uses IN_APP, REGION, ASPECT_CORRECT globals
drag_coords_to_pixels() {
    local coords="$1"

    # Parse coordinates - support both formats
    IFS=',' read -r v1 v2 v3 v4 v5 v6 <<< "$coords"

    local x1 y1 x2 y2

    if [[ -n "$v5" && -n "$v6" ]]; then
        # 6 values: x,y,w,h,x2,y2 - box to point format
        x1=$(awk "BEGIN {printf \"%.1f\", $v1 + $v3 / 2}")
        y1=$(awk "BEGIN {printf \"%.1f\", $v2 + $v4 / 2}")
        x2="$v5"
        y2="$v6"
    else
        # 4 values: x1,y1,x2,y2
        x1="$v1"
        y1="$v2"
        x2="$v3"
        y2="$v4"
    fi

    [[ -z "$x1" || -z "$y1" || -z "$x2" || -z "$y2" ]] && return 1

    local abs_x1 abs_y1 abs_x2 abs_y2

    if [[ -n "$IN_APP" ]]; then
        local where=$("$PYTHON" "$WINDOW_LIST" --app "$IN_APP" --where 2>&1)
        if ! echo "$where" | grep -q "No window found"; then
            local bounds=$(echo "$where" | grep "^BOUNDS:" | sed 's/BOUNDS: //')
            if [[ -n "$bounds" ]]; then
                IFS=',' read -r win_x win_y win_w win_h <<< "$bounds"

                local draw_x draw_y draw_w draw_h
                if [[ -n "$REGION" ]]; then
                    IFS=',' read -r rx1 ry1 rx2 ry2 <<< "$REGION"
                    draw_x=$(awk "BEGIN {print int($win_x + $rx1 * $win_w / 100)}")
                    draw_y=$(awk "BEGIN {print int($win_y + $ry1 * $win_h / 100)}")
                    draw_w=$(awk "BEGIN {print int(($rx2 - $rx1) * $win_w / 100)}")
                    draw_h=$(awk "BEGIN {print int(($ry2 - $ry1) * $win_h / 100)}")
                else
                    draw_x=$win_x
                    draw_y=$win_y
                    draw_w=$win_w
                    draw_h=$win_h
                fi

                if [[ -n "$ASPECT_CORRECT" ]]; then
                    local min_dim=$((draw_w < draw_h ? draw_w : draw_h))
                    local off_x=$(( (draw_w - min_dim) / 2 ))
                    local off_y=$(( (draw_h - min_dim) / 2 ))
                    abs_x1=$(awk "BEGIN {print int($draw_x + $off_x + $x1 * $min_dim / 100)}")
                    abs_y1=$(awk "BEGIN {print int($draw_y + $off_y + $y1 * $min_dim / 100)}")
                    abs_x2=$(awk "BEGIN {print int($draw_x + $off_x + $x2 * $min_dim / 100)}")
                    abs_y2=$(awk "BEGIN {print int($draw_y + $off_y + $y2 * $min_dim / 100)}")
                else
                    abs_x1=$(awk "BEGIN {print int($draw_x + $x1 * $draw_w / 100)}")
                    abs_y1=$(awk "BEGIN {print int($draw_y + $y1 * $draw_h / 100)}")
                    abs_x2=$(awk "BEGIN {print int($draw_x + $x2 * $draw_w / 100)}")
                    abs_y2=$(awk "BEGIN {print int($draw_y + $y2 * $draw_h / 100)}")
                fi
            fi
        fi
    fi

    # Fallback to display-relative
    if [[ -z "$abs_x1" ]]; then
        if [[ -n "$ASPECT_CORRECT" ]]; then
            local min_dim=$((DISPLAY_WIDTH < DISPLAY_HEIGHT ? DISPLAY_WIDTH : DISPLAY_HEIGHT))
            local off_x=$(( (DISPLAY_WIDTH - min_dim) / 2 ))
            local off_y=$(( (DISPLAY_HEIGHT - min_dim) / 2 ))
            abs_x1=$(awk "BEGIN {print int($DISPLAY_X_OFFSET + $off_x + $x1 * $min_dim / 100)}")
            abs_y1=$(awk "BEGIN {print int($DISPLAY_Y_OFFSET + $off_y + $y1 * $min_dim / 100)}")
            abs_x2=$(awk "BEGIN {print int($DISPLAY_X_OFFSET + $off_x + $x2 * $min_dim / 100)}")
            abs_y2=$(awk "BEGIN {print int($DISPLAY_Y_OFFSET + $off_y + $y2 * $min_dim / 100)}")
        else
            abs_x1=$(awk "BEGIN {print int($DISPLAY_X_OFFSET + $x1 * $DISPLAY_WIDTH / 100)}")
            abs_y1=$(awk "BEGIN {print int($DISPLAY_Y_OFFSET + $y1 * $DISPLAY_HEIGHT / 100)}")
            abs_x2=$(awk "BEGIN {print int($DISPLAY_X_OFFSET + $x2 * $DISPLAY_WIDTH / 100)}")
            abs_y2=$(awk "BEGIN {print int($DISPLAY_Y_OFFSET + $y2 * $DISPLAY_HEIGHT / 100)}")
        fi
    fi

    echo "$abs_x1,$abs_y1,$abs_x2,$abs_y2"
}

# Drag from point to point with smooth, visible movement
# Uses intermediate points so web apps register the drag properly
# Supports two formats:
#   x1,y1,x2,y2       - point to point
#   x1,y1,w1,h1,x2,y2 - box (auto-centered) to point
drag_mouse() {
    local coords="$1"
    local skip_down="${2:-}"  # If "1", skip mouse-down (already held from prev drag)
    local skip_up="${3:-}"    # If "1", skip mouse-up (more drags coming)

    # Parse coordinates - support both formats
    IFS=',' read -r v1 v2 v3 v4 v5 v6 <<< "$coords"

    local x1 y1 x2 y2

    if [[ -n "$v5" && -n "$v6" ]]; then
        # 6 values: x,y,w,h,x2,y2 - box to point format
        # Calculate center of start box
        x1=$(awk "BEGIN {printf \"%.1f\", $v1 + $v3 / 2}")
        y1=$(awk "BEGIN {printf \"%.1f\", $v2 + $v4 / 2}")
        x2="$v5"
        y2="$v6"
        echo "Start box → center ($x1,$y1)" >&2
    else
        # 4 values: x1,y1,x2,y2 - point to point format
        x1="$v1"
        y1="$v2"
        x2="$v3"
        y2="$v4"
    fi

    if [[ -z "$x1" || -z "$y1" || -z "$x2" || -z "$y2" ]]; then
        echo "ERROR: Invalid coordinates. Use format: x1,y1,x2,y2 or x1,y1,w1,h1,x2,y2"
        return 1
    fi

    # Restore target app if set
    restore_target_app

    # Convert percentages to absolute pixel coordinates
    # Priority: REGION (if set) > IN_APP > display
    local abs_x1 abs_y1 abs_x2 abs_y2

    if [[ -n "$IN_APP" ]]; then
        local where=$("$PYTHON" "$WINDOW_LIST" --app "$IN_APP" --where 2>&1)
        if ! echo "$where" | grep -q "No window found"; then
            local bounds=$(echo "$where" | grep "^BOUNDS:" | sed 's/BOUNDS: //')
            if [[ -n "$bounds" ]]; then
                IFS=',' read -r win_x win_y win_w win_h <<< "$bounds"

                # If REGION is set, calculate the region bounds within the window
                local draw_x draw_y draw_w draw_h
                if [[ -n "$REGION" ]]; then
                    # REGION format: rx1,ry1,rx2,ry2 (percentages within window)
                    IFS=',' read -r rx1 ry1 rx2 ry2 <<< "$REGION"
                    draw_x=$(awk "BEGIN {print int($win_x + $rx1 * $win_w / 100)}")
                    draw_y=$(awk "BEGIN {print int($win_y + $ry1 * $win_h / 100)}")
                    draw_w=$(awk "BEGIN {print int(($rx2 - $rx1) * $win_w / 100)}")
                    draw_h=$(awk "BEGIN {print int(($ry2 - $ry1) * $win_h / 100)}")
                else
                    draw_x=$win_x
                    draw_y=$win_y
                    draw_w=$win_w
                    draw_h=$win_h
                fi

                if [[ -n "$ASPECT_CORRECT" ]]; then
                    # Square coordinate space within region/window
                    local min_dim=$((draw_w < draw_h ? draw_w : draw_h))
                    local off_x=$(( (draw_w - min_dim) / 2 ))
                    local off_y=$(( (draw_h - min_dim) / 2 ))
                    abs_x1=$(awk "BEGIN {print int($draw_x + $off_x + $x1 * $min_dim / 100)}")
                    abs_y1=$(awk "BEGIN {print int($draw_y + $off_y + $y1 * $min_dim / 100)}")
                    abs_x2=$(awk "BEGIN {print int($draw_x + $off_x + $x2 * $min_dim / 100)}")
                    abs_y2=$(awk "BEGIN {print int($draw_y + $off_y + $y2 * $min_dim / 100)}")
                else
                    abs_x1=$(awk "BEGIN {print int($draw_x + $x1 * $draw_w / 100)}")
                    abs_y1=$(awk "BEGIN {print int($draw_y + $y1 * $draw_h / 100)}")
                    abs_x2=$(awk "BEGIN {print int($draw_x + $x2 * $draw_w / 100)}")
                    abs_y2=$(awk "BEGIN {print int($draw_y + $y2 * $draw_h / 100)}")
                fi
            fi
        fi
    fi

    # Fallback to display-relative if no app context
    if [[ -z "$abs_x1" ]]; then
        if [[ -n "$ASPECT_CORRECT" ]]; then
            # Square coordinate space within display
            local min_dim=$((DISPLAY_WIDTH < DISPLAY_HEIGHT ? DISPLAY_WIDTH : DISPLAY_HEIGHT))
            local off_x=$(( (DISPLAY_WIDTH - min_dim) / 2 ))
            local off_y=$(( (DISPLAY_HEIGHT - min_dim) / 2 ))
            abs_x1=$(awk "BEGIN {print int($DISPLAY_X_OFFSET + $off_x + $x1 * $min_dim / 100)}")
            abs_y1=$(awk "BEGIN {print int($DISPLAY_Y_OFFSET + $off_y + $y1 * $min_dim / 100)}")
            abs_x2=$(awk "BEGIN {print int($DISPLAY_X_OFFSET + $off_x + $x2 * $min_dim / 100)}")
            abs_y2=$(awk "BEGIN {print int($DISPLAY_Y_OFFSET + $off_y + $y2 * $min_dim / 100)}")
        else
            abs_x1=$(awk "BEGIN {print int($DISPLAY_X_OFFSET + $x1 * $DISPLAY_WIDTH / 100)}")
            abs_y1=$(awk "BEGIN {print int($DISPLAY_Y_OFFSET + $y1 * $DISPLAY_HEIGHT / 100)}")
            abs_x2=$(awk "BEGIN {print int($DISPLAY_X_OFFSET + $x2 * $DISPLAY_WIDTH / 100)}")
            abs_y2=$(awk "BEGIN {print int($DISPLAY_Y_OFFSET + $y2 * $DISPLAY_HEIGHT / 100)}")
        fi
    fi

    # Check if arc parameters are set
    if [[ -n "$ARC_POSITION" ]]; then
        echo "Arc dragging from ($x1%, $y1%) to ($x2%, $y2%) [pos=$ARC_POSITION, tension=$ARC_TENSION]" >&2
    else
        echo "Dragging from ($x1%, $y1%) to ($x2%, $y2%)" >&2
    fi
    echo "Pixels: ($abs_x1, $abs_y1) → ($abs_x2, $abs_y2)" >&2

    # Use Python/Quartz for smooth drag
    local duration=${DRAG_DURATION:-1.6}
    local easing=${DRAG_EASING:-ease-in-out}
    local steps=${DRAG_STEPS:-60}
    local arc_pos="${ARC_POSITION:-0}"
    local arc_tension="${ARC_TENSION:-0}"
    local skip_down_flag="${skip_down:-0}"
    local skip_up_flag="${skip_up:-0}"
    "$PYTHON" - "$abs_x1" "$abs_y1" "$abs_x2" "$abs_y2" "$duration" "$arc_pos" "$arc_tension" "$skip_down_flag" "$skip_up_flag" "$easing" "$steps" <<'PYEOF'
import sys
import time
import math
from Quartz import (
    CGEventCreateMouseEvent,
    CGEventPost,
    kCGEventLeftMouseDown,
    kCGEventLeftMouseUp,
    kCGEventLeftMouseDragged,
    kCGHIDEventTap,
    CGEventSetIntegerValueField,
    kCGMouseEventClickState
)

def ease_linear(t):
    """Linear interpolation - constant speed, best for precision drawing."""
    return t

def ease_in(t):
    """Cubic ease-in - slow start, fast end."""
    return t * t * t

def ease_out(t):
    """Cubic ease-out - fast start, slow end."""
    return 1 - pow(1 - t, 3)

def ease_in_out(t):
    """Cubic ease-in-out - slow start and end, fast middle."""
    if t < 0.5:
        return 4 * t * t * t
    else:
        return 1 - pow(-2 * t + 2, 3) / 2

EASING_FUNCS = {
    'linear': ease_linear,
    'ease-in': ease_in,
    'ease-out': ease_out,
    'ease-in-out': ease_in_out,
}

def smooth_drag(x1, y1, x2, y2, duration=1.6, steps=60, arc_position=0, arc_tension=0,
                skip_mouse_down=False, skip_mouse_up=False, easing='ease-in-out'):
    """
    Perform smooth drag using Quartz events.

    arc_position: ±1 to ±179
        Sign = direction (+ curves left, - curves right)
        Magnitude = apex location (1=start, 90=center, 179=end)
    arc_tension: shape control
        negative = straighter, 0 = circular arc, positive = L-cornered
    skip_mouse_down: If True, assume mouse is already held (for chained drags)
    skip_mouse_up: If True, don't release mouse (for chained drags)
    easing: 'linear', 'ease-in', 'ease-out', 'ease-in-out'
           For chained drags: easing only applies at chain boundaries
           - First drag (skip_down=False): applies ease-in
           - Last drag (skip_up=False): applies ease-out
           - Middle drags: always linear for smooth continuous motion
    """
    # Determine effective easing based on chain position
    if easing == 'linear':
        ease_func = ease_linear
    elif skip_mouse_down and skip_mouse_up:
        # Middle of chain: always linear for smooth motion
        ease_func = ease_linear
    elif skip_mouse_down and not skip_mouse_up:
        # Last segment: ease-out only
        ease_func = ease_out if easing in ('ease-out', 'ease-in-out') else ease_linear
    elif not skip_mouse_down and skip_mouse_up:
        # First segment: ease-in only
        ease_func = ease_in if easing in ('ease-in', 'ease-in-out') else ease_linear
    else:
        # Single drag (no chaining): use full easing
        ease_func = EASING_FUNCS.get(easing, ease_in_out)

    if not skip_mouse_down:
        # Move to start position
        move_event = CGEventCreateMouseEvent(None, kCGEventLeftMouseDragged, (x1, y1), 0)
        CGEventPost(kCGHIDEventTap, move_event)
        time.sleep(0.05)

        # Mouse down
        down_event = CGEventCreateMouseEvent(None, kCGEventLeftMouseDown, (x1, y1), 0)
        CGEventSetIntegerValueField(down_event, kCGMouseEventClickState, 1)
        CGEventPost(kCGHIDEventTap, down_event)
        time.sleep(0.05)

    # Calculate arc parameters
    use_true_circle = (arc_position != 0 and arc_tension == 0)
    ctrl_x, ctrl_y = None, None
    center_x, center_y, radius, start_angle, end_angle = None, None, None, None, None

    if arc_position != 0:
        # Chord vector
        dx, dy = x2 - x1, y2 - y1
        chord_len = math.sqrt(dx*dx + dy*dy)

        if chord_len > 0:
            # Direction from sign of position
            perp_sign = 1 if arc_position > 0 else -1

            if use_true_circle:
                # TRUE CIRCULAR ARC when tension=0
                # position magnitude = arc angle in degrees (90 = quarter circle)
                arc_angle_deg = abs(arc_position)
                arc_angle = math.radians(arc_angle_deg)

                # Radius from chord and arc angle: chord = 2 * r * sin(θ/2)
                half_angle = arc_angle / 2
                radius = chord_len / (2 * math.sin(half_angle))

                # Center is perpendicular from midpoint of chord
                # Distance from midpoint to center = r * cos(θ/2)
                mid_x = (x1 + x2) / 2
                mid_y = (y1 + y2) / 2

                # Perpendicular unit vector (screen coords: Y increases downward)
                perp_x = dy / chord_len * perp_sign
                perp_y = -dx / chord_len * perp_sign

                center_dist = radius * math.cos(half_angle)
                center_x = mid_x + perp_x * center_dist
                center_y = mid_y + perp_y * center_dist

                # Calculate start and end angles from center
                start_angle = math.atan2(y1 - center_y, x1 - center_x)
                end_angle = math.atan2(y2 - center_y, x2 - center_x)

                # Ensure we go the right direction around the circle
                # For positive position (left curve), we want counterclockwise
                # For negative position (right curve), we want clockwise
                angle_diff = end_angle - start_angle

                # Normalize angle difference to determine direction
                if perp_sign > 0:  # Left curve = counterclockwise
                    if angle_diff < 0:
                        angle_diff += 2 * math.pi
                    if angle_diff > math.pi:
                        angle_diff -= 2 * math.pi
                else:  # Right curve = clockwise
                    if angle_diff > 0:
                        angle_diff -= 2 * math.pi
                    if angle_diff < -math.pi:
                        angle_diff += 2 * math.pi

                end_angle = start_angle + angle_diff

            else:
                # BÉZIER APPROXIMATION when tension != 0
                # Apex position along chord (1-179 → 0.0-1.0)
                t_pos = abs(arc_position) / 180.0

                # Perpendicular unit vector (screen coords: Y increases downward)
                perp_x = dy / chord_len * perp_sign
                perp_y = -dx / chord_len * perp_sign

                # Control point base position along chord
                ctrl_base_x = x1 + dx * t_pos
                ctrl_base_y = y1 + dy * t_pos

                # Control point offset (perpendicular distance)
                if arc_tension > 0:
                    # positive: L-corner (sharper)
                    offset = chord_len * (0.5 + 0.5 * arc_tension / 100.0)
                else:
                    # negative: flatten toward straight line
                    offset = chord_len * 0.5 * max(0, 1 + arc_tension / 100.0)

                ctrl_x = ctrl_base_x + perp_x * offset
                ctrl_y = ctrl_base_y + perp_y * offset

    # Smooth drag
    step_delay = duration / steps
    for i in range(1, steps + 1):
        t = i / steps
        eased_t = ease_func(t)

        if use_true_circle and center_x is not None:
            # TRUE CIRCULAR ARC: interpolate angle, trace circle
            angle = start_angle + (end_angle - start_angle) * eased_t
            x = center_x + radius * math.cos(angle)
            y = center_y + radius * math.sin(angle)
        elif ctrl_x is not None:
            # Quadratic Bézier: B(t) = (1-t)²P1 + 2(1-t)t·Ctrl + t²P2
            inv_t = 1 - eased_t
            x = inv_t*inv_t*x1 + 2*inv_t*eased_t*ctrl_x + eased_t*eased_t*x2
            y = inv_t*inv_t*y1 + 2*inv_t*eased_t*ctrl_y + eased_t*eased_t*y2
        else:
            # Linear interpolation
            x = x1 + (x2 - x1) * eased_t
            y = y1 + (y2 - y1) * eased_t

        drag_event = CGEventCreateMouseEvent(None, kCGEventLeftMouseDragged, (x, y), 0)
        CGEventPost(kCGHIDEventTap, drag_event)
        time.sleep(step_delay)

    if not skip_mouse_up:
        # Mouse up
        up_event = CGEventCreateMouseEvent(None, kCGEventLeftMouseUp, (x2, y2), 0)
        CGEventPost(kCGHIDEventTap, up_event)

if __name__ == '__main__':
    x1, y1 = float(sys.argv[1]), float(sys.argv[2])
    x2, y2 = float(sys.argv[3]), float(sys.argv[4])
    duration = float(sys.argv[5]) if len(sys.argv) > 5 else 1.6
    arc_position = int(sys.argv[6]) if len(sys.argv) > 6 else 0
    arc_tension = int(sys.argv[7]) if len(sys.argv) > 7 else 0
    skip_mouse_down = sys.argv[8] == "1" if len(sys.argv) > 8 else False
    skip_mouse_up = sys.argv[9] == "1" if len(sys.argv) > 9 else False
    easing = sys.argv[10] if len(sys.argv) > 10 else 'ease-in-out'
    steps = int(sys.argv[11]) if len(sys.argv) > 11 else 60
    smooth_drag(x1, y1, x2, y2, duration, steps, arc_position, arc_tension,
                skip_mouse_down, skip_mouse_up, easing)
PYEOF

    auto_read_page
}

# Batch drag - execute multiple drag segments in a single Python process
# Usage: drag_batch "x1,y1,x2,y2,arc_pos,arc_tension" "x1,y1,x2,y2,arc_pos,arc_tension" ...
# All coordinates should already be in absolute pixels
drag_batch() {
    local duration=${DRAG_DURATION:-1.6}
    local easing=${DRAG_EASING:-ease-in-out}
    local steps=${DRAG_STEPS:-60}

    # Build segments array as JSON-like format for Python
    local segments=""
    for seg in "$@"; do
        [[ -n "$segments" ]] && segments="$segments;"
        segments="$segments$seg"
    done

    "$PYTHON" - "$segments" "$duration" "$easing" "$steps" <<'PYEOF'
import sys
import time
import math
from Quartz import (
    CGEventCreateMouseEvent,
    CGEventPost,
    kCGEventLeftMouseDown,
    kCGEventLeftMouseUp,
    kCGEventLeftMouseDragged,
    kCGHIDEventTap,
    CGEventSetIntegerValueField,
    kCGMouseEventClickState
)

def ease_linear(t):
    return t

def ease_in(t):
    return t * t * t

def ease_out(t):
    return 1 - pow(1 - t, 3)

def ease_in_out(t):
    if t < 0.5:
        return 4 * t * t * t
    else:
        return 1 - pow(-2 * t + 2, 3) / 2

def drag_segment(x1, y1, x2, y2, arc_position, arc_tension, duration, steps, ease_func):
    """Execute a single drag segment (mouse already down, don't release)."""
    use_true_circle = (arc_position != 0 and arc_tension == 0)
    ctrl_x, ctrl_y = None, None
    center_x, center_y, radius, start_angle, end_angle = None, None, None, None, None

    if arc_position != 0:
        dx, dy = x2 - x1, y2 - y1
        chord_len = math.sqrt(dx*dx + dy*dy)

        if chord_len > 0:
            perp_sign = 1 if arc_position > 0 else -1

            if use_true_circle:
                arc_angle_deg = abs(arc_position)
                arc_angle = math.radians(arc_angle_deg)
                half_angle = arc_angle / 2
                radius = chord_len / (2 * math.sin(half_angle))
                mid_x = (x1 + x2) / 2
                mid_y = (y1 + y2) / 2
                perp_x = dy / chord_len * perp_sign
                perp_y = -dx / chord_len * perp_sign
                center_dist = radius * math.cos(half_angle)
                center_x = mid_x + perp_x * center_dist
                center_y = mid_y + perp_y * center_dist
                start_angle = math.atan2(y1 - center_y, x1 - center_x)
                end_angle = math.atan2(y2 - center_y, x2 - center_x)
                angle_diff = end_angle - start_angle
                if perp_sign > 0:
                    if angle_diff < 0:
                        angle_diff += 2 * math.pi
                    if angle_diff > math.pi:
                        angle_diff -= 2 * math.pi
                else:
                    if angle_diff > 0:
                        angle_diff -= 2 * math.pi
                    if angle_diff < -math.pi:
                        angle_diff += 2 * math.pi
                end_angle = start_angle + angle_diff
            else:
                t_pos = abs(arc_position) / 180.0
                perp_x = dy / chord_len * perp_sign
                perp_y = -dx / chord_len * perp_sign
                ctrl_base_x = x1 + dx * t_pos
                ctrl_base_y = y1 + dy * t_pos
                if arc_tension > 0:
                    offset = chord_len * (0.5 + 0.5 * arc_tension / 100.0)
                else:
                    offset = chord_len * 0.5 * max(0, 1 + arc_tension / 100.0)
                ctrl_x = ctrl_base_x + perp_x * offset
                ctrl_y = ctrl_base_y + perp_y * offset

    step_delay = duration / steps
    for i in range(1, steps + 1):
        t = i / steps
        eased_t = ease_func(t)

        if use_true_circle and center_x is not None:
            angle = start_angle + (end_angle - start_angle) * eased_t
            x = center_x + radius * math.cos(angle)
            y = center_y + radius * math.sin(angle)
        elif ctrl_x is not None:
            inv_t = 1 - eased_t
            x = inv_t*inv_t*x1 + 2*inv_t*eased_t*ctrl_x + eased_t*eased_t*x2
            y = inv_t*inv_t*y1 + 2*inv_t*eased_t*ctrl_y + eased_t*eased_t*y2
        else:
            x = x1 + (x2 - x1) * eased_t
            y = y1 + (y2 - y1) * eased_t

        drag_event = CGEventCreateMouseEvent(None, kCGEventLeftMouseDragged, (x, y), 0)
        CGEventPost(kCGHIDEventTap, drag_event)
        time.sleep(step_delay)

    return x2, y2

if __name__ == '__main__':
    segments_str = sys.argv[1]
    duration = float(sys.argv[2]) if len(sys.argv) > 2 else 1.6
    easing = sys.argv[3] if len(sys.argv) > 3 else 'ease-in-out'
    steps = int(sys.argv[4]) if len(sys.argv) > 4 else 60

    # Parse segments: "x1,y1,x2,y2,arc_pos,arc_tension;..."
    segments = []
    for seg_str in segments_str.split(';'):
        parts = seg_str.split(',')
        if len(parts) >= 4:
            x1, y1, x2, y2 = float(parts[0]), float(parts[1]), float(parts[2]), float(parts[3])
            arc_pos = int(parts[4]) if len(parts) > 4 else 0
            arc_ten = int(parts[5]) if len(parts) > 5 else 0
            segments.append((x1, y1, x2, y2, arc_pos, arc_ten))

    if not segments:
        sys.exit(1)

    num_segs = len(segments)

    # Mouse down at first segment start
    x1, y1 = segments[0][0], segments[0][1]
    move_event = CGEventCreateMouseEvent(None, kCGEventLeftMouseDragged, (x1, y1), 0)
    CGEventPost(kCGHIDEventTap, move_event)
    time.sleep(0.02)
    down_event = CGEventCreateMouseEvent(None, kCGEventLeftMouseDown, (x1, y1), 0)
    CGEventSetIntegerValueField(down_event, kCGMouseEventClickState, 1)
    CGEventPost(kCGHIDEventTap, down_event)
    time.sleep(0.02)

    # Execute each segment
    for idx, (x1, y1, x2, y2, arc_pos, arc_ten) in enumerate(segments):
        # Determine easing for this segment
        is_first = (idx == 0)
        is_last = (idx == num_segs - 1)

        if easing == 'linear':
            ease_func = ease_linear
        elif is_first and is_last:
            # Single segment: full easing
            ease_func = {'ease-in': ease_in, 'ease-out': ease_out, 'ease-in-out': ease_in_out}.get(easing, ease_in_out)
        elif is_first:
            ease_func = ease_in if easing in ('ease-in', 'ease-in-out') else ease_linear
        elif is_last:
            ease_func = ease_out if easing in ('ease-out', 'ease-in-out') else ease_linear
        else:
            ease_func = ease_linear

        # Each segment gets full duration (not divided)
        drag_segment(x1, y1, x2, y2, arc_pos, arc_ten, duration, steps, ease_func)

    # Mouse up at last segment end
    x2, y2 = segments[-1][2], segments[-1][3]
    up_event = CGEventCreateMouseEvent(None, kCGEventLeftMouseUp, (x2, y2), 0)
    CGEventPost(kCGHIDEventTap, up_event)
PYEOF
}

# Type text using Python/Quartz with inter-character delays
# Safe mode prevents macOS shortcut collisions (Dictation, Emoji picker, etc.)
# Usage: type_text "text" [delay_ms] [--fast]
type_text() {
    local text="$1"
    local delay_ms="${2:-30}"
    local fast_mode=""

    # Check for --fast flag
    if [[ "$2" == "--fast" || "$3" == "--fast" ]]; then
        fast_mode=1
        [[ "$2" == "--fast" ]] && delay_ms="30"
    fi

    echo "Typing: $text"

    # Fast mode: Use cliclick (legacy behavior) - may trigger shortcuts
    if [[ -n "$fast_mode" ]]; then
        cliclick "t:$text"
        return
    fi

    # Safe mode: Use Python/Quartz character-by-character with base64 encoding
    # Uses actual macOS key codes so pygame/SDL apps receive proper key events
    local encoded=$(printf '%s' "$text" | base64)

    "$PYTHON" << PYEOF
import Quartz
import time
import base64

text = base64.b64decode('$encoded').decode('utf-8')
delay_ms = $delay_ms

# macOS virtual key codes for common characters
# This allows pygame/SDL apps to receive proper key events (they check event.key, not unicode)
KEY_CODES = {
    # Letters
    'a': 0, 's': 1, 'd': 2, 'f': 3, 'h': 4, 'g': 5, 'z': 6, 'x': 7, 'c': 8, 'v': 9,
    'b': 11, 'q': 12, 'w': 13, 'e': 14, 'r': 15, 'y': 16, 't': 17, 'o': 31,
    'u': 32, 'i': 34, 'p': 35, 'l': 37, 'j': 38, 'k': 40, 'n': 45, 'm': 46,
    # Numbers and their shifted symbols
    '1': 18, '!': 18,
    '2': 19, '@': 19,
    '3': 20, '#': 20,
    '4': 21, '$': 21,
    '5': 23, '%': 23,
    '6': 22, '^': 22,
    '7': 26, '&': 26,
    '8': 28, '*': 28,
    '9': 25, '(': 25,
    '0': 29, ')': 29,
    # Punctuation and their shifted variants
    '-': 27, '_': 27,
    '=': 24, '+': 24,
    '[': 33, '{': 33,
    ']': 30, '}': 30,
    '\\\\': 42, '|': 42,
    ';': 41, ':': 41,
    "'": 39, '"': 39,
    ',': 43, '<': 43,
    '.': 47, '>': 47,
    '/': 44, '?': 44,
    '\`': 50, '~': 50,
    # Whitespace
    ' ': 49,
}
# Add uppercase letters (same key codes, will set shift flag if needed)
for c in 'abcdefghijklmnopqrstuvwxyz':
    KEY_CODES[c.upper()] = KEY_CODES[c]

for char in text:
    # Look up the key code, default to 0 for unknown characters
    key_code = KEY_CODES.get(char, 0)

    # Check if we need shift modifier (uppercase or shifted symbols)
    needs_shift = char.isupper() or char in '~!@#$%^&*()_+{}|:<>?"'

    # Create key events with proper key code
    event_down = Quartz.CGEventCreateKeyboardEvent(None, key_code, True)
    event_up = Quartz.CGEventCreateKeyboardEvent(None, key_code, False)

    # Set ONLY shift flag if needed, otherwise clear all flags
    if needs_shift:
        Quartz.CGEventSetFlags(event_down, Quartz.kCGEventFlagMaskShift)
        Quartz.CGEventSetFlags(event_up, Quartz.kCGEventFlagMaskShift)
    else:
        # Clear all modifier flags to prevent accidental Cmd+key, etc.
        Quartz.CGEventSetFlags(event_down, 0)
        Quartz.CGEventSetFlags(event_up, 0)

    # Also set unicode character (for apps that use text input system)
    Quartz.CGEventKeyboardSetUnicodeString(event_down, 1, char)
    Quartz.CGEventKeyboardSetUnicodeString(event_up, 1, char)

    # Post to session tap (more appropriate for app input than HID tap)
    Quartz.CGEventPost(Quartz.kCGSessionEventTap, event_down)
    time.sleep(0.01)  # 10ms between down/up
    Quartz.CGEventPost(Quartz.kCGSessionEventTap, event_up)

    # Inter-character delay
    time.sleep(delay_ms / 1000.0)
PYEOF
}

# Press key - use Python/Quartz for reliability
press_key() {
    local key="$1"
    echo "Pressing key: $key"

    # Map key names to macOS key codes
    local key_code
    case "$key" in
        esc|escape) key_code=53 ;;
        return|enter) key_code=36 ;;
        tab) key_code=48 ;;
        space) key_code=49 ;;
        delete|backspace) key_code=51 ;;
        fwd-delete) key_code=117 ;;
        home) key_code=115 ;;
        end) key_code=119 ;;
        page-up) key_code=116 ;;
        page-down) key_code=121 ;;
        arrow-up) key_code=126 ;;
        arrow-down) key_code=125 ;;
        arrow-left) key_code=123 ;;
        arrow-right) key_code=124 ;;
        f1) key_code=122 ;; f2) key_code=120 ;; f3) key_code=99 ;;
        f4) key_code=118 ;; f5) key_code=96 ;; f6) key_code=97 ;;
        f7) key_code=98 ;; f8) key_code=100 ;; f9) key_code=101 ;;
        f10) key_code=109 ;; f11) key_code=103 ;; f12) key_code=111 ;;
        *)
            # Fall back to cliclick for unknown keys
            cliclick "kp:$key"
            return
            ;;
    esac

    # Use Python/Quartz for reliable key sending
    "$PYTHON" << PYEOF
import Quartz
import time
key_code = $key_code

# Create events with NO modifier flags (clear any residual modifiers)
down = Quartz.CGEventCreateKeyboardEvent(None, key_code, True)
up = Quartz.CGEventCreateKeyboardEvent(None, key_code, False)

# Explicitly clear all modifier flags to prevent Cmd+Enter, etc.
Quartz.CGEventSetFlags(down, 0)
Quartz.CGEventSetFlags(up, 0)

# Post to session tap (more appropriate for app input than HID tap)
Quartz.CGEventPost(Quartz.kCGSessionEventTap, down)
time.sleep(0.02)
Quartz.CGEventPost(Quartz.kCGSessionEventTap, up)
PYEOF
}

# Get audio state (volume level and mute status)
get_audio_state() {
    local format="${1:-text}"
    local output_vol=$(osascript -e 'output volume of (get volume settings)' 2>/dev/null)
    local output_muted=$(osascript -e 'output muted of (get volume settings)' 2>/dev/null)
    local input_vol=$(osascript -e 'input volume of (get volume settings)' 2>/dev/null)

    if [[ "$format" == "json" ]]; then
        echo "{\"output_volume\": $output_vol, \"output_muted\": $output_muted, \"input_volume\": $input_vol}"
    else
        echo "Audio State:"
        echo "  Output Volume: ${output_vol}%"
        echo "  Muted: $output_muted"
        echo "  Input Volume: ${input_vol}%"
    fi
}

# Set system volume (0-100)
set_volume() {
    local level="$1"
    if [[ ! "$level" =~ ^[0-9]+$ ]] || [[ "$level" -lt 0 ]] || [[ "$level" -gt 100 ]]; then
        echo "ERROR: Volume must be 0-100"
        return 1
    fi
    osascript -e "set volume output volume $level"
    echo "Volume set to ${level}%"
}

# Get Now Playing media info from system (works with any app)
# Note: Firefox doesn't register with MediaRemote, so we also check power assertions
get_now_playing() {
    local format="${1:-text}"
    local nowplaying_bin="$LIB_DIR/nowplaying"

    # Build the binary if it doesn't exist
    if [[ ! -f "$nowplaying_bin" ]]; then
        cat > /tmp/nowplaying_build.swift << 'SWIFTEOF'
import Foundation
guard let bundle = CFBundleCreate(kCFAllocatorDefault, NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")) else { print("{}"); exit(0) }
guard let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString) else { print("{}"); exit(0) }
typealias F = @convention(c) (DispatchQueue, @escaping ([String: Any]?) -> Void) -> Void
let fn = unsafeBitCast(ptr, to: F.self)
let sem = DispatchSemaphore(value: 0)
var json = "{}"
fn(DispatchQueue.main) { info in
    if let info = info {
        var r: [String: Any] = ["playing": (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0) > 0]
        if let v = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String { r["title"] = v }
        if let v = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String { r["artist"] = v }
        if let v = info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String { r["album"] = v }
        if let v = info["kMRMediaRemoteNowPlayingInfoDuration"] as? Double { r["duration"] = v }
        if let v = info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double { r["elapsed"] = v }
        if let d = try? JSONSerialization.data(withJSONObject: r), let s = String(data: d, encoding: .utf8) { json = s }
    }
    sem.signal()
}
DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { sem.signal() }
_ = sem.wait(timeout: .now() + 1)
print(json)
SWIFTEOF
        swiftc -O -o "$nowplaying_bin" /tmp/nowplaying_build.swift 2>/dev/null
        rm -f /tmp/nowplaying_build.swift
    fi

    local result=$("$nowplaying_bin" 2>/dev/null || echo '{}')

    # Check if MediaRemote returned nothing - fall back to power assertions
    # This catches Firefox and other apps that don't register with MediaRemote
    if [[ "$result" == "{}" || "$result" == "" ]]; then
        local fallback_info=$("$PYTHON" << PYEOF
import subprocess
import re
import json

# Get Firefox tabs
try:
    tabs_result = subprocess.run(['$PYTHON', '$FIREFOX_TABS', '--json'],
                                  capture_output=True, text=True, timeout=5)
    all_tabs = json.loads(tabs_result.stdout) if tabs_result.returncode == 0 else []
except:
    all_tabs = []

# Check power assertions
result = subprocess.run(['pmset', '-g', 'assertions'], capture_output=True, text=True, errors='replace')
assertions = result.stdout

# Look for apps with video-playing assertion (more reliable) or audio-playing
video_match = re.search(r'pid (\d+)\(([^)]+)\).*?"video-playing"', assertions)
audio_match = re.search(r'pid (\d+)\(([^)]+)\).*?"audio-playing"', assertions)

if video_match or audio_match:
    match = video_match or audio_match
    pid, app = match.groups()[:2]
    media_type = "video" if video_match else "audio"

    # Find potential media tabs (YouTube, Spotify, SoundCloud, etc.)
    media_domains = ['youtube.com/watch', 'music.youtube.com', 'spotify.com', 'soundcloud.com',
                     'twitch.tv', 'netflix.com', 'vimeo.com', 'dailymotion.com', 'bandcamp.com']
    potential_tabs = []
    for tab in all_tabs:
        url = tab.get('url', '').lower()
        title = tab.get('title', '')
        for domain in media_domains:
            if domain in url:
                potential_tabs.append({
                    "index": tab['index'],
                    "title": title[:60],
                    "url": url[:80]
                })
                break

    output = {
        "playing": True,
        "app": app,
        "media_type": media_type,
        "source": "power_assertion",
        "note": f"{app} doesn't report to Now Playing API"
    }
    if potential_tabs:
        output["potential_tabs"] = potential_tabs

    print(json.dumps(output))
else:
    print("{}")
PYEOF
)
        if [[ "$fallback_info" != "{}" ]]; then
            result="$fallback_info"
        fi
    fi

    if [[ "$format" == "json" ]]; then
        echo "$result"
    else
        # Parse JSON and format as text
        local tmpfile=$(mktemp)
        echo "$result" > "$tmpfile"
        "$PYTHON" << PYEOF
import json
try:
    with open("$tmpfile") as f:
        info = json.load(f)
    if not info or (not info.get('title') and not info.get('playing')):
        print("Now Playing: Nothing")
    else:
        playing = "▶ Playing" if info.get('playing') else "⏸ Paused"
        print(f"Now Playing: {playing}")
        if info.get('title'):
            print(f"  Title: {info['title']}")
        if info.get('artist'):
            print(f"  Artist: {info['artist']}")
        if info.get('album'):
            print(f"  Album: {info['album']}")
        if info.get('app'):
            print(f"  App: {info['app']}")
        if info.get('duration'):
            elapsed = info.get('elapsed', 0)
            duration = info['duration']
            print(f"  Progress: {int(elapsed//60)}:{int(elapsed%60):02d} / {int(duration//60)}:{int(duration%60):02d}")
        if info.get('potential_tabs'):
            tabs = info['potential_tabs']
            print(f"  Potential sources ({len(tabs)} media tabs):")
            for i, tab in enumerate(tabs, 1):
                print(f"    {i}. #{tab['index']} \"{tab['title']}\"")
except Exception as e:
    print(f"Now Playing: Error - {e}")
PYEOF
        rm -f "$tmpfile"
    fi
}

# Get display brightness
get_brightness() {
    local format="${1:-text}"

    local result=$("$PYTHON" << 'PYEOF'
import subprocess
import re
import json

result = subprocess.run(['ioreg', '-l'], capture_output=True, text=True)

# Look for ApplePanelRawBrightness (built-in display)
brightness_match = re.search(r'"ApplePanelRawBrightness"\s*=\s*(\d+)', result.stdout)
range_match = re.search(r'"brightness"=\{"max"=(\d+),"min"=(\d+)\}', result.stdout)

if brightness_match:
    raw = int(brightness_match.group(1))
    if range_match:
        max_val = int(range_match.group(1))
        min_val = int(range_match.group(2))
        pct = round((raw - min_val) / (max_val - min_val) * 100)
        print(json.dumps({"brightness_percent": pct, "brightness_raw": raw, "min": min_val, "max": max_val}))
    else:
        print(json.dumps({"brightness_raw": raw}))
else:
    print(json.dumps({"brightness": None, "note": "No built-in display found (external monitors control their own brightness)"}))
PYEOF
)

    if [[ "$format" == "json" ]]; then
        echo "$result"
    else
        local pct=$(echo "$result" | "$PYTHON" -c "import json,sys; d=json.load(sys.stdin); print(d.get('brightness_percent', d.get('brightness_raw', 'N/A')))")
        if [[ "$pct" == "None" || "$pct" == "N/A" ]]; then
            echo "Brightness: N/A (external monitor)"
        else
            echo "Brightness: ${pct}%"
        fi
    fi
}

# ============================================================================
# CLIPBOARD OPERATIONS
# ============================================================================

# Read clipboard content and output in LLM-friendly format
read_clipboard() {
    local cb_type=$("$PYTHON" "$CLIPBOARD_PY" --type 2>/dev/null)

    case "$cb_type" in
        text)
            local content=$(pbpaste 2>/dev/null)
            local size=${#content}
            echo "@clipboard type:text size:$size"
            echo "$content"
            echo "---"
            ;;
        image)
            local output_file="/tmp/clipboard_$(date +%Y%m%d_%H%M%S).png"
            "$PYTHON" "$CLIPBOARD_PY" --read-image "$output_file" >/dev/null 2>&1
            if [[ -f "$output_file" ]]; then
                local size=$(stat -f%z "$output_file" 2>/dev/null || echo 0)
                echo "@clipboard type:image size:$size saved:$output_file"
                echo "[Image saved to $output_file]"
                echo "---"
            else
                echo "@clipboard type:image"
                echo "ERROR: Could not extract image from clipboard"
                echo "---"
                return 1
            fi
            ;;
        files)
            local files=$("$PYTHON" "$CLIPBOARD_PY" --read-files 2>/dev/null)
            local count=$(echo "$files" | grep -c . 2>/dev/null || echo 0)
            echo "@clipboard type:files count:$count"
            echo "$files"
            echo "---"
            ;;
        *)
            echo "@clipboard type:empty"
            echo "---"
            ;;
    esac
}

# Get clipboard type only
get_clipboard_type() {
    "$PYTHON" "$CLIPBOARD_PY" --type 2>/dev/null || echo "empty"
}

# Copy text to clipboard
copy_text_to_clipboard() {
    local text="$1"
    if [[ -z "$text" ]]; then
        echo "ERROR: No text provided" >&2
        return 1
    fi
    printf '%s' "$text" | pbcopy 2>/dev/null
    local size=${#text}
    echo "Copied text to clipboard ($size bytes)"
}

# Copy image to clipboard
copy_image_to_clipboard() {
    local path="$1"
    if [[ -z "$path" ]]; then
        echo "ERROR: No path provided" >&2
        return 1
    fi
    if [[ ! -f "$path" ]]; then
        echo "ERROR: File not found: $path" >&2
        return 1
    fi
    local result=$("$PYTHON" "$CLIPBOARD_PY" --copy-image "$path" 2>&1)
    if [[ "$result" == "OK" ]]; then
        echo "Copied image to clipboard: $path"
    else
        echo "ERROR: Failed to copy image: $result" >&2
        return 1
    fi
}

# Copy file to clipboard (for Finder paste)
copy_file_to_clipboard() {
    local path="$1"
    if [[ -z "$path" ]]; then
        echo "ERROR: No path provided" >&2
        return 1
    fi
    if [[ ! -f "$path" && ! -d "$path" ]]; then
        echo "ERROR: Path not found: $path" >&2
        return 1
    fi
    local result=$("$PYTHON" "$CLIPBOARD_PY" --copy-file "$path" 2>&1)
    if [[ "$result" == "OK" ]]; then
        echo "Copied file to clipboard: $path"
    else
        echo "ERROR: Failed to copy file: $result" >&2
        return 1
    fi
}

# ============================================================================

# Capture a screenshot hash for comparison (used by wait_for_change)
# Returns a hash of the screenshot or region
capture_screen_hash() {
    local region="$1"  # Optional: x,y,w,h
    local tmpfile=$(mktemp).jpg

    if [[ -n "$region" ]]; then
        IFS=',' read -r x y w h <<< "$region"
        screencapture -x -R "${x},${y},${w},${h}" "$tmpfile" 2>/dev/null
    else
        screencapture -x "$tmpfile" 2>/dev/null
    fi

    if [[ -f "$tmpfile" ]]; then
        # Use md5 hash of the image
        local hash=$(md5 -q "$tmpfile" 2>/dev/null)
        rm -f "$tmpfile"
        echo "$hash"
    fi
}

# Wait for text to appear or disappear from screen
# Usage: wait_for_text "pattern" appear|gone [timeout_ms] [app]
wait_for_text() {
    local pattern="$1"
    local condition="${2:-appear}"  # appear or gone
    local timeout="${3:-5000}"
    local app="$4"  # Optional: restrict to app window

    local interval=500  # Check every 500ms
    local elapsed=0
    local temp_screenshot="/tmp/wait_for_text_$$.jpg"

    echo "Waiting for text '$pattern' to $condition (timeout: ${timeout}ms)..."

    while [[ $elapsed -lt $timeout ]]; do
        # Take screenshot
        if [[ -n "$app" ]]; then
            "$SCREENSHOT" --in-app "$app" --output "$temp_screenshot" --full-res > /dev/null 2>&1
        else
            "$SCREENSHOT" --output "$temp_screenshot" --full-res > /dev/null 2>&1
        fi

        # Run OCR to find text
        local found=""
        if [[ -f "$temp_screenshot" ]]; then
            found=$("$PYTHON" "$OCR_FIND" --find "$pattern" --json "$temp_screenshot" 2>/dev/null)
        fi

        local count=$(echo "$found" | "$PYTHON" -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

        if [[ "$condition" == "appear" && "$count" -gt 0 ]]; then
            rm -f "$temp_screenshot"
            echo "Text '$pattern' appeared after ${elapsed}ms"
            return 0
        elif [[ "$condition" == "gone" && "$count" -eq 0 ]]; then
            rm -f "$temp_screenshot"
            echo "Text '$pattern' gone after ${elapsed}ms"
            return 0
        fi

        sleep $(echo "scale=3; $interval/1000" | bc)
        elapsed=$((elapsed + interval))
    done

    rm -f "$temp_screenshot"
    echo "Timeout: text '$pattern' did not $condition after ${timeout}ms"
    return 1
}

# Wait for a screen region to change
# Usage: wait_for_change [x,y,w,h] [timeout_ms]
# If no region specified, monitors full screen
wait_for_change() {
    local region="$1"
    local timeout="${2:-5000}"

    local interval=300  # Check every 300ms
    local elapsed=0

    echo "Waiting for screen change (timeout: ${timeout}ms)..."

    # Capture initial state
    local initial_hash=$(capture_screen_hash "$region")

    if [[ -z "$initial_hash" ]]; then
        echo "ERROR: Could not capture initial screen state"
        return 1
    fi

    while [[ $elapsed -lt $timeout ]]; do
        sleep $(echo "scale=3; $interval/1000" | bc)
        elapsed=$((elapsed + interval))

        local current_hash=$(capture_screen_hash "$region")

        if [[ "$current_hash" != "$initial_hash" ]]; then
            echo "Screen changed after ${elapsed}ms"
            return 0
        fi
    done

    echo "Timeout: screen did not change after ${timeout}ms"
    return 1
}

# Verify text is present/gone after an action
# Usage: verify_text "pattern" present|gone [app]
verify_text() {
    local pattern="$1"
    local condition="${2:-present}"
    local app="$3"

    local temp_screenshot="/tmp/verify_text_$$.jpg"

    # Take screenshot (full-res for OCR accuracy)
    if [[ -n "$app" ]]; then
        "$SCREENSHOT" --in-app "$app" --output "$temp_screenshot" --full-res > /dev/null 2>&1
    else
        "$SCREENSHOT" --output "$temp_screenshot" --full-res > /dev/null 2>&1
    fi

    local found=""
    if [[ -f "$temp_screenshot" ]]; then
        found=$("$PYTHON" "$OCR_FIND" --find "$pattern" --json "$temp_screenshot" 2>/dev/null)
        rm -f "$temp_screenshot"
    fi

    local count=$(echo "$found" | "$PYTHON" -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

    if [[ "$condition" == "present" ]]; then
        if [[ "$count" -gt 0 ]]; then
            echo "Verified: text '$pattern' is present"
            return 0
        else
            echo "Verification failed: text '$pattern' not found"
            return 1
        fi
    else  # gone
        if [[ "$count" -eq 0 ]]; then
            echo "Verified: text '$pattern' is gone"
            return 0
        else
            echo "Verification failed: text '$pattern' still present"
            return 1
        fi
    fi
}

# Press media key (play/pause, volume, brightness, etc.)
# Uses NSSystemDefined events which are different from regular keyboard events
press_media_key() {
    local key="$1"
    echo "Pressing media key: $key"

    # Map media key names to NX_KEYTYPE constants
    local key_type
    case "$key" in
        play-pause|play|pause) key_type=16 ;;  # NX_KEYTYPE_PLAY
        next-track|next) key_type=17 ;;         # NX_KEYTYPE_NEXT
        prev-track|previous) key_type=18 ;;     # NX_KEYTYPE_PREVIOUS
        fast-forward) key_type=19 ;;            # NX_KEYTYPE_FAST
        rewind) key_type=20 ;;                  # NX_KEYTYPE_REWIND
        volume-up) key_type=0 ;;                # NX_KEYTYPE_SOUND_UP
        volume-down) key_type=1 ;;              # NX_KEYTYPE_SOUND_DOWN
        mute) key_type=7 ;;                     # NX_KEYTYPE_MUTE
        brightness-up) key_type=2 ;;            # NX_KEYTYPE_BRIGHTNESS_UP
        brightness-down) key_type=3 ;;          # NX_KEYTYPE_BRIGHTNESS_DOWN
        keyboard-light-up) key_type=21 ;;       # NX_KEYTYPE_ILLUMINATION_UP
        keyboard-light-down) key_type=22 ;;     # NX_KEYTYPE_ILLUMINATION_DOWN
        eject) key_type=14 ;;                   # NX_KEYTYPE_EJECT
        *)
            echo "ERROR: Unknown media key: $key"
            echo "Valid keys: play-pause, next-track, prev-track, volume-up, volume-down, mute,"
            echo "            brightness-up, brightness-down, keyboard-light-up, keyboard-light-down"
            return 1
            ;;
    esac

    # Use Python to send NSSystemDefined event for media keys
    "$PYTHON" << PYEOF
import Quartz
import time

key_type = $key_type

# Media keys use NSSystemDefined events (type 14)
# The data field encodes the key type and key state
# Format: (key_type << 16) | (key_state << 8) | repeat_flag
# key_state: 0x0A = key down, 0x0B = key up

def send_media_key(key_type, key_down):
    flags = 0xa00 if key_down else 0xb00
    data = (key_type << 16) | flags

    event = Quartz.NSEvent.otherEventWithType_location_modifierFlags_timestamp_windowNumber_context_subtype_data1_data2_(
        14,  # NSSystemDefined
        (0, 0),
        0,  # modifierFlags
        0,  # timestamp
        0,  # windowNumber
        None,  # context
        8,  # subtype (NX_SUBTYPE_AUX_CONTROL_BUTTONS)
        data,
        -1
    )

    cg_event = event.CGEvent()
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, cg_event)

# Send key down, brief pause, then key up
send_media_key(key_type, True)
time.sleep(0.05)
send_media_key(key_type, False)
PYEOF
}

# Key combination
key_combo() {
    local combo="$1"

    # Parse combo like cmd+t, cmd+shift+s
    local keys=""
    local main_key=""

    IFS='+' read -ra parts <<< "$combo"

    for part in "${parts[@]}"; do
        case "$part" in
            cmd|command) keys="${keys}cmd," ;;
            ctrl|control) keys="${keys}ctrl," ;;
            alt|option) keys="${keys}alt," ;;
            shift) keys="${keys}shift," ;;
            fn) keys="${keys}fn," ;;
            *) main_key="$part" ;;
        esac
    done

    # Remove trailing comma
    keys="${keys%,}"

    echo "Pressing combo: $combo"

    # Check if main_key is a special key or a regular character
    # cliclick kp: only accepts special keys (return, tab, esc, etc.)
    # For regular letters/characters, use t: (type)
    local special_keys="arrow-down arrow-left arrow-right arrow-up delete end enter esc return space tab"
    special_keys="$special_keys f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12 f13 f14 f15 f16"
    special_keys="$special_keys home page-down page-up fwd-delete mute volume-up volume-down"

    if [[ " $special_keys " == *" $main_key "* ]]; then
        # Special key - use kp:
        cliclick "kd:$keys" "kp:$main_key" "ku:$keys"
    else
        # Regular character - use t: (type)
        cliclick "kd:$keys" "t:$main_key" "ku:$keys"
    fi
}

# Open/launch app (more reliable than activate for apps that aren't running)
open_app() {
    local app="$1"
    echo "Opening: $app"
    open -a "$app"
}

# Activate app (brings to front, also launches if not running)
# Uses timeout to prevent hanging when app has modal dialogs/dropdowns open
activate_app() {
    local app="$1"
    echo "Activating: $app"
    # Timeout after 1 second - osascript can hang if app has dropdown/modal open
    # Keep timeout short since activate_app may be called multiple times in a flow
    run_with_timeout 1 osascript -e "tell application \"$app\" to activate" >/dev/null 2>&1
    # Don't fail if activation times out - continue anyway
    return 0
}

# Hide app
hide_app() {
    local app="$1"
    echo "Hiding: $app"
    osascript -e "tell application \"System Events\" to set visible of process \"$app\" to false"
}

# Quit app
quit_app() {
    local app="$1"
    echo "Quitting: $app"
    osascript -e "tell application \"$app\" to quit"
}

# Browse to URL or path - finds existing tab/window or opens new one
# Usage: browse_url <url_or_path> [app]
# For browsers: finds tab with matching domain
# For Finder: finds window with exact matching path
browse_url() {
    local target="$1"
    local app="${2:-$IN_APP}"

    # Check if target is a file path (starts with /, ~, or .)
    if [[ "$target" =~ ^[/~.] ]]; then
        # Expand ~ and resolve to absolute path
        local abs_path
        abs_path=$(cd "$(dirname "$target")" 2>/dev/null && pwd)/$(basename "$target")
        [[ "$target" == ~* ]] && abs_path="${target/#\~/$HOME}"

        echo "Browse: Looking for Finder window at '$abs_path'"

        # Search Finder windows for exact path match
        local found_window
        found_window=$(osascript -e "
            tell application \"Finder\"
                set windowCount to count of windows
                repeat with i from 1 to windowCount
                    try
                        set w to window i
                        set winPath to POSIX path of (target of w as alias)
                        -- Remove trailing slash for comparison
                        if winPath ends with \"/\" then
                            set winPath to text 1 thru -2 of winPath
                        end if
                        set comparePath to \"$abs_path\"
                        if comparePath ends with \"/\" then
                            set comparePath to text 1 thru -2 of comparePath
                        end if
                        if winPath is equal to comparePath then
                            set index of w to 1
                            return \"found\"
                        end if
                    end try
                end repeat
                return \"\"
            end tell
        " 2>/dev/null)

        if [[ "$found_window" == "found" ]]; then
            echo "Browse: Found existing Finder window, bringing to front"
            activate_app "Finder"
            return 0
        else
            echo "Browse: No existing window, opening new Finder window"
            open "$abs_path"
            return 0
        fi
    fi

    # URL handling for browsers
    local browser="${app:-}"

    # Extract domain from URL (handles both "domain.com" and "https://domain.com/path")
    local domain
    domain=$(echo "$target" | sed -E 's|^https?://||; s|^www\.||; s|/.*$||')

    # If no browser specified, detect frontmost browser app
    if [[ -z "$browser" ]]; then
        browser=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null)
    fi

    echo "Browse: Looking for '$domain' in $browser"

    local tab_index=""
    local found_tab=false

    # Firefox: Use session file (AppleScript doesn't expose tab URLs)
    if [[ "$browser" == "Firefox" ]]; then
        tab_index=$("$PYTHON" "$SCRIPT_DIR/../lib/firefox_tabs.py" --search "$domain" --index-only 2>/dev/null)

        if [[ -n "$tab_index" ]]; then
            echo "Browse: Found existing tab at index $tab_index"
            activate_app "$browser"
            sleep 0.2

            if [[ "$tab_index" -le 8 ]]; then
                key_combo "cmd+$tab_index"
            else
                # Tab > 8 - cycle from tab 1
                key_combo "cmd+1"
                for ((i=1; i<tab_index; i++)); do
                    key_combo "ctrl+tab"
                    sleep 0.05
                done
            fi
            return 0
        fi
        found_tab=true  # Firefox supported, no matching tab found
    fi

    # Try Chrome-style AppleScript (works for Chrome, Brave, Edge, Arc, etc.)
    if [[ "$found_tab" == false ]]; then
        local chrome_result
        chrome_result=$(osascript -e "
            tell application \"$browser\"
                repeat with w in windows
                    set tabNum to 0
                    repeat with t in tabs of w
                        set tabNum to tabNum + 1
                        if URL of t contains \"$domain\" then
                            set active tab index of w to tabNum
                            set index of w to 1
                            return \"found\"
                        end if
                    end repeat
                end repeat
                return \"none\"
            end tell
        " 2>&1)

        if [[ "$chrome_result" == "found" ]]; then
            echo "Browse: Found and switched to existing tab"
            activate_app "$browser"
            return 0
        elif [[ "$chrome_result" == "none" ]]; then
            found_tab=true  # App supports browse, no matching tab
        fi
    fi

    # Try Safari-style AppleScript (uses 'current tab' instead of 'active tab index')
    if [[ "$found_tab" == false ]]; then
        local safari_result
        safari_result=$(osascript -e "
            tell application \"$browser\"
                repeat with w in windows
                    repeat with t in tabs of w
                        if URL of t contains \"$domain\" then
                            set current tab of w to t
                            set index of w to 1
                            return \"found\"
                        end if
                    end repeat
                end repeat
                return \"none\"
            end tell
        " 2>&1)

        if [[ "$safari_result" == "found" ]]; then
            echo "Browse: Found and switched to existing tab"
            activate_app "$browser"
            return 0
        elif [[ "$safari_result" == "none" ]]; then
            found_tab=true  # App supports browse, no matching tab
        fi
    fi

    # If no AppleScript approach worked, app doesn't support browse
    if [[ "$found_tab" == false ]]; then
        echo "ERROR: browse not supported for '$browser'" >&2
        return 1
    fi

    # No existing tab found - open new tab and navigate
    echo "Browse: No existing tab found, opening new tab"
    activate_app "$browser"
    sleep 0.2
    key_combo "cmd+t"
    sleep 0.2

    # Ensure URL has protocol
    if [[ ! "$target" =~ ^https?:// ]]; then
        target="https://$target"
    fi

    # Paste URL (preserving user's clipboard)
    local saved_clipboard=$(pbpaste 2>/dev/null)
    printf '%s' "$target" | pbcopy 2>/dev/null
    sleep 0.05
    cliclick "kd:cmd" "t:v" "ku:cmd"
    sleep 0.1
    printf '%s' "$saved_clipboard" | pbcopy 2>/dev/null

    press_key "return"

    return 0
}

# Wait for a new window to appear and return the app info
# Usage: wait_for_new_window [timeout_seconds]
# Returns: Sets IN_APP to detected app and outputs app info
wait_for_new_window() {
    local timeout="${1:-10}"
    local poll_interval=0.3

    # Get current window IDs
    local before_ids=$("$PYTHON" "$WINDOW_LIST" --json 2>/dev/null | "$PYTHON" -c '
import json, sys
data = json.load(sys.stdin)
print(" ".join(str(w["window_id"]) for w in data))
' 2>/dev/null)

    echo "Waiting for new window (timeout: ${timeout}s)..." >&2

    local elapsed=0
    while (( $(echo "$elapsed < $timeout" | bc -l) )); do
        sleep $poll_interval
        elapsed=$(echo "$elapsed + $poll_interval" | bc -l)

        # Get current windows and find new ones
        local result
        result=$("$PYTHON" "$WINDOW_LIST" --json 2>/dev/null | "$PYTHON" -c '
import json, sys

before_ids_str = sys.argv[1] if len(sys.argv) > 1 else ""
before_ids = set(before_ids_str.split())
data = json.load(sys.stdin)

for w in data:
    if str(w["window_id"]) not in before_ids:
        # Found new window - output tab-separated for easy parsing
        print("APP=" + w["app"])
        print("WINDOW_ID=" + str(w["window_id"]))
        print("TITLE=" + w["title"])
        sys.exit(0)
sys.exit(1)
' "$before_ids" 2>/dev/null)
        local exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            # Parse result
            local new_app=$(echo "$result" | grep "^APP=" | cut -d= -f2)
            local window_id=$(echo "$result" | grep "^WINDOW_ID=" | cut -d= -f2)
            local title=$(echo "$result" | grep "^TITLE=" | cut -d= -f2-)

            echo "Detected new window: $new_app (window $window_id)" >&2
            echo "Title: $title" >&2

            # Auto-set IN_APP
            set_target_app "$new_app"
            echo "Auto-set IN_APP=$new_app" >&2

            # Output for scripting
            echo "$new_app"
            return 0
        fi
    done

    echo "Timeout: No new window detected" >&2
    return 1
}

# Show screen size
show_screen_size() {
    echo "Display: ${DISPLAY_NUM:-main}"
    echo "Size: ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}"
    echo "Offset: (${DISPLAY_X_OFFSET}, ${DISPLAY_Y_OFFSET})"
}

# List all displays
list_displays() {
    echo "Available displays:"
    get_display_info | while read num w h x y main; do
        local main_str=""
        [[ "$main" == "1" ]] && main_str=" [MAIN]"
        echo "  Display $num: ${w}x${h} at ($x,$y)$main_str"
    done
}

# ============================================================================
# WINDOW QUERY FUNCTIONS
# ============================================================================

# List all visible windows
list_windows() {
    "$PYTHON" "$WINDOW_LIST" "$@"
}

# Find where an app's window is located
where_app() {
    local app="$1"
    "$PYTHON" "$WINDOW_LIST" --app "$app" --where
}

# Get app window bounds (for OCR filtering)
get_app_bounds() {
    local app="$1"
    "$PYTHON" "$WINDOW_LIST" --app "$app" --bounds
}

# Force cursor to be visible (macOS hides it during text input)
show_cursor() {
    "$PYTHON" << 'PYEOF'
import Quartz
# Show cursor on all displays
Quartz.CGDisplayShowCursor(Quartz.CGMainDisplayID())
PYEOF
    echo "Cursor visibility restored"
}

# Show mouse position
show_mouse_pos() {
    local pos=$(cliclick p)
    echo "Mouse position (absolute): $pos"

    local pixel_x=$(echo "$pos" | cut -d',' -f1)
    local pixel_y=$(echo "$pos" | cut -d',' -f2)

    # Show grid percentage relative to current display
    local rel_x=$(echo "$pixel_x - $DISPLAY_X_OFFSET" | bc)
    local rel_y=$(echo "$pixel_y - $DISPLAY_Y_OFFSET" | bc)
    local grid_x=$(echo "scale=1; $rel_x * 100 / $DISPLAY_WIDTH" | bc)
    local grid_y=$(echo "scale=1; $rel_y * 100 / $DISPLAY_HEIGHT" | bc)
    echo "Grid on display ${DISPLAY_NUM:-1}: ${grid_x}%, ${grid_y}%"
}

# Wait
wait_ms() {
    local ms="$1"
    local seconds=$(echo "scale=3; $ms / 1000" | bc)
    sleep "$seconds"
}

# ============================================================================
# OCR-BASED TEXT OPERATIONS
# ============================================================================

# Find text on screen using OCR
# Returns: grid coordinates or error
# If IN_APP is set, filters results to only text within that app's window
find_text_on_screen() {
    local search_text="$1"
    local instance="${2:-1}"
    local display="${3:-$DISPLAY_NUM}"
    local in_app="${4:-$IN_APP}"
    local near_text="${5:-$NEAR_TEXT}"  # Proximity anchor text

    # Restore target app if not already set (auto-reactivates the app)
    restore_target_app
    in_app="${in_app:-$IN_APP}"  # Update in case restore_target_app set it

    # Activate the app to ensure it's visible for the screenshot
    if [[ -n "$in_app" ]]; then
        activate_app "$in_app" > /dev/null 2>&1
        sleep 0.3
    fi

    # Build find_text.py command
    local find_args=("$search_text")
    [[ -n "$in_app" ]] && find_args+=(--in-app "$in_app")
    [[ -n "$near_text" ]] && find_args+=(--near "$near_text")
    # Only pass --instance if user explicitly requested it (INSTANCE_EXPLICIT=1)
    # Otherwise let find_text.py detect multiple matches and warn
    [[ "$INSTANCE_EXPLICIT" == "1" && -n "$instance" && -z "$near_text" ]] && find_args+=(--instance "$instance")
    [[ -n "$display" ]] && find_args+=(--display "$display")

    # Run find_text.py with timeout
    local result
    result=$(run_with_timeout "$OCR_TIMEOUT" "$PYTHON" "$LIB_DIR/find_text.py" "${find_args[@]}" 2>&1)
    local status=$?

    if [[ $status -eq 124 ]]; then
        echo "ERROR: OCR timed out after ${OCR_TIMEOUT}s"
        return 1
    fi

    if [[ $status -ne 0 ]]; then
        # Pass through error message from find_text.py
        echo "$result"
        return 1
    fi

    echo "$result"
    return 0
}

# Click on text found via OCR
click_text() {
    local search_text="$1"
    local click_type="${2:-c}"
    local instance="${3:-1}"
    local activate_app="${4:-$ACTIVATE_APP}"
    local in_app="${5:-$IN_APP}"

    echo "Finding text: '$search_text'..."

    # Run find_text_on_screen with timeout to prevent hanging
    # Uses OCR_TIMEOUT (default 10s) to allow for app activation + screenshot + OCR
    local find_timeout="$OCR_TIMEOUT"
    local coords_file="/tmp/find_text_coords_$$.txt"

    # Run in background with timeout
    # Only capture stdout (coords), let stderr go to parent for logging
    # Pass NEAR_TEXT as 5th arg for proximity-based search
    # INSTANCE_EXPLICIT is only set when user explicitly provides --instance (see pre-scan in main)
    ( find_text_on_screen "$search_text" "$instance" "$DISPLAY_NUM" "$in_app" "$NEAR_TEXT" > "$coords_file" ) &
    local find_pid=$!

    # Wait with timeout (use 0.2s granularity for more responsive timeout)
    local waited=0
    while kill -0 $find_pid 2>/dev/null && [[ $waited -lt $((find_timeout * 5)) ]]; do
        sleep 0.2
        waited=$((waited + 1))
    done

    # Check if still running (timed out)
    if kill -0 $find_pid 2>/dev/null; then
        # Kill the process and all its children
        pkill -P $find_pid 2>/dev/null
        kill $find_pid 2>/dev/null
        wait $find_pid 2>/dev/null
        rm -f "$coords_file"
        echo "ERROR: Text search timed out after ${find_timeout}s"
        return 1
    fi

    wait $find_pid
    local find_status=$?
    local coords=$(cat "$coords_file" 2>/dev/null)
    rm -f "$coords_file"

    if [[ $find_status -ne 0 || -z "$coords" || "$coords" == *"NOT_FOUND"* || "$coords" == *"ERROR"* || "$coords" == *"MULTIPLE_MATCHES"* ]]; then
        # Show appropriate error based on response type
        if [[ "$coords" == *"MULTIPLE_MATCHES"* ]]; then
            echo "$coords"
        elif [[ "$coords" == *"NOT_FOUND"* ]]; then
            echo "$coords"
        else
            echo "ERROR: Text not found: '$search_text'"
            [[ -n "$coords" ]] && echo "$coords"
        fi
        return 1
    fi

    echo "Found at grid: $coords"

    # Activate app if specified (important: do this AFTER OCR but BEFORE click)
    if [[ -n "$activate_app" ]]; then
        echo "Activating: $activate_app"
        activate_app "$activate_app"
        sleep 0.2  # Brief pause to ensure activation
    fi

    # Click at the found coordinates
    click_grid "$coords" "$click_type"
}

# Click UI element by type near a text label using accessibility API
# Usage: click_element <label> <element_type>
click_element() {
    local label="$1"
    local element_type="$2"
    local app="${IN_APP:-}"

    if [[ -z "$app" ]]; then
        echo "ERROR: --in-app must be set to use click-$element_type" >&2
        return 1
    fi

    echo "Finding $element_type near '$label' in $app..."

    # Use ui_elements.py to find the element
    local result
    result=$("$PYTHON" "$UI_ELEMENTS" --app "$app" --near "$label" --type "$element_type" 2>&1)

    if [[ $? -ne 0 ]] || echo "$result" | grep -q "NOT_FOUND"; then
        echo "ERROR: No $element_type found near '$label'" >&2
        return 1
    fi

    # Extract pixel coordinates from result
    local pixel_coords
    pixel_coords=$(echo "$result" | grep "^PIXEL:" | sed 's/PIXEL: //')

    if [[ -z "$pixel_coords" ]]; then
        echo "ERROR: Could not determine element position" >&2
        return 1
    fi

    local pixel_x pixel_y
    IFS=',' read -r pixel_x pixel_y <<< "$pixel_coords"

    echo "Found $element_type at pixel ($pixel_x,$pixel_y)"

    # Activate the app first
    restore_target_app

    # Click at pixel coordinates
    cliclick "c:$pixel_x,$pixel_y"

    # Show value if available
    local value
    value=$(echo "$result" | grep "^VALUE:" | sed 's/VALUE: //')
    if [[ -n "$value" ]]; then
        echo "Current value: $value"
    fi

    # Auto-read page after click when IN_APP is set
    auto_read_page
}

# Click toggle/switch near text label
click_toggle() {
    click_element "$1" "toggle"
}

# Click info (i) button near text label
click_info() {
    click_element "$1" "info"
}

# Unified click function - single entry point for all click operations
# Uses global CLICK_* flags to determine click type and mode
# Target auto-detection: text (has non-numeric chars), grid (x,y), pixel (px:x,y)
unified_click() {
    local target="$1"
    local click_type="c"

    # Determine click type from modifier flags
    [[ -n "$CLICK_DOUBLE" ]] && click_type="dc"
    [[ -n "$CLICK_RIGHT" ]] && click_type="rc"
    [[ -n "$CLICK_TRIPLE" ]] && click_type="tc"

    # Handle modes based on flags and target
    if [[ -n "$CLICK_TOGGLE" ]]; then
        # A11y toggle mode
        if [[ -z "$target" ]]; then
            echo "ERROR: --toggle requires a label argument" >&2
            return 1
        fi
        click_toggle "$target"
    elif [[ -n "$CLICK_INFO" ]]; then
        # A11y info button mode
        if [[ -z "$target" ]]; then
            echo "ERROR: --info requires a label argument" >&2
            return 1
        fi
        click_info "$target"
    elif [[ -z "$target" ]]; then
        # No target = click at cursor
        click_here "$click_type"
    elif [[ "$target" == px:* ]]; then
        # Pixel prefix: px:1200,500
        click_pixel "${target#px:}" "$click_type"
    elif [[ "$target" =~ ^[0-9.-]+,[0-9.-]+(,[0-9.]+,[0-9.]+)?$ ]]; then
        # Grid % coordinate target (x,y or x,y,w,h)
        click_grid "$target" "$click_type"
    else
        # Text target (OCR)
        click_text "$target" "$click_type" "${INSTANCE:-1}" "${ACTIVATE_APP:-}"
    fi

    # Reset flags after use
    CLICK_DOUBLE="" CLICK_RIGHT="" CLICK_TRIPLE=""
    CLICK_TOGGLE="" CLICK_INFO=""
}

# List UI elements in current app
# Usage: list_elements [type]
list_elements() {
    local element_type="$1"
    local app="${IN_APP:-}"

    if [[ -z "$app" ]]; then
        echo "ERROR: --in-app must be set to use --list-elements" >&2
        return 1
    fi

    if [[ -n "$element_type" ]]; then
        "$PYTHON" "$UI_ELEMENTS" --app "$app" --list --relative --type "$element_type"
    else
        "$PYTHON" "$UI_ELEMENTS" --app "$app" --list --relative
    fi
}

# Read page - extract all visible text in LLM-friendly format
# Usage: read_page <app> [--classify] [--json] [--save-screenshot <path>] [--region x1,y1,x2,y2]
read_page() {
    local app="$1"
    local classify="$2"
    local json_output="$3"
    local save_screenshot="$4"
    local region="$5"
    local aspect="$6"

    if [[ -z "$app" ]]; then
        echo "ERROR: read_page requires an app name" >&2
        return 1
    fi

    # Standard OCR screenshot locations (persists for potential Read after OCR)
    local OCR_SCREENSHOT="/tmp/claude/ocr_screenshot.png"
    local OCR_SCREENSHOT_API="/tmp/claude/ocr_screenshot_api.jpg"
    mkdir -p /tmp/claude 2>/dev/null

    # Clean up previous OCR screenshots (at start of new run, not end)
    rm -f "$OCR_SCREENSHOT" "$OCR_SCREENSHOT_API"

    # Get app window info
    local where_output=$("$PYTHON" "$WINDOW_LIST" --app "$app" --where 2>&1)
    if echo "$where_output" | grep -q "No window found"; then
        echo "ERROR: No window found for app: $app" >&2
        return 1
    fi

    local display=$(echo "$where_output" | grep "^DISPLAY:" | sed 's/DISPLAY: //' | awk '{print $1}')
    local bounds=$(echo "$where_output" | grep "^BOUNDS:" | sed 's/BOUNDS: //')
    IFS=',' read -r win_x win_y win_w win_h <<< "$bounds"

    # Activate and screenshot the app
    activate_app "$app" > /dev/null 2>&1
    sleep 0.3

    local temp_screenshot="/tmp/read_page_$$.jpg"
    # Use --full-res for OCR accuracy (resize happens later in image_detect for extracted images)
    "$SCREENSHOT" --in-app "$app" --output "$temp_screenshot" --full-res > /dev/null 2>&1

    if [[ ! -f "$temp_screenshot" ]]; then
        echo "ERROR: Failed to capture screenshot" >&2
        return 1
    fi

    # Optionally save screenshot
    if [[ -n "$save_screenshot" ]]; then
        cp "$temp_screenshot" "$save_screenshot"
    fi

    # Run OCR to get all text with positions (with timeout to prevent hanging)
    local ocr_output
    ocr_output=$(run_with_timeout "$READ_PAGE_TIMEOUT" "$PYTHON" "$OCR_FIND" "$temp_screenshot" --list --json 2>/dev/null)
    local ocr_status=$?

    if [[ $ocr_status -eq 124 ]]; then
        echo "WARNING: OCR timed out after ${READ_PAGE_TIMEOUT}s" >&2
        rm -f "$temp_screenshot"
        return 1
    fi

    # Run image detection if enabled (with timeout)
    local image_output=""
    if [[ "$DETECT_IMAGES" == "1" && -f "$IMAGE_DETECT" ]]; then
        image_output=$(run_with_timeout "$READ_PAGE_TIMEOUT" "$PYTHON" "$IMAGE_DETECT" "$temp_screenshot" --json 2>/dev/null)
    fi

    # Run icon detection if enabled (with timeout)
    local icon_output=""
    if [[ "$DETECT_ICONS" == "1" && -f "$ELEMENT_DETECT" ]]; then
        icon_output=$(run_with_timeout "$READ_PAGE_TIMEOUT" "$PYTHON" "$ELEMENT_DETECT" --image "$temp_screenshot" --extract --json 2>/dev/null)
    fi

    # Get bubble position if running (for LLM awareness of obscured areas)
    local bubble_info=""
    local bubble_script="${SCRIPT_DIR}/bubble.sh"
    if [[ -f "$bubble_script" ]]; then
        bubble_info=$("$bubble_script" --get-position 2>/dev/null | grep "^@bubble" || echo "")
    fi

    # Format output using Python
    "$PYTHON" - "$ocr_output" "$app" "$display" "$win_w" "$win_h" "$classify" "$json_output" "$image_output" "$bubble_info" "$region" "$aspect" "$icon_output" "$OCR_SCREENSHOT_API" "$piece_output" << 'PYEOF'
import json
import sys

ocr_json = sys.argv[1]
app = sys.argv[2]
display = sys.argv[3]
win_w = sys.argv[4]
win_h = sys.argv[5]
classify = sys.argv[6] == "true"
json_output = sys.argv[7] == "true"
image_json = sys.argv[8] if len(sys.argv) > 8 else ""
bubble_info = sys.argv[9] if len(sys.argv) > 9 else ""
region_str = sys.argv[10] if len(sys.argv) > 10 else ""
aspect_mode = sys.argv[11] == "true" if len(sys.argv) > 11 else False
icon_json = sys.argv[12] if len(sys.argv) > 12 else ""
screenshot_path = sys.argv[13] if len(sys.argv) > 13 else ""
piece_json = sys.argv[14] if len(sys.argv) > 14 else ""

# Aspect transformation: convert to square coordinate space
win_w_f = float(win_w) if win_w else 0
win_h_f = float(win_h) if win_h else 0

def to_aspect_coords(x, y, w, h):
    """Transform percentages to square coordinate space."""
    if not aspect_mode or win_w_f == 0 or win_h_f == 0:
        return x, y, w, h

    min_dim = min(win_w_f, win_h_f)
    # Offsets in percentage terms
    off_x_pct = (win_w_f - min_dim) / 2 * 100 / win_w_f
    off_y_pct = (win_h_f - min_dim) / 2 * 100 / win_h_f
    # Scale factor (how much bigger is original space vs square space)
    scale_x = win_w_f / min_dim
    scale_y = win_h_f / min_dim

    new_x = (x - off_x_pct) * scale_x
    new_y = (y - off_y_pct) * scale_y
    new_w = w * scale_x
    new_h = h * scale_y
    return new_x, new_y, new_w, new_h

region = None
if region_str:
    try:
        parts = [float(x) for x in region_str.split(',')]
        if len(parts) == 4:
            region = {'x1': parts[0], 'y1': parts[1], 'x2': parts[2], 'y2': parts[3]}
    except:
        pass

def in_region(bounds_pct, region):
    if not region:
        return True
    cx = bounds_pct.get('x', 0) + bounds_pct.get('width', 0) / 2
    cy = bounds_pct.get('y', 0) + bounds_pct.get('height', 0) / 2
    return (region['x1'] <= cx <= region['x2'] and region['y1'] <= cy <= region['y2'])

# Parse text elements from OCR
try:
    text_elements = json.loads(ocr_json) if ocr_json else []
except:
    text_elements = []

# Parse image elements
try:
    image_elements = json.loads(image_json) if image_json else []
except:
    image_elements = []

# Parse icon elements
try:
    icon_elements = json.loads(icon_json) if icon_json else []
except:
    icon_elements = []

# Parse piece elements (game pieces)
try:
    piece_elements = json.loads(piece_json) if piece_json else []
except:
    piece_elements = []

# Merge text, images, icons, and pieces into unified elements list, applying region filter
elements = []
for e in text_elements:
    bounds = e.get('bounds_pct', {})
    if in_region(bounds, region):
        elements.append({
            'type': 'text',
            'bounds_pct': bounds,
            'text': e.get('text', '')
        })

for img in image_elements:
    bounds = img.get('bounds_pct', {})
    if in_region(bounds, region):
        elements.append({
            'type': 'image',
            'bounds_pct': bounds,
            'path': img.get('path', ''),
            'description': img.get('description', 'Image')
        })

for icon in icon_elements:
    # Icon bbox is [x, y, w, h] array, convert to dict
    bbox = icon.get('bbox', [0, 0, 0, 0])
    bounds = {'x': bbox[0], 'y': bbox[1], 'width': bbox[2], 'height': bbox[3]}
    if in_region(bounds, region):
        elements.append({
            'type': 'icon',
            'bounds_pct': bounds,
            'path': icon.get('path', ''),
            'icon_type': icon.get('type', 'icon'),
            'icon_desc': icon.get('desc', '')
        })

for piece in piece_elements:
    # Piece has x, y, w, h keys directly
    bounds = {'x': piece.get('x', 0), 'y': piece.get('y', 0), 'width': piece.get('w', 0), 'height': piece.get('h', 0)}
    if in_region(bounds, region):
        elements.append({
            'type': 'piece',
            'bounds_pct': bounds,
            'color': piece.get('color', 'unknown'),
            'circularity': piece.get('circularity', 0)
        })

# Sort by position (top-to-bottom, left-to-right reading order)
def sort_key(e):
    b = e.get('bounds_pct', {})
    y = b.get('y', 0)
    x = b.get('x', 0)
    return (round(y / 5) * 5, x)  # Group by ~5% vertical bands

elements.sort(key=sort_key)

image_count = sum(1 for e in elements if e['type'] == 'image')
icon_count = sum(1 for e in elements if e['type'] == 'icon')
piece_count = sum(1 for e in elements if e['type'] == 'piece')
text_count = len(elements) - image_count - icon_count - piece_count

if json_output:
    output = {
        "app": app,
        "display": int(display) if display else 1,
        "viewport": [int(win_w), int(win_h)],
        "scroll": "unknown",
        "screenshot": screenshot_path if screenshot_path else None,
        "elements": []
    }
    for e in elements:
        b = e.get('bounds_pct', {})
        x, y, w, h = to_aspect_coords(
            b.get('x', 0), b.get('y', 0),
            b.get('width', 0), b.get('height', 0)
        )
        x, y, w, h = round(x, 1), round(y, 1), round(w, 1), round(h, 1)
        if e['type'] == 'image':
            elem = {
                "b": [x, y, w, h],
                "type": "image",
                "path": e.get('path', ''),
                "desc": e.get('description', '')
            }
        elif e['type'] == 'icon':
            elem = {
                "b": [x, y, w, h],
                "type": "icon",
                "path": e.get('path', ''),
                "icon_type": e.get('icon_type', 'icon'),
                "desc": e.get('icon_desc', '')
            }
        else:
            elem = {
                "b": [x, y, w, h],
                "t": e.get('text', '')
            }
        output["elements"].append(elem)
    print(json.dumps(output, indent=2))
else:
    # Line-oriented format: [x,y,w,h] where x,y is top-left corner
    aspect_flag = " --aspect" if aspect_mode else ""
    screenshot_info = f" screenshot:{screenshot_path}" if screenshot_path else ""
    print(f"@page {app} display:{display} viewport:{win_w}x{win_h}{aspect_flag}{screenshot_info}")
    # Include bubble position info if running (helps LLM avoid obscured areas)
    if bubble_info:
        print(bubble_info)
    for e in elements:
        b = e.get('bounds_pct', {})
        x, y, w, h = to_aspect_coords(
            b.get('x', 0), b.get('y', 0),
            b.get('width', 0), b.get('height', 0)
        )
        x, y, w, h = round(x, 1), round(y, 1), round(w, 1), round(h, 1)
        if e['type'] == 'image':
            path = e.get('path', '')
            desc = e.get('description', 'Image')
            print(f"[{x},{y},{w},{h}] [IMAGE:{path} \"{desc}\"]")
        elif e['type'] == 'icon':
            path = e.get('path', '')
            icon_type = e.get('icon_type', 'icon')
            icon_desc = e.get('icon_desc', '')
            # Include description if available, otherwise just type
            label = f"{icon_type} {icon_desc}".strip() if icon_desc else icon_type
            print(f"[{x},{y},{w},{h}] [ICON:{path} \"{label}\"]")
        else:
            text = e.get('text', '')
            print(f"[{x},{y},{w},{h}] {text}")
    print("---")
    print(f"elements:{text_count} icons:{icon_count} images:{image_count}")
PYEOF

    rm -f "$temp_screenshot"
}

# List all text visible on screen (for debugging)
list_screen_text() {
    local display="${1:-$DISPLAY_NUM}"

    local temp_screenshot="/tmp/ocr_list_$$.jpg"

    local screenshot_cmd="$SCREENSHOT"
    [[ -n "$display" ]] && screenshot_cmd="$screenshot_cmd --display $display"
    screenshot_cmd="$screenshot_cmd --output $temp_screenshot --full-res"

    $screenshot_cmd > /dev/null 2>&1

    if [[ ! -f "$temp_screenshot" ]]; then
        echo "ERROR: Failed to capture screenshot"
        return 1
    fi

    echo "Text found on screen:"
    "$PYTHON" "$OCR_FIND" "$temp_screenshot" --list

    rm -f "$temp_screenshot"
}

# ============================================================================
# ATOMIC COMMAND CHAINS
# ============================================================================

# Execute a chain of commands atomically
# Usage: run_chain "activate:Firefox" "wait:300" "click:68 comments" "wait:500" "type:hello"
run_chain() {
    local default_delay=150  # ms between commands
    IN_CHAIN=1  # Suppress auto-read in individual actions; chain handles it at end
    local needs_auto_wait=""  # Set after navigation actions

    # Restore persistent target app if set (enables OCR output at chain end)
    restore_target_app

    # Convert args to array for index-based access (needed for lookahead)
    local -a actions=("$@")
    local i=0
    local num_actions=${#actions[@]}

    while [[ $i -lt $num_actions ]]; do
        local cmd="${actions[$i]}"
        local action="${cmd%%:*}"
        local arg="${cmd#*:}"

        # If no colon, arg equals action (no argument)
        [[ "$action" == "$arg" ]] && arg=""

        # Auto-wait after navigation actions (unless explicit wait follows)
        if [[ -n "$needs_auto_wait" ]]; then
            case "$action" in
                wait|wait-for-text|wait-for-change)
                    # Explicit wait provided - skip auto-wait
                    ;;
                *)
                    # No explicit wait - do smart wait for page to stabilize
                    echo "Chain: Auto-waiting for page change (timeout: ${AUTO_WAIT_TIMEOUT}ms)..." >&2
                    if ! wait_for_change "" "$AUTO_WAIT_TIMEOUT" 2>/dev/null; then
                        echo "Chain: WARNING - auto-wait timed out after ${AUTO_WAIT_TIMEOUT}ms (page may not have changed)" >&2
                    fi
                    ;;
            esac
            needs_auto_wait=""
        fi

        case "$action" in
            open)
                echo "Chain: Opening $arg"
                open_app "$arg"
                wait_ms 500  # Apps need more time to launch
                # Also set IN_APP since we're likely to interact with the opened app
                set_target_app "$arg"
                ACTIVATE_APP="$arg"
                ;;
            activate)
                echo "Chain: Activating $arg"
                activate_app "$arg"
                wait_ms "$default_delay"
                # Browsers may auto-focus address bar on activation - Escape deselects it
                # (F6 can trigger macOS system functions like Control Center)
                local app_lower=$(echo "$arg" | tr '[:upper:]' '[:lower:]')
                if [[ "$app_lower" == "firefox" || "$app_lower" == "safari" || "$app_lower" == "chrome" || "$app_lower" == "google chrome" || "$app_lower" == "arc" || "$app_lower" == "brave" || "$app_lower" == "edge" ]]; then
                    sleep 0.3
                    echo "Chain: Pressing Escape to deselect address bar"
                    press_key "esc"
                    sleep 0.2
                fi
                ;;
            in-app)
                echo "Chain: Setting target app to $arg"
                set_target_app "$arg"
                # Also set activate-before to the same app (common pattern)
                ACTIVATE_APP="$arg"
                # Also set display context based on app's window location
                local app_where=$("$PYTHON" "$WINDOW_LIST" --app "$arg" --where 2>&1)
                if ! echo "$app_where" | grep -q "No window found"; then
                    local app_disp=$(echo "$app_where" | grep "^DISPLAY:" | sed 's/DISPLAY: //' | awk '{print $1}')
                    if [[ -n "$app_disp" ]]; then
                        DISPLAY_NUM="$app_disp"
                        set_display "$app_disp" 2>/dev/null
                        echo "Chain: Set display context to $app_disp (from $arg)"
                    fi
                    # Store window bounds for scroll targeting
                    IN_APP_BOUNDS=$(echo "$app_where" | grep "^BOUNDS:" | sed 's/BOUNDS: //')
                fi
                ;;
            wait)
                echo "Chain: Waiting ${arg}ms"
                wait_ms "$arg"
                ;;
            click)
                # Unified click with pipe modifiers: click:target|double|near:anchor
                local click_arg="$arg"
                local click_type="c"
                local near_text=""

                # Parse modifiers (split by |)
                while [[ "$click_arg" == *"|"* ]]; do
                    local modifier="${click_arg##*|}"
                    click_arg="${click_arg%|*}"

                    case "$modifier" in
                        double) click_type="dc" ;;
                        right) click_type="rc" ;;
                        triple) click_type="tc" ;;
                        near:*) near_text="${modifier#near:}" ;;
                    esac
                done

                # Build click description based on type
                local click_desc=""
                case "$click_type" in
                    dc) click_desc="Double-clicking" ;;
                    rc) click_desc="Right-clicking" ;;
                    tc) click_desc="Triple-clicking" ;;
                    *) click_desc="Clicking" ;;
                esac

                # Check for prefixes (toggle:, info:, px:)
                if [[ "$click_arg" == toggle:* ]]; then
                    echo "Chain: $click_desc toggle '${click_arg#toggle:}'${IN_APP:+ (in $IN_APP)}"
                    click_toggle "${click_arg#toggle:}"
                elif [[ "$click_arg" == info:* ]]; then
                    echo "Chain: $click_desc info button '${click_arg#info:}'${IN_APP:+ (in $IN_APP)}"
                    click_info "${click_arg#info:}"
                elif [[ "$click_arg" == px:* ]]; then
                    echo "Chain: $click_desc at pixel ${click_arg#px:}"
                    click_pixel "${click_arg#px:}" "$click_type"
                elif [[ "$click_arg" =~ ^[0-9.-]+,[0-9.-]+(,[0-9.]+,[0-9.]+)?$ ]]; then
                    # Grid coordinates
                    echo "Chain: $click_desc at $click_arg"
                    click_grid "$click_arg" "$click_type"
                else
                    # Text target (OCR)
                    echo "Chain: $click_desc on text '$click_arg'${near_text:+ near '$near_text'}${IN_APP:+ (in $IN_APP)}"

                    # Set NEAR_TEXT if specified
                    local saved_near="$NEAR_TEXT"
                    [[ -n "$near_text" ]] && NEAR_TEXT="$near_text"
                    click_text "$click_arg" "$click_type" "1"
                    NEAR_TEXT="$saved_near"
                fi

                wait_ms "$default_delay"
                needs_auto_wait=1  # Navigation action - auto-wait for page change
                ;;
            drag-easing)
                # Set easing for drags: linear, ease-in, ease-out, ease-in-out
                case "$arg" in
                    linear|ease-in|ease-out|ease-in-out)
                        DRAG_EASING="$arg"
                        echo "Chain: Drag easing set to $arg"
                        ;;
                    *)
                        echo "Chain: ERROR - drag-easing must be linear, ease-in, ease-out, or ease-in-out"
                        return 1
                        ;;
                esac
                ;;
            drag-steps)
                # Set number of interpolation steps (10-500)
                if [[ "$arg" =~ ^[0-9]+$ && "$arg" -ge 10 && "$arg" -le 500 ]]; then
                    DRAG_STEPS="$arg"
                    echo "Chain: Drag steps set to $arg"
                else
                    echo "Chain: ERROR - drag-steps must be a number between 10 and 500"
                    return 1
                fi
                ;;
            aspect)
                # Enable aspect ratio correction (square coordinate space)
                # Optional: aspect:x1,y1,x2,y2 to specify region
                ASPECT_CORRECT="1"
                if [[ -n "$arg" && "$arg" =~ ^[0-9] ]]; then
                    REGION="$arg"
                    echo "Chain: Aspect correction enabled (region $REGION)"
                else
                    echo "Chain: Aspect correction enabled (full window)"
                fi
                ;;
            arc)
                # Set arc parameters for next drag
                # Format: arc:position:tension (e.g., arc:90:0, arc:-90:100)
                if [[ "$arg" =~ ^(-?[0-9]+):(-?[0-9]+)$ ]]; then
                    ARC_POSITION="${BASH_REMATCH[1]}"
                    ARC_TENSION="${BASH_REMATCH[2]}"
                    local abs_pos=${ARC_POSITION#-}
                    if [[ $abs_pos -lt 1 || $abs_pos -gt 179 ]]; then
                        echo "Chain: ERROR - Arc position must be ±1 to ±179 (got $ARC_POSITION)"
                        return 1
                    fi
                    echo "Chain: Arc set (pos=$ARC_POSITION, tension=$ARC_TENSION) - applies to next drag"
                else
                    echo "Chain: ERROR - arc requires format position:tension (e.g., arc:90:0)"
                    return 1
                fi
                ;;
            dragend)
                # Explicit mouse release for drag chaining
                if [[ -n "$DRAG_MOUSE_DOWN" ]]; then
                    echo "Chain: Ending drag (releasing mouse)"
                    "$PYTHON" <<'PYEOF'
from Quartz import CGEventCreateMouseEvent, CGEventPost, kCGEventLeftMouseUp, kCGHIDEventTap, CGEventGetLocation, CGEventCreate
event = CGEventCreate(None)
loc = CGEventGetLocation(event)
up_event = CGEventCreateMouseEvent(None, kCGEventLeftMouseUp, loc, 0)
CGEventPost(kCGHIDEventTap, up_event)
PYEOF
                    DRAG_MOUSE_DOWN=""
                else
                    echo "Chain: dragend - no drag in progress"
                fi
                ;;
            drag)
                # Format: drag:x1,y1,x2,y2 or drag:x1,y1,w,h,x2,y2 (box to point)
                # BATCH consecutive drags into single Python call to avoid pauses

                # Restore target app once at start
                restore_target_app

                # Collect all consecutive drag+arc actions
                local -a batch_segments=()
                local scan_i=$i

                while [[ $scan_i -lt $num_actions ]]; do
                    local scan_cmd="${actions[$scan_i]}"
                    local scan_action="${scan_cmd%%:*}"
                    local scan_arg="${scan_cmd#*:}"
                    [[ "$scan_action" == "$scan_arg" ]] && scan_arg=""

                    if [[ "$scan_action" == "drag" ]]; then
                        local drag_coords="$scan_arg"
                        local arc_pos=0
                        local arc_ten=0

                        # Check if next action is arc: (modifies this drag)
                        local peek_i=$((scan_i + 1))
                        if [[ $peek_i -lt $num_actions ]]; then
                            local peek_cmd="${actions[$peek_i]}"
                            local peek_action="${peek_cmd%%:*}"
                            local peek_arg="${peek_cmd#*:}"
                            if [[ "$peek_action" == "arc" ]]; then
                                if [[ "$peek_arg" =~ ^(-?[0-9]+):(-?[0-9]+)$ ]]; then
                                    arc_pos="${BASH_REMATCH[1]}"
                                    arc_ten="${BASH_REMATCH[2]}"
                                    scan_i=$((scan_i + 1))  # Consume arc
                                fi
                            fi
                        fi

                        # Convert to pixel coordinates
                        local pixels=$(drag_coords_to_pixels "$drag_coords")
                        if [[ -n "$pixels" ]]; then
                            # Format: x1,y1,x2,y2,arc_pos,arc_tension
                            batch_segments+=("$pixels,$arc_pos,$arc_ten")
                            echo "Chain: Batching drag $drag_coords${arc_pos:+ (arc:$arc_pos:$arc_ten)}" >&2
                        fi

                        scan_i=$((scan_i + 1))

                        # Check if next is also a drag (continue batching)
                        if [[ $scan_i -lt $num_actions ]]; then
                            local next_cmd="${actions[$scan_i]}"
                            local next_action="${next_cmd%%:*}"
                            [[ "$next_action" != "drag" ]] && break
                        fi
                    else
                        break
                    fi
                done

                # Execute batch
                if [[ ${#batch_segments[@]} -gt 0 ]]; then
                    echo "Chain: Executing ${#batch_segments[@]} drag segments in batch"
                    drag_batch "${batch_segments[@]}"
                fi

                # Update loop index to skip consumed actions
                i=$((scan_i - 1))  # -1 because loop will increment

                DRAG_MOUSE_DOWN=""
                wait_ms "$default_delay"
                ;;
            type)
                echo "Chain: Typing '$arg'"
                local chain_fast=""
                [[ -n "$TYPE_FAST" ]] && chain_fast="--fast"
                type_text "$arg" "$TYPE_DELAY" "$chain_fast"
                wait_ms "$default_delay"
                ;;
            key)
                echo "Chain: Pressing key $arg"
                press_key "$arg"
                wait_ms "$default_delay"
                # Return/enter typically triggers navigation
                [[ "$arg" == "return" || "$arg" == "enter" ]] && needs_auto_wait=1
                ;;
            combo)
                echo "Chain: Pressing combo $arg"
                key_combo "$arg"
                wait_ms "$default_delay"
                ;;
            scroll)
                # Format: scroll:direction or scroll:direction,amount or scroll:direction,amount,x,y
                local scroll_dir scroll_amt scroll_pos
                IFS=',' read -r scroll_dir scroll_amt scroll_pos <<< "$arg"
                scroll_amt="${scroll_amt:-5}"
                # If IN_APP is set and no position specified, use scroll_in_app for auto-targeting
                if [[ -n "$IN_APP" && -z "$scroll_pos" ]]; then
                    echo "Chain: Scrolling $scroll_dir by $scroll_amt in $IN_APP"
                    scroll_in_app "$IN_APP" "$scroll_dir" "$scroll_amt"
                else
                    echo "Chain: Scrolling $scroll_dir by $scroll_amt${scroll_pos:+ at $scroll_pos}"
                    scroll_at "$scroll_dir" "$scroll_amt" "$scroll_pos"
                fi
                wait_ms "$default_delay"
                ;;
            page-top|page-bottom)
                # Navigate to top/bottom of page using large scroll
                local scroll_dir="up"
                [[ "$action" == "page-bottom" ]] && scroll_dir="down"
                if [[ -n "$IN_APP" ]]; then
                    echo "Chain: Going to $action in $IN_APP (scrolling $scroll_dir)"
                    # Use scroll_in_app with large amount (200 units = ~6000px)
                    scroll_in_app "$IN_APP" "$scroll_dir" 200
                else
                    echo "Chain: Going to $action (scrolling $scroll_dir)"
                    scroll_at "$scroll_dir" 200 ""
                fi
                wait_ms "$default_delay"
                ;;
            back-no-close)
                # Go back without auto-close (simple cmd+[)
                echo "Chain: Going back (no auto-close)"
                key_combo "cmd+["
                wait_ms "$default_delay"
                needs_auto_wait=1  # Navigation action
                ;;
            back)
                # Go back, or close tab/window if no history (smart default)
                # Compares window title before/after to detect if navigation happened
                echo "Chain: Going back"

                # Get window title before navigation
                local title_before=""
                if [[ -n "$IN_APP" ]]; then
                    title_before=$(osascript -e "tell application \"$IN_APP\" to get name of front window" 2>/dev/null)
                else
                    title_before=$(osascript -e 'tell application "System Events" to get name of first window of (first process whose frontmost is true)' 2>/dev/null)
                fi

                key_combo "cmd+["
                sleep 1.5  # Wait longer for page/title to update

                # Get window title after navigation
                local title_after=""
                if [[ -n "$IN_APP" ]]; then
                    title_after=$(osascript -e "tell application \"$IN_APP\" to get name of front window" 2>/dev/null)
                else
                    title_after=$(osascript -e 'tell application "System Events" to get name of first window of (first process whose frontmost is true)' 2>/dev/null)
                fi

                if [[ -z "$title_before" ]]; then
                    # App doesn't expose window titles - can't detect history
                    echo "Chain: ERROR - App does not expose window titles. Cannot detect navigation history. Use explicit 'close-tab' or 'close-window' action if needed." >&2
                elif [[ "$title_before" == "$title_after" ]]; then
                    # Window title unchanged after back - no history, close tab
                    echo "Chain: WARNING - No history detected (title unchanged), closing tab/window" >&2
                    key_combo "cmd+w"
                    wait_ms "$default_delay"
                fi
                needs_auto_wait=1
                ;;
            close-tab|close-window)
                # Close current tab (browsers) or window (other apps)
                echo "Chain: Closing tab/window"
                key_combo "cmd+w"
                wait_ms "$default_delay"
                needs_auto_wait=1
                ;;
            forward)
                # Go forward (browsers, Finder, many apps)
                echo "Chain: Going forward"
                key_combo "cmd+]"
                wait_ms "$default_delay"
                needs_auto_wait=1  # Navigation action
                ;;
            up)
                # Go up/parent (Finder, some apps)
                echo "Chain: Going up"
                key_combo "cmd+arrow-up"
                wait_ms "$default_delay"
                ;;
            home)
                # Go to beginning of document/page
                echo "Chain: Going to home/beginning"
                key_combo "cmd+arrow-up"
                wait_ms "$default_delay"
                ;;
            end)
                # Go to end of document/page
                echo "Chain: Going to end"
                key_combo "cmd+arrow-down"
                wait_ms "$default_delay"
                ;;
            select-next)
                # Move selection down in lists
                echo "Chain: Selecting next item"
                press_key "arrow-down"
                wait_ms "$default_delay"
                ;;
            select-prev)
                # Move selection up in lists
                echo "Chain: Selecting previous item"
                press_key "arrow-up"
                wait_ms "$default_delay"
                ;;
            select-first)
                # Jump to first item
                echo "Chain: Selecting first item"
                key_combo "cmd+arrow-up"
                wait_ms "$default_delay"
                ;;
            select-last)
                # Jump to last item
                echo "Chain: Selecting last item"
                key_combo "cmd+arrow-down"
                wait_ms "$default_delay"
                ;;
            open-selection)
                # Open selected item
                echo "Chain: Opening selection"
                press_key "return"
                wait_ms "$default_delay"
                needs_auto_wait=1  # Navigation action
                ;;
            select-all)
                # Select all
                echo "Chain: Selecting all"
                key_combo "cmd+a"
                wait_ms "$default_delay"
                ;;
            play-pause|play|pause)
                # Toggle play/pause for media
                echo "Chain: Play/Pause"
                press_media_key "play-pause"
                wait_ms "$default_delay"
                ;;
            next-track|next)
                # Next track
                echo "Chain: Next track"
                press_media_key "next-track"
                wait_ms "$default_delay"
                ;;
            prev-track|previous)
                # Previous track
                echo "Chain: Previous track"
                press_media_key "prev-track"
                wait_ms "$default_delay"
                ;;
            volume-up)
                # Increase volume
                local amount="${arg:-1}"
                echo "Chain: Volume up${arg:+ ($amount times)}"
                for ((i=0; i<amount; i++)); do
                    press_media_key "volume-up"
                    sleep 0.05
                done
                wait_ms "$default_delay"
                ;;
            volume-down)
                # Decrease volume
                local amount="${arg:-1}"
                echo "Chain: Volume down${arg:+ ($amount times)}"
                for ((i=0; i<amount; i++)); do
                    press_media_key "volume-down"
                    sleep 0.05
                done
                wait_ms "$default_delay"
                ;;
            mute)
                # Toggle mute
                echo "Chain: Mute toggle"
                press_media_key "mute"
                wait_ms "$default_delay"
                ;;
            brightness-up)
                # Increase brightness
                local amount="${arg:-1}"
                echo "Chain: Brightness up${arg:+ ($amount times)}"
                for ((i=0; i<amount; i++)); do
                    press_media_key "brightness-up"
                    sleep 0.05
                done
                wait_ms "$default_delay"
                ;;
            brightness-down)
                # Decrease brightness
                local amount="${arg:-1}"
                echo "Chain: Brightness down${arg:+ ($amount times)}"
                for ((i=0; i<amount; i++)); do
                    press_media_key "brightness-down"
                    sleep 0.05
                done
                wait_ms "$default_delay"
                ;;
            audio-state)
                # Query and display current audio state
                echo "Chain: Checking audio state"
                get_audio_state
                ;;
            volume)
                # Set volume to specific level (0-100)
                if [[ -n "$arg" && "$arg" =~ ^[0-9]+$ ]]; then
                    echo "Chain: Setting volume to ${arg}%"
                    set_volume "$arg"
                else
                    echo "ERROR: volume requires a number 0-100 (e.g., volume:50)"
                fi
                wait_ms "$default_delay"
                ;;
            unmute)
                # Ensure audio is unmuted (only unmutes if currently muted)
                local is_muted=$(osascript -e 'output muted of (get volume settings)' 2>/dev/null)
                if [[ "$is_muted" == "true" ]]; then
                    echo "Chain: Unmuting audio"
                    press_media_key "mute"
                else
                    echo "Chain: Audio already unmuted"
                fi
                wait_ms "$default_delay"
                ;;
            wait-for-text)
                # Wait for text to appear or disappear
                # Format: wait-for-text:pattern or wait-for-text:pattern,gone or wait-for-text:pattern,appear,5000
                local wft_pattern wft_condition wft_timeout
                IFS=',' read -r wft_pattern wft_condition wft_timeout <<< "$arg"
                wft_condition="${wft_condition:-appear}"
                wft_timeout="${wft_timeout:-5000}"
                echo "Chain: Waiting for text '$wft_pattern' to $wft_condition"
                if ! wait_for_text "$wft_pattern" "$wft_condition" "$wft_timeout" "$IN_APP"; then
                    echo "Chain: FAILED - wait-for-text condition not met"
                    return 1
                fi
                ;;
            wait-for-change)
                # Wait for screen region to change
                # Format: wait-for-change or wait-for-change:x,y,w,h or wait-for-change:x,y,w,h,5000
                local wfc_region="" wfc_timeout="5000"
                if [[ -n "$arg" ]]; then
                    # Parse region and optional timeout
                    local wfc_parts
                    IFS=',' read -ra wfc_parts <<< "$arg"
                    if [[ ${#wfc_parts[@]} -ge 4 ]]; then
                        wfc_region="${wfc_parts[0]},${wfc_parts[1]},${wfc_parts[2]},${wfc_parts[3]}"
                        [[ ${#wfc_parts[@]} -ge 5 ]] && wfc_timeout="${wfc_parts[4]}"
                    elif [[ ${#wfc_parts[@]} -eq 1 ]]; then
                        wfc_timeout="${wfc_parts[0]}"
                    fi
                fi
                echo "Chain: Waiting for screen change"
                if ! wait_for_change "$wfc_region" "$wfc_timeout"; then
                    echo "Chain: FAILED - screen did not change"
                    return 1
                fi
                ;;
            verify-text)
                # Verify text is present or gone
                # Format: verify-text:pattern or verify-text:pattern,gone
                local vt_pattern vt_condition
                IFS=',' read -r vt_pattern vt_condition <<< "$arg"
                vt_condition="${vt_condition:-present}"
                echo "Chain: Verifying text '$vt_pattern' is $vt_condition"
                if ! verify_text "$vt_pattern" "$vt_condition" "$IN_APP"; then
                    echo "Chain: FAILED - verification failed"
                    return 1
                fi
                ;;
            screenshot)
                # Take a screenshot mid-chain
                # Usage: screenshot or screenshot:/path/to/file.jpg
                sleep 0.2  # Brief delay for UI to settle
                local screenshot_cmd="$SCREENSHOT"
                if [[ -n "$IN_APP" ]]; then
                    screenshot_cmd="$screenshot_cmd --in-app $IN_APP"
                fi
                if [[ -n "$arg" ]]; then
                    screenshot_cmd="$screenshot_cmd --output $arg"
                    echo "Chain: Taking screenshot to $arg"
                else
                    echo "Chain: Taking screenshot"
                fi
                $screenshot_cmd
                wait_ms "$default_delay"
                ;;
            clipboard-read)
                echo "Chain: Reading clipboard"
                read_clipboard
                ;;
            copy-text)
                echo "Chain: Copying text to clipboard"
                copy_text_to_clipboard "$arg"
                ;;
            paste)
                # Paste text without clobbering user's clipboard
                # Saves clipboard, pastes text, restores clipboard
                echo "Chain: Pasting text (preserving clipboard)"
                local saved_clipboard=$(pbpaste 2>/dev/null)
                printf '%s' "$arg" | pbcopy 2>/dev/null
                sleep 0.05
                cliclick "kd:cmd" "t:v" "ku:cmd"
                sleep 0.1
                printf '%s' "$saved_clipboard" | pbcopy 2>/dev/null
                wait_ms "$default_delay"
                ;;
            copy-image)
                echo "Chain: Copying image to clipboard"
                copy_image_to_clipboard "$arg"
                ;;
            copy-file)
                echo "Chain: Copying file to clipboard"
                copy_file_to_clipboard "$arg"
                ;;
            scroll-capture)
                # Scroll and capture in one step
                # Format: scroll-capture:dir,amount,path
                local sc_dir sc_amt sc_path
                IFS=',' read -r sc_dir sc_amt sc_path <<< "$arg"
                sc_amt="${sc_amt:-page}"
                if [[ -z "$sc_path" ]]; then
                    sc_path="/tmp/scroll_capture_$$.jpg"
                fi
                echo "Chain: Scrolling $sc_dir by $sc_amt and capturing to $sc_path"
                if [[ -n "$IN_APP" ]]; then
                    scroll_in_app "$IN_APP" "$sc_dir" "$sc_amt"
                else
                    scroll_at "$sc_dir" "$sc_amt" ""
                fi
                sleep 0.3
                local sc_screenshot_cmd="$SCREENSHOT"
                if [[ -n "$IN_APP" ]]; then
                    sc_screenshot_cmd="$sc_screenshot_cmd --in-app $IN_APP"
                fi
                sc_screenshot_cmd="$sc_screenshot_cmd --output $sc_path"
                $sc_screenshot_cmd
                wait_ms "$default_delay"
                ;;
            switch-tab)
                # Switch to existing browser tab by search term
                # Format: switch-tab:term or switch-tab:term,N (auto-select Nth result)
                # Works in Firefox (% prefix) and Chrome (similar)
                local search_term select_n
                IFS=',' read -r search_term select_n <<< "$arg"
                local browser="${IN_APP:-Firefox}"
                echo "Chain: Searching for tab '$search_term' in $browser"
                activate_app "$browser" > /dev/null 2>&1
                sleep 0.2
                # Use URL bar with % prefix to search tabs
                key_combo "cmd+l"
                sleep 0.2
                type_text "% $search_term"
                sleep 0.4
                if [[ -n "$select_n" && "$select_n" =~ ^[0-9]+$ ]]; then
                    # Auto-select Nth result
                    echo "Chain: Selecting result #$select_n"
                    for ((i=0; i<select_n; i++)); do
                        press_key "arrow-down"
                        sleep 0.05
                    done
                    sleep 0.1
                    press_key "return"
                else
                    echo "Chain: Tab search dropdown open - use arrow-down to navigate, return to select"
                fi
                wait_ms "$default_delay"
                ;;
            tab)
                # Switch to tab by number (1-9) - useful for pinned tabs
                # Cmd+1 = first tab, Cmd+9 = last tab
                local tab_num="$arg"
                if [[ ! "$tab_num" =~ ^[1-9]$ ]]; then
                    echo "ERROR: tab number must be 1-9"
                    return 1
                fi
                local browser="${IN_APP:-Firefox}"
                echo "Chain: Switching to tab #$tab_num in $browser"
                activate_app "$browser" > /dev/null 2>&1
                sleep 0.1
                key_combo "cmd+$tab_num"
                wait_ms "$default_delay"
                ;;
            browse)
                # Smart browse - find existing tab/window or open new one
                # Works across Firefox, Safari, Chrome (URLs) and Finder (paths)
                # Examples: browse:bsky.app, browse:github.com, browse:/Users/jay/Documents
                echo "Chain: Browsing to '$arg'"
                if ! browse_url "$arg" "$IN_APP"; then
                    return 1
                fi
                wait_ms "$default_delay"
                needs_auto_wait=1
                ;;
            goto|goto-url)
                # Navigate to URL/site, reusing existing tab if found
                # Reads Firefox session file to find existing tabs (fast, reliable)
                # Examples: goto:hacker, goto:gmail, goto:youtube.com/watch:2 (2nd match)
                local search_term="$arg"
                local pick_index=""
                local browser="${IN_APP:-Firefox}"

                # Check for :N suffix to pick Nth match (e.g., goto:youtube:2)
                if [[ "$search_term" =~ ^(.+):([0-9]+)$ ]]; then
                    search_term="${BASH_REMATCH[1]}"
                    pick_index="${BASH_REMATCH[2]}"
                fi

                # Search Firefox tabs directly from session file - get ALL matches
                local matches_json=""
                local match_count=0
                if [[ -f "$FIREFOX_TABS" ]]; then
                    matches_json=$("$PYTHON" "$FIREFOX_TABS" --search "$search_term" --json 2>/dev/null)
                    match_count=$(echo "$matches_json" | "$PYTHON" -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
                fi

                if [[ "$match_count" -eq 1 ]]; then
                    # Exactly one match - switch to it
                    local tab_index=$(echo "$matches_json" | "$PYTHON" -c "import json,sys; print(json.load(sys.stdin)[0]['index'])")
                    local tab_title=$(echo "$matches_json" | "$PYTHON" -c "import json,sys; print(json.load(sys.stdin)[0]['title'][:50])")
                    echo "Chain: Found tab #$tab_index '$tab_title' - switching"
                    activate_app "$browser" > /dev/null 2>&1
                    sleep 0.1
                    key_combo "cmd+l"
                    sleep 0.1
                    type_text "% $search_term"
                    sleep 0.3
                    press_key "arrow-down"
                    sleep 0.1
                    press_key "return"
                elif [[ "$match_count" -gt 1 ]]; then
                    # Multiple matches
                    if [[ -n "$pick_index" && "$pick_index" -ge 1 && "$pick_index" -le "$match_count" ]]; then
                        # User specified which match to use
                        local idx=$((pick_index - 1))
                        local tab_index=$(echo "$matches_json" | "$PYTHON" -c "import json,sys; print(json.load(sys.stdin)[$idx]['index'])")
                        local tab_title=$(echo "$matches_json" | "$PYTHON" -c "import json,sys; print(json.load(sys.stdin)[$idx]['title'][:50])")
                        echo "Chain: Using match #$pick_index: tab #$tab_index '$tab_title' - switching"
                        activate_app "$browser" > /dev/null 2>&1
                        sleep 0.1
                        key_combo "cmd+l"
                        sleep 0.1
                        # Use the specific title for more accurate matching
                        type_text "% $tab_title"
                        sleep 0.3
                        press_key "arrow-down"
                        sleep 0.1
                        press_key "return"
                    else
                        # List matches and DON'T switch - let LLM choose
                        echo "Chain: Found $match_count tabs matching '$search_term':"
                        local tmpfile=$(mktemp)
                        echo "$matches_json" > "$tmpfile"
                        "$PYTHON" << PYEOF
import json
with open("$tmpfile") as f:
    tabs = json.load(f)
for i, tab in enumerate(tabs[:10], 1):
    title = tab['title'][:45] + '...' if len(tab['title']) > 45 else tab['title']
    url_short = tab['url'][:50] + '...' if len(tab['url']) > 50 else tab['url']
    print(f"  {i}. #{tab['index']} \"{title}\"")
    print(f"     {url_short}")
if len(tabs) > 10:
    print(f"  ... and {len(tabs) - 10} more")
PYEOF
                        rm -f "$tmpfile"
                        echo "Chain: Use goto:$search_term:N to select (e.g., goto:$search_term:1)"
                        # Don't switch - return early
                        wait_ms "$default_delay"
                        i=$((i + 1))
                        continue
                    fi
                else
                    # No existing tab - navigate to URL
                    echo "Chain: No existing tab for '$search_term' - navigating"
                    activate_app "$browser" > /dev/null 2>&1
                    sleep 0.1
                    key_combo "cmd+l"
                    sleep 0.1
                    # Navigate to the URL
                    if [[ "$search_term" =~ ^https?:// ]]; then
                        type_text "$search_term"
                    elif [[ "$search_term" == *.* ]]; then
                        type_text "https://$search_term"
                    else
                        echo "Chain: Warning - '$search_term' is not a URL, Firefox will search for it"
                        type_text "$search_term"
                    fi
                    sleep 0.1
                    press_key "return"
                fi
                wait_ms "$default_delay"
                ;;
            *)
                echo "ERROR: Unknown chain action: $action"
                return 1
                ;;
        esac

        # Increment index for next iteration
        i=$((i + 1))
    done

    # Release mouse if held from drag chaining
    if [[ -n "$DRAG_MOUSE_DOWN" ]]; then
        echo "Chain: Releasing held mouse button" >&2
        # Release mouse at current position using Python
        "$PYTHON" <<'PYEOF'
from Quartz import CGEventCreateMouseEvent, CGEventPost, kCGEventLeftMouseUp, kCGHIDEventTap, CGEventGetLocation, CGEventCreate
event = CGEventCreate(None)
loc = CGEventGetLocation(event)
up_event = CGEventCreateMouseEvent(None, kCGEventLeftMouseUp, loc, 0)
CGEventPost(kCGHIDEventTap, up_event)
PYEOF
        DRAG_MOUSE_DOWN=""
    fi

    echo "Chain: Complete" >&2
    IN_CHAIN=""  # Clear chain flag

    # Auto-return page state when IN_APP is set (with timeout)
    if [[ -n "$IN_APP" ]]; then
        sleep 0.3  # Brief pause for UI to settle
        # Run read_page with timeout to avoid hanging on OCR
        local timeout_sec="$READ_PAGE_TIMEOUT"
        local read_output=""

        # Use background process with timeout (macOS compatible)
        # Pass REGION for filtering if set
        read_output=$(
            ( read_page "$IN_APP" "false" "false" "" "$REGION" ) &
            local pid=$!
            ( sleep "$timeout_sec"; kill $pid 2>/dev/null ) &
            local killer=$!
            wait $pid 2>/dev/null
            local exit_code=$?
            kill $killer 2>/dev/null
            wait $killer 2>/dev/null
            exit $exit_code
        ) 2>/dev/null

        if [[ $? -ne 0 || -z "$read_output" ]]; then
            echo "Chain: WARNING - read_page timed out after ${timeout_sec}s (OCR may be slow)" >&2
            echo "@page $IN_APP display:${DISPLAY_NUM:-1}" >&2
            echo "[Page content unavailable - timeout]" >&2
            echo "---" >&2
        else
            echo "$read_output"
        fi
    fi
}

# Nudge cursor by pixel offset from current position
nudge_mouse() {
    local offset="$1"

    IFS=',' read -r dx dy <<< "$offset"

    if [[ -z "$dx" || -z "$dy" ]]; then
        echo "ERROR: Invalid offset. Use format: dx,dy (e.g., 0,-5 for up 5px)"
        return 1
    fi

    # Get current position
    local pos=$(cliclick p 2>/dev/null)
    local cur_x=$(echo "$pos" | cut -d',' -f1)
    local cur_y=$(echo "$pos" | cut -d',' -f2)

    # Calculate new position
    local new_x=$((cur_x + dx))
    local new_y=$((cur_y + dy))

    # Format for cliclick
    local cli_x="$new_x"
    local cli_y="$new_y"
    [[ $new_x -lt 0 ]] && cli_x="=$new_x"
    [[ $new_y -lt 0 ]] && cli_y="=$new_y"

    echo "Nudging from ($cur_x, $cur_y) by ($dx, $dy) to ($new_x, $new_y)"
    cliclick "m:$cli_x,$cli_y"
}

# Scroll at current mouse position or specified grid position
# Usage: scroll_at <direction> [amount] [x,y]
# direction: up, down, left, right
# amount: number of scroll units (default: 3)
# x,y: optional grid position to scroll at
scroll_at() {
    local direction="$1"
    local amount="${2:-3}"
    local coords="$3"

    # Restore target app if set (auto-reactivates the app)
    restore_target_app

    # Support named scroll presets
    case "$amount" in
        page)      amount=20 ;;      # ~600px, roughly one viewport
        half|half-page) amount=10 ;; # ~300px
        little)    amount=3 ;;       # small adjustment
        *)         ;;                # numeric passthrough
    esac

    # If coords provided, move mouse there first
    # If no coords but target app is set, move mouse to app's content area
    if [[ -n "$coords" ]]; then
        IFS=',' read -r grid_x grid_y <<< "$coords"
        local pixel_coords=$(grid_to_pixel "$grid_x" "$grid_y")
        local pixel_x=$(echo "$pixel_coords" | awk '{print $1}')
        local pixel_y=$(echo "$pixel_coords" | awk '{print $2}')
        local cli_x=$(echo "$pixel_coords" | awk '{print $3}')
        local cli_y=$(echo "$pixel_coords" | awk '{print $4}')
        cliclick "m:$cli_x,$cli_y"
        sleep 0.1
    elif [[ -n "$IN_APP" ]]; then
        # Move mouse to target app's content area for scroll to work
        local where_output=$("$PYTHON" "$WINDOW_LIST" --app "$IN_APP" --where 2>&1)
        if ! echo "$where_output" | grep -q "No window found"; then
            local bounds=$(echo "$where_output" | grep "^BOUNDS:" | sed 's/BOUNDS: //')
            if [[ -n "$bounds" ]]; then
                IFS=',' read -r win_x win_y win_w win_h <<< "$bounds"
                local content_x=$((win_x + win_w * 60 / 100))
                local content_y=$((win_y + win_h * 50 / 100))
                "$PYTHON" << PYEOF
import Quartz
move = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventMouseMoved, ($content_x, $content_y), 0)
Quartz.CGEventPost(Quartz.kCGHIDEventTap, move)
PYEOF
                sleep 0.1
            fi
        fi
    fi

    # Determine scroll direction
    local scroll_x=0
    local scroll_y=0
    case "$direction" in
        up)    scroll_y=$amount ;;
        down)  scroll_y=-$amount ;;
        left)  scroll_x=$amount ;;
        right) scroll_x=-$amount ;;
        *)
            echo "ERROR: Invalid scroll direction. Use: up, down, left, right"
            return 1
            ;;
    esac

    echo "Scrolling $direction by $amount"

    # Use Python/Quartz to send scroll wheel events (pixel-based for reliability)
    "$PYTHON" << PYEOF
import Quartz
import time

# Send multiple smaller scroll events for smoother scrolling
pixels_per_unit = 30
total_pixels = $amount * pixels_per_unit

# Scroll in chunks
chunk_size = 50
chunks = max(1, abs(total_pixels) // chunk_size)
pixel_per_chunk_y = ($scroll_y * pixels_per_unit) // max(1, chunks) if $scroll_y != 0 else 0
pixel_per_chunk_x = ($scroll_x * pixels_per_unit) // max(1, chunks) if $scroll_x != 0 else 0

for i in range(chunks):
    scroll_event = Quartz.CGEventCreateScrollWheelEvent(
        None,
        Quartz.kCGScrollEventUnitPixel,
        1,  # 1 axis for simple vertical/horizontal
        pixel_per_chunk_y if pixel_per_chunk_y != 0 else pixel_per_chunk_x
    )
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, scroll_event)
    time.sleep(0.03)
PYEOF

    # Auto-read page after scroll when IN_APP is set
    auto_read_page
}

# Scroll within a specific app's window
# Usage: scroll_in_app <app> <direction> [amount]
# Automatically: finds app window, activates it, moves mouse to content area, scrolls
scroll_in_app() {
    local app="$1"
    local direction="$2"
    local amount="${3:-5}"

    if [[ -z "$app" || -z "$direction" ]]; then
        echo "ERROR: Usage: scroll_in_app <app> <direction> [amount]"
        return 1
    fi

    # Support named scroll presets
    case "$amount" in
        page)      amount=20 ;;
        half|half-page) amount=10 ;;
        little)    amount=3 ;;
        *)         ;;
    esac

    # Get window info for the app
    local where_output=$("$PYTHON" "$WINDOW_LIST" --app "$app" --where 2>&1)

    if echo "$where_output" | grep -q "No window found"; then
        echo "ERROR: No window found for app: $app"
        return 1
    fi

    # Parse display and bounds
    local app_display=$(echo "$where_output" | grep "^DISPLAY:" | sed 's/DISPLAY: //' | awk '{print $1}')
    local bounds=$(echo "$where_output" | grep "^BOUNDS:" | sed 's/BOUNDS: //')
    local center=$(echo "$where_output" | grep "^CENTER:" | sed 's/CENTER: //')

    if [[ -z "$bounds" ]]; then
        echo "ERROR: Could not get window bounds for: $app"
        return 1
    fi

    # Parse bounds: x,y,w,h
    IFS=',' read -r win_x win_y win_w win_h <<< "$bounds"

    # Calculate content area position (60% across, 50% down - avoids sidebars)
    local content_x=$((win_x + win_w * 60 / 100))
    local content_y=$((win_y + win_h * 50 / 100))

    echo "Scrolling $direction in $app (display $app_display)"

    # Activate the app
    activate_app "$app" > /dev/null 2>&1
    sleep 0.2

    # Move mouse to content area using Python (handles negative coords reliably)
    "$PYTHON" << PYEOF
import Quartz
move = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventMouseMoved, ($content_x, $content_y), 0)
Quartz.CGEventPost(Quartz.kCGHIDEventTap, move)
PYEOF
    sleep 0.1

    # Determine scroll direction
    local scroll_y=0
    case "$direction" in
        up)    scroll_y=$amount ;;
        down)  scroll_y=-$amount ;;
        *)
            echo "ERROR: Invalid scroll direction for scroll_in_app. Use: up, down"
            return 1
            ;;
    esac

    # Send scroll events
    "$PYTHON" << PYEOF
import Quartz
import time

pixels_per_unit = 30
total_pixels = $amount * pixels_per_unit
chunk_size = 50
chunks = max(1, abs(total_pixels) // chunk_size)
pixel_per_chunk = ($scroll_y * pixels_per_unit) // max(1, chunks)

for i in range(chunks):
    scroll_event = Quartz.CGEventCreateScrollWheelEvent(
        None,
        Quartz.kCGScrollEventUnitPixel,
        1,
        pixel_per_chunk
    )
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, scroll_event)
    time.sleep(0.03)
PYEOF

    # Auto-read page after scroll when IN_APP is set
    auto_read_page
}

# Click at current cursor position
click_here() {
    local click_type="${1:-c}"
    local pos=$(cliclick p 2>/dev/null)
    echo "Clicking at current position: $pos"
    if [[ "$click_type" == "tc" ]]; then
        # Triple-click: 3 rapid clicks (cliclick doesn't support tc natively)
        cliclick "c:." "c:." "c:."
    else
        cliclick "$click_type:."
    fi
}

# Verify position: move to grid coords and take crosshair screenshot
verify_position() {
    local coords="$1"
    local size="${2:-300}"

    # Restore target app if set (loads IN_APP from persistent state)
    restore_target_app

    # Use unified coordinate translation (handles IN_APP, REGION, ASPECT_CORRECT, bounding box)
    local pixels=$(grid_coords_to_pixel "$coords")
    if [[ -z "$pixels" ]]; then
        echo "ERROR: Invalid coordinates. Use format: x,y or x,y,w,h"
        return 1
    fi

    local pixel_x=$(echo "$pixels" | awk '{print $1}')
    local pixel_y=$(echo "$pixels" | awk '{print $2}')
    local cli_x=$(echo "$pixels" | awk '{print $3}')
    local cli_y=$(echo "$pixels" | awk '{print $4}')

    # Use triple-move pattern to make cursor position stick
    local nudge_x=$((pixel_x + 1))
    local cli_nudge_x="$nudge_x"
    [[ $nudge_x -lt 0 ]] && cli_nudge_x="=$nudge_x"

    cliclick "m:$cli_x,$cli_y" "m:$cli_nudge_x,$cli_y" "m:$cli_x,$cli_y"

    # Small delay to ensure cursor settles
    sleep 0.1

    # Take at-cursor screenshot (which now includes crosshairs)
    echo "Taking verification screenshot..."
    "$SCRIPT_DIR/screenshot.sh" --at-cursor "$size"
}

# Main
main() {
    if [[ $# -eq 0 ]]; then
        show_help
        exit 0
    fi

    check_cliclick

    # Initialize to main display by default
    get_main_display

    # Pre-scan for --instance to set INSTANCE_EXPLICIT early
    # This ensures --find-text works correctly regardless of argument order
    for arg in "$@"; do
        if [[ "$arg" == "--instance" ]]; then
            export INSTANCE_EXPLICIT=1
            break
        fi
    done

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --display)
                set_display "$2" || exit 1
                shift 2
                ;;
            --auto-wait-timeout)
                AUTO_WAIT_TIMEOUT="$2"
                shift 2
                ;;
            --list-displays)
                list_displays
                exit 0
                ;;
            --list-windows)
                list_windows
                exit 0
                ;;
            --where)
                where_app "$2"
                shift 2
                exit $?
                ;;
            --in-app)
                set_target_app "$2"
                shift 2
                ;;
            --clear-target)
                clear_target_app
                echo "Target app cleared"
                shift
                ;;
            --region)
                REGION="$2"
                shift 2
                ;;
            --clear-region)
                REGION=""
                shift
                ;;
            --show-cursor)
                show_cursor
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -s|--status)
                show_status
                exit 0
                ;;
            --double)
                CLICK_DOUBLE=1
                shift
                ;;
            --right)
                CLICK_RIGHT=1
                shift
                ;;
            --triple)
                CLICK_TRIPLE=1
                shift
                ;;
            --toggle)
                CLICK_TOGGLE=1
                shift
                ;;
            --info)
                CLICK_INFO=1
                shift
                ;;
            --click)
                # Check if next arg is a target or another flag
                if [[ -z "$2" || "$2" == -* ]]; then
                    unified_click ""  # No target = cursor click
                    shift
                else
                    unified_click "$2"
                    shift 2
                fi
                ;;
            --move)
                move_mouse "$2" "false"
                shift 2
                ;;
            --move-pixel)
                move_mouse "$2" "true"
                shift 2
                ;;
            --drag)
                drag_mouse "$2"
                shift 2
                ;;
            --drag-speed)
                case "$2" in
                    slow)
                        DRAG_DURATION=2.5
                        ;;
                    normal)
                        DRAG_DURATION=1.6
                        ;;
                    fast)
                        DRAG_DURATION=0.6
                        ;;
                    *)
                        echo "ERROR: --drag-speed must be slow, normal, or fast"
                        exit 1
                        ;;
                esac
                shift 2
                ;;
            --arc)
                # Parse position:tension format
                local arc_param="$2"
                if [[ "$arc_param" =~ ^(-?[0-9]+):(-?[0-9]+)$ ]]; then
                    ARC_POSITION="${BASH_REMATCH[1]}"
                    ARC_TENSION="${BASH_REMATCH[2]}"
                    # Validate position range (±1 to ±179)
                    local abs_pos=${ARC_POSITION#-}
                    if [[ $abs_pos -lt 1 || $abs_pos -gt 179 ]]; then
                        echo "ERROR: Arc position must be ±1 to ±179 (got $ARC_POSITION)"
                        exit 1
                    fi
                    echo "Arc: position=$ARC_POSITION tension=$ARC_TENSION"
                else
                    echo "ERROR: --arc requires format position:tension (e.g., 90:0, -90:100)"
                    exit 1
                fi
                shift 2
                ;;
            --drag-easing)
                case "$2" in
                    linear|ease-in|ease-out|ease-in-out)
                        DRAG_EASING="$2"
                        echo "Drag easing: $DRAG_EASING"
                        ;;
                    *)
                        echo "ERROR: --drag-easing must be linear, ease-in, ease-out, or ease-in-out"
                        exit 1
                        ;;
                esac
                shift 2
                ;;
            --drag-steps)
                if [[ "$2" =~ ^[0-9]+$ && "$2" -ge 10 && "$2" -le 500 ]]; then
                    DRAG_STEPS="$2"
                    echo "Drag steps: $DRAG_STEPS"
                else
                    echo "ERROR: --drag-steps must be a number between 10 and 500"
                    exit 1
                fi
                shift 2
                ;;
            --aspect)
                ASPECT_CORRECT="1"
                # Optional region argument (x1,y1,x2,y2)
                if [[ -n "$2" && "$2" =~ ^[0-9]+(\.[0-9]+)?,.*,.*,.*$ ]]; then
                    REGION="$2"
                    echo "Aspect correction: enabled (region $REGION)"
                    shift 2
                else
                    echo "Aspect correction: enabled (full window)"
                    shift
                fi
                ;;
            --type)
                local fast_flag=""
                [[ -n "$TYPE_FAST" ]] && fast_flag="--fast"
                type_text "$2" "$TYPE_DELAY" "$fast_flag"
                shift 2
                ;;
            --type-delay)
                TYPE_DELAY="$2"
                shift 2
                ;;
            --type-fast)
                TYPE_FAST=1
                shift
                ;;
            --key)
                local key="$2"
                # Check if third arg exists AND is a number (repeat count)
                if [[ -n "$3" && "$3" =~ ^[0-9]+$ ]]; then
                    local count="$3"
                    echo "Pressing key: $key ($count times)"
                    for ((i=1; i<=count; i++)); do
                        press_key "$key" > /dev/null  # Suppress individual echoes
                        sleep 0.05  # Small delay between rapid key presses
                    done
                    shift 3
                else
                    press_key "$key"
                    shift 2
                fi
                ;;
            --combo)
                key_combo "$2"
                shift 2
                ;;
            --open)
                open_app "$2"
                shift 2
                ;;
            --activate)
                activate_app "$2"
                shift 2
                ;;
            --hide)
                hide_app "$2"
                shift 2
                ;;
            --quit)
                quit_app "$2"
                shift 2
                ;;
            --browse)
                browse_url "$2" || exit 1
                shift 2
                ;;
            --wait)
                wait_ms "$2"
                shift 2
                ;;
            --wait-for-new-window)
                if [[ -n "$2" && "$2" != --* ]]; then
                    wait_for_new_window "$2"
                    shift 2
                else
                    wait_for_new_window
                    shift
                fi
                ;;
            --screen-size)
                show_screen_size
                shift
                ;;
            --mouse-pos)
                show_mouse_pos
                shift
                ;;
            --media-state)
                get_audio_state "text"
                echo ""
                get_now_playing "text"
                echo ""
                get_brightness "text"
                shift
                ;;
            --audio-state)
                get_audio_state "text"
                shift
                ;;
            --audio-state-json)
                get_audio_state "json"
                shift
                ;;
            --volume)
                set_volume "$2"
                shift 2
                ;;
            --mute)
                press_media_key "mute"
                shift
                ;;
            --unmute)
                local is_muted=$(osascript -e 'output muted of (get volume settings)' 2>/dev/null)
                if [[ "$is_muted" == "true" ]]; then
                    press_media_key "mute"
                    echo "Audio unmuted"
                else
                    echo "Audio already unmuted"
                fi
                shift
                ;;
            --now-playing)
                get_now_playing "text"
                shift
                ;;
            --now-playing-json)
                get_now_playing "json"
                shift
                ;;
            --brightness)
                get_brightness "text"
                shift
                ;;
            --brightness-json)
                get_brightness "json"
                shift
                ;;
            --clipboard)
                read_clipboard
                shift
                ;;
            --clipboard-type)
                get_clipboard_type
                shift
                ;;
            --copy-text)
                copy_text_to_clipboard "$2"
                shift 2
                ;;
            --copy-image)
                copy_image_to_clipboard "$2"
                shift 2
                ;;
            --copy-file)
                copy_file_to_clipboard "$2"
                shift 2
                ;;
            --wait-for-text)
                local wft_pattern="$2"
                local wft_condition="${3:-appear}"
                local wft_timeout="${4:-5000}"
                shift 2
                # Check for optional condition and timeout
                if [[ "$1" =~ ^(appear|gone)$ ]]; then
                    wft_condition="$1"
                    shift
                fi
                if [[ "$1" =~ ^[0-9]+$ ]]; then
                    wft_timeout="$1"
                    shift
                fi
                wait_for_text "$wft_pattern" "$wft_condition" "$wft_timeout" "$IN_APP"
                ;;
            --wait-for-change)
                local wfc_region=""
                local wfc_timeout="5000"
                shift
                # Check for optional region (x,y,w,h format)
                if [[ "$1" =~ ^[0-9]+,[0-9]+,[0-9]+,[0-9]+$ ]]; then
                    wfc_region="$1"
                    shift
                fi
                # Check for optional timeout
                if [[ "$1" =~ ^[0-9]+$ ]]; then
                    wfc_timeout="$1"
                    shift
                fi
                wait_for_change "$wfc_region" "$wfc_timeout"
                ;;
            --verify-text)
                local vt_pattern="$2"
                local vt_condition="${3:-present}"
                shift 2
                if [[ "$1" =~ ^(present|gone)$ ]]; then
                    vt_condition="$1"
                    shift
                fi
                verify_text "$vt_pattern" "$vt_condition" "$IN_APP"
                ;;
            --nudge)
                nudge_mouse "$2"
                shift 2
                ;;
            --scroll)
                local scroll_dir="$2"
                local scroll_amt="3"
                local scroll_pos=""
                shift 2
                # Check for optional amount (numeric or named preset)
                if [[ "$1" =~ ^[0-9]+$ || "$1" =~ ^(page|half|half-page|little)$ ]]; then
                    scroll_amt="$1"
                    shift
                fi
                # Check for optional position (contains comma)
                if [[ "$1" =~ , && ! "$1" =~ ^-- ]]; then
                    scroll_pos="$1"
                    shift
                fi
                scroll_at "$scroll_dir" "$scroll_amt" "$scroll_pos"
                ;;
            --scroll-in-app)
                local sia_app="$2"
                local sia_dir="$3"
                local sia_amt="${4:-5}"
                scroll_in_app "$sia_app" "$sia_dir" "$sia_amt"
                shift 3
                # Check for optional amount (numeric or named preset)
                if [[ "$1" =~ ^[0-9]+$ || "$1" =~ ^(page|half|half-page|little)$ ]]; then
                    shift
                fi
                ;;
            --find-text)
                coords=$(find_text_on_screen "$2" "${INSTANCE:-1}" "$DISPLAY_NUM")
                if [[ $? -eq 0 ]]; then
                    echo "Found '$2' at grid: $coords"
                fi
                shift 2
                ;;
            --list-text)
                list_screen_text "$DISPLAY_NUM"
                shift
                ;;
            --list-elements)
                if [[ -n "$2" && "$2" != --* ]]; then
                    list_elements "$2"
                    shift 2
                else
                    list_elements ""
                    shift
                fi
                ;;
            --read-page)
                local rp_app=""
                local rp_classify="false"
                local rp_json="false"
                local rp_save=""
                local rp_region=""
                local rp_aspect="false"
                shift  # shift past --read-page
                # Check if next arg is an app name (not a flag)
                if [[ $# -gt 0 && "$1" != --* ]]; then
                    rp_app="$1"
                    shift
                elif [[ -n "$IN_APP" ]]; then
                    # Fall back to --in-app target
                    rp_app="$IN_APP"
                else
                    echo "ERROR: --read-page requires an app name or --in-app to be set" >&2
                    exit 1
                fi
                # Parse optional flags
                while [[ $# -gt 0 ]]; do
                    case "$1" in
                        --classify) rp_classify="true"; shift ;;
                        --json) rp_json="true"; shift ;;
                        --save-screenshot) rp_save="$2"; shift 2 ;;
                        --no-images) DETECT_IMAGES=0; shift ;;
                        --no-icons) DETECT_ICONS=0; shift ;;
                        --region) rp_region="$2"; shift 2 ;;
                        --aspect) rp_aspect="true"; shift ;;
                        *) break ;;
                    esac
                done
                # Use global REGION if local not set
                [[ -z "$rp_region" && -n "$REGION" ]] && rp_region="$REGION"
                # Use global ASPECT_CORRECT if local not set
                [[ "$rp_aspect" == "false" && -n "$ASPECT_CORRECT" ]] && rp_aspect="true"
                read_page "$rp_app" "$rp_classify" "$rp_json" "$rp_save" "$rp_region" "$rp_aspect"
                ;;
            --instance)
                INSTANCE="$2"
                export INSTANCE_EXPLICIT=1
                shift 2
                ;;
            --near)
                NEAR_TEXT="$2"
                shift 2
                ;;
            --activate-before)
                ACTIVATE_APP="$2"
                shift 2
                ;;
            --chain)
                shift
                # Collect all remaining arguments as chain commands
                chain_cmds=()
                local chain_screenshot=""
                while [[ $# -gt 0 ]]; do
                    if [[ "$1" == "--screenshot" ]]; then
                        shift
                        # Check if next arg is a path (not another flag)
                        if [[ $# -gt 0 && "$1" != --* ]]; then
                            chain_screenshot="$1"
                            shift
                        else
                            # Auto-generate filename
                            chain_screenshot="auto"
                        fi
                        break
                    elif [[ "$1" == --* ]]; then
                        break
                    else
                        chain_cmds+=("$1")
                        shift
                    fi
                done
                run_chain "${chain_cmds[@]}"
                local chain_result=$?
                if [[ $chain_result -ne 0 ]]; then
                    echo "Chain failed with exit code $chain_result"
                    exit $chain_result
                fi
                # Take screenshot at end of chain if requested (only on success)
                if [[ -n "$chain_screenshot" ]]; then
                    sleep 0.3  # Brief delay for UI to settle
                    local screenshot_cmd="$SCREENSHOT"
                    if [[ -n "$IN_APP" ]]; then
                        screenshot_cmd="$screenshot_cmd --in-app $IN_APP"
                    fi
                    if [[ "$chain_screenshot" != "auto" ]]; then
                        screenshot_cmd="$screenshot_cmd --output $chain_screenshot"
                    fi
                    echo "Chain: Taking screenshot..."
                    $screenshot_cmd
                fi
                ;;
            --verify)
                local coords="$2"
                local size="300"
                if [[ -n "$3" && "$3" =~ ^[0-9]+$ ]]; then
                    size="$3"
                    verify_position "$coords" "$size"
                    shift 3
                else
                    verify_position "$coords" "$size"
                    shift 2
                fi
                ;;
            *)
                echo "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

main "$@"
