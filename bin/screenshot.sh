#!/bin/bash
# Desktop screenshot utility for Claude vision capabilities
# Captures full screen, windows, or regions for visual analysis

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PYTHON="$PROJECT_ROOT/venv/bin/python"
LIB_DIR="$PROJECT_ROOT/lib"
WINDOW_LIST="$LIB_DIR/window_list.py"
GRID_OVERLAY="$LIB_DIR/grid_overlay.py"

# Default settings
FORMAT="jpg"
OUTPUT_DIR="/tmp"
INCLUDE_CURSOR=""

# Generate timestamped filename
generate_filename() {
    local prefix="${1:-screenshot}"
    local ext="${2:-$FORMAT}"
    echo "${OUTPUT_DIR}/${prefix}_$(date +%Y%m%d_%H%M%S).${ext}"
}

# Check for Screen Recording permission
check_permission() {
    # Try a quick capture to /dev/null
    local test_file="/tmp/screenshot_permission_test_$$.png"
    screencapture -x "$test_file" 2>/dev/null
    if [[ ! -f "$test_file" ]]; then
        echo "ERROR: Screen Recording permission required."
        echo ""
        echo "To enable:"
        echo "  1. Open System Settings"
        echo "  2. Go to Privacy & Security > Screen Recording"
        echo "  3. Enable access for Terminal (or your terminal app)"
        echo "  4. Restart the terminal if needed"
        return 1
    fi
    rm -f "$test_file"
    return 0
}

# Show status of dependencies and permissions
show_status() {
    echo "=== screenshot.sh Status ==="
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

    # Pillow (for grid overlay)
    if [[ -f "$PYTHON" ]] && "$PYTHON" -c "import PIL" 2>/dev/null; then
        local pil_version=$("$PYTHON" -c "import PIL; print(PIL.__version__)" 2>/dev/null)
        echo "  [OK] Pillow $pil_version (image processing)"
    else
        echo "  [MISSING] Pillow - Run: ./setup.sh"
        all_ok=false
    fi

    # pyobjc-framework-Quartz (for window list, display info)
    if [[ -f "$PYTHON" ]] && "$PYTHON" -c "import Quartz" 2>/dev/null; then
        echo "  [OK] pyobjc-framework-Quartz (window/display info)"
    else
        echo "  [MISSING] pyobjc-framework-Quartz - Run: ./setup.sh"
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

    echo ""
    if $all_ok; then
        echo "Status: All checks passed"
    else
        echo "Status: Issues detected (see above)"
    fi
}

# Get display information using Python
get_display_info() {
    "$PYTHON" << 'PYEOF'
import Quartz

max_displays = 10
(err, active_displays, num_displays) = Quartz.CGGetActiveDisplayList(max_displays, None, None)

if err == 0 and num_displays > 0:
    for i, display_id in enumerate(active_displays[:num_displays]):
        bounds = Quartz.CGDisplayBounds(display_id)
        main = Quartz.CGDisplayIsMain(display_id)
        print(f"Display {i+1}: {int(bounds.size.width)}x{int(bounds.size.height)} at ({int(bounds.origin.x)},{int(bounds.origin.y)}){' [MAIN]' if main else ''}")
else:
    print("Could not get display info")
PYEOF
}

# Show help
show_help() {
    cat << 'EOF'
Desktop Screenshot Utility

USAGE:
    screenshot.sh [OPTIONS]

CAPTURE MODES:
    (default)               Capture main display
    --display <n>           Capture specific display (1, 2, etc.)
    --all                   Capture all displays (separate files)
    --window                Interactive window picker (click to select)
    --in-app <name>         Capture window of named application
    --region                Interactive rectangular selection (drag to select)
    --region <x,y,w,h>      Capture specific coordinates
    --at-cursor [size]      Capture region centered on cursor (default: 400px)

OPTIONS:
    -h, --help              Show this help message
    -s, --status            Check dependencies and permissions
    --output <file>         Custom output filename
    --format <jpg|png>      Output format (default: jpg)
    --cursor                Include mouse cursor in capture
    --grid [file]           Add grid overlay (to latest or specified file)
    --preview <x>,<y>       Screenshot display and show where click at x%,y% would land
                            (crosshairs overlay without moving cursor)
    --list-windows          List available windows with IDs
    --list-displays         List all displays with resolutions and offsets

EXAMPLES:
    ./screenshot.sh                      # Full screen capture
    ./screenshot.sh --display 2          # Capture second display
    ./screenshot.sh --window             # Click to select a window
    ./screenshot.sh --in-app Safari      # Capture Safari window
    ./screenshot.sh --region             # Drag to select area
    ./screenshot.sh --region 100,100,800,600  # Specific region
    ./screenshot.sh --grid               # Add grid to latest screenshot
    ./screenshot.sh --preview 54,64      # Show where click at 54%,64% would land
    ./screenshot.sh --display 2 --preview 54,64  # Preview click position on display 2
    ./screenshot.sh --list-windows       # Show available windows
    ./screenshot.sh --list-displays      # Show display info for coordinate mapping

OUTPUT:
    Screenshots saved as: screenshot_YYYYMMDD_HHMMSS.jpg
    Grid overlays saved as: screenshot_YYYYMMDD_HHMMSS_grid.jpg

COORDINATE MAPPING:
    Use --list-displays to see display offsets for multi-monitor setups.
    Negative X coordinates indicate displays to the left of the main display.
EOF
}

# List windows
list_windows() {
    if [[ ! -f "$WINDOW_LIST" ]]; then
        echo "ERROR: window_list.py not found at $WINDOW_LIST"
        return 1
    fi
    "$PYTHON" "$WINDOW_LIST" "$@"
}

# Find latest screenshot
find_latest_screenshot() {
    ls -t "$OUTPUT_DIR"/screenshot_*.{jpg,png} 2>/dev/null | grep -v '_grid\.' | head -1
}

# Add grid overlay
add_grid() {
    local file="$1"
    if [[ -z "$file" ]]; then
        file=$(find_latest_screenshot)
        if [[ -z "$file" ]]; then
            echo "ERROR: No screenshot found to add grid overlay"
            return 1
        fi
    fi

    if [[ ! -f "$file" ]]; then
        echo "ERROR: File not found: $file"
        return 1
    fi

    if [[ ! -f "$GRID_OVERLAY" ]]; then
        echo "ERROR: grid_overlay.py not found at $GRID_OVERLAY"
        return 1
    fi

    "$PYTHON" "$GRID_OVERLAY" "$file"
}

# Capture full screen
capture_fullscreen() {
    local display="$1"
    local custom_out="$2"
    local output="${custom_out:-$(generate_filename)}"

    local cmd="screencapture -x"
    [[ -n "$INCLUDE_CURSOR" ]] && cmd="$cmd -C"
    [[ -n "$display" ]] && cmd="$cmd -D $display"

    $cmd "$output"

    if [[ -f "$output" ]]; then
        echo "Screenshot saved: $output"
        echo "$output"
    else
        echo "ERROR: Failed to capture screenshot"
        return 1
    fi
}

# Capture all displays
capture_all_displays() {
    local base=$(generate_filename "screenshot" "")
    base="${base%.*}"  # Remove extension

    local cmd="screencapture -x"
    [[ -n "$INCLUDE_CURSOR" ]] && cmd="$cmd -C"

    # Get number of displays using system_profiler
    local num_displays=$(system_profiler SPDisplaysDataType 2>/dev/null | grep -c "Resolution:")

    if [[ "$num_displays" -lt 2 ]]; then
        echo "Only one display detected, capturing main display..."
        capture_fullscreen
        return
    fi

    local files=""
    for i in $(seq 1 $num_displays); do
        local output="${base}_display${i}.${FORMAT}"
        $cmd -D $i "$output"
        if [[ -f "$output" ]]; then
            files="$files $output"
            echo "Display $i saved: $output"
        fi
    done

    if [[ -n "$files" ]]; then
        echo "All displays captured:$files"
    fi
}

# Interactive window capture
capture_window_interactive() {
    local output=$(generate_filename)

    local cmd="screencapture -x -w"
    [[ -n "$INCLUDE_CURSOR" ]] && cmd="$cmd -C"

    echo "Click on the window you want to capture..."
    $cmd "$output"

    if [[ -f "$output" ]]; then
        echo "Screenshot saved: $output"
        echo "$output"
    else
        echo "Capture cancelled or failed"
        return 1
    fi
}

# Capture window by app name
capture_app_window() {
    local app_name="$1"
    local custom_out="$2"

    if [[ -z "$app_name" ]]; then
        echo "ERROR: App name required"
        return 1
    fi

    # Get window ID for the app
    local window_id=$("$PYTHON" "$WINDOW_LIST" --app "$app_name" --id-only 2>/dev/null)

    if [[ -z "$window_id" ]]; then
        echo "ERROR: No window found for app: $app_name"
        echo ""
        echo "Available windows:"
        list_windows
        return 1
    fi

    local output="${custom_out:-$(generate_filename)}"

    # -o removes window shadow for cleaner capture and better OCR
    local cmd="screencapture -x -o -l $window_id"
    [[ -n "$INCLUDE_CURSOR" ]] && cmd="$cmd -C"

    $cmd "$output"

    if [[ -f "$output" ]]; then
        echo "Screenshot saved: $output"
        echo "$output"
    else
        echo "ERROR: Failed to capture window"
        return 1
    fi
}

# Interactive region capture
capture_region_interactive() {
    local output=$(generate_filename)

    local cmd="screencapture -x -s"
    [[ -n "$INCLUDE_CURSOR" ]] && cmd="$cmd -C"

    echo "Drag to select the region you want to capture..."
    $cmd "$output"

    if [[ -f "$output" ]]; then
        echo "Screenshot saved: $output"
        echo "$output"
    else
        echo "Capture cancelled or failed"
        return 1
    fi
}

# Coordinate-based region capture
capture_region_coords() {
    local coords="$1"

    # Parse coordinates (x,y,w,h)
    IFS=',' read -r x y w h <<< "$coords"

    if [[ -z "$x" || -z "$y" || -z "$w" || -z "$h" ]]; then
        echo "ERROR: Invalid coordinates. Use format: x,y,width,height"
        echo "Example: --region 100,100,800,600"
        return 1
    fi

    local output=$(generate_filename)

    local cmd="screencapture -x -R ${x},${y},${w},${h}"
    [[ -n "$INCLUDE_CURSOR" ]] && cmd="$cmd -C"

    $cmd "$output"

    if [[ -f "$output" ]]; then
        echo "Screenshot saved: $output"
        echo "$output"
    else
        echo "ERROR: Failed to capture region"
        return 1
    fi
}

# Preview where a click would land (screenshot with crosshairs at specified position)
preview_click() {
    local coords="$1"
    local display="$2"

    IFS=',' read -r grid_x grid_y <<< "$coords"

    if [[ -z "$grid_x" || -z "$grid_y" ]]; then
        echo "ERROR: Invalid coordinates. Use format: x,y (e.g., 54,64)"
        return 1
    fi

    echo "Previewing click at grid position ($grid_x%, $grid_y%)"

    # Capture the display
    local output=$(generate_filename "preview")

    local cmd="screencapture -x"
    [[ -n "$INCLUDE_CURSOR" ]] && cmd="$cmd -C"
    [[ -n "$display" ]] && cmd="$cmd -D $display"

    $cmd "$output"

    if [[ ! -f "$output" ]]; then
        echo "ERROR: Failed to capture screenshot"
        return 1
    fi

    # Add crosshairs at the grid position
    "$PYTHON" "$GRID_OVERLAY" --crosshairs-grid "$grid_x,$grid_y" "$output" "$output"

    echo "Preview saved: $output"
    echo "$output"
}

# Capture region centered on current cursor position
# Automatically adds crosshairs to show exact click point
capture_at_cursor() {
    local size="${1:-400}"  # Default 400x400 box

    # Get current mouse position using cliclick
    local pos=$(cliclick p 2>/dev/null)
    if [[ -z "$pos" ]]; then
        echo "ERROR: Could not get cursor position (is cliclick installed?)"
        return 1
    fi

    local cursor_x=$(echo "$pos" | cut -d',' -f1)
    local cursor_y=$(echo "$pos" | cut -d',' -f2)

    # Calculate top-left corner of capture region (centered on cursor)
    local half=$((size / 2))
    local x=$((cursor_x - half))
    local y=$((cursor_y - half))

    # Ensure non-negative (screencapture handles screen bounds)
    [[ $x -lt -5000 ]] && x=-5000  # Allow for left monitors
    [[ $y -lt 0 ]] && y=0

    echo "Cursor at: $cursor_x, $cursor_y"
    echo "Capturing ${size}x${size} region centered on cursor..."

    local output=$(generate_filename "cursor_region")

    # Always include cursor for this mode
    local cmd="screencapture -x -C -R ${x},${y},${size},${size}"

    $cmd "$output"

    if [[ -f "$output" ]]; then
        # Add crosshairs to show exact click point
        "$PYTHON" "$GRID_OVERLAY" --crosshairs "$output" "$output"
        echo "Screenshot saved: $output"
        echo "$output"
    else
        echo "ERROR: Failed to capture region"
        return 1
    fi
}

# Main argument parsing
main() {
    # Check for help/status first (before permission check)
    for arg in "$@"; do
        if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
            show_help
            exit 0
        fi
        if [[ "$arg" == "--status" || "$arg" == "-s" ]]; then
            show_status
            exit 0
        fi
    done

    # Check permission (skip for non-capture operations)
    local needs_permission=true
    for arg in "$@"; do
        if [[ "$arg" == "--list-windows" || "$arg" == "--list-displays" ]]; then
            needs_permission=false
            break
        fi
    done
    if $needs_permission; then
        check_permission || exit 1
    fi

    local mode="fullscreen"
    local display=""
    local app_name=""
    local coords=""
    local cursor_size="400"
    local custom_output=""
    local grid_file=""
    local do_grid=false
    local preview_coords=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            --display)
                mode="display"
                display="$2"
                shift 2
                ;;
            --all)
                mode="all"
                shift
                ;;
            --window)
                mode="window"
                shift
                ;;
            --in-app)
                mode="app"
                app_name="$2"
                shift 2
                ;;
            --region)
                if [[ -n "$2" && "$2" != --* ]]; then
                    mode="region_coords"
                    coords="$2"
                    shift 2
                else
                    mode="region"
                    shift
                fi
                ;;
            --at-cursor)
                mode="at_cursor"
                if [[ -n "$2" && "$2" != --* && "$2" =~ ^[0-9]+$ ]]; then
                    cursor_size="$2"
                    shift 2
                else
                    cursor_size="400"
                    shift
                fi
                ;;
            --list-windows)
                list_windows
                exit 0
                ;;
            --list-displays)
                get_display_info
                exit 0
                ;;
            --output)
                custom_output="$2"
                shift 2
                ;;
            --format)
                FORMAT="$2"
                shift 2
                ;;
            --cursor)
                INCLUDE_CURSOR="1"
                shift
                ;;
            --grid)
                do_grid=true
                if [[ -n "$2" && "$2" != --* ]]; then
                    grid_file="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            --preview)
                mode="preview"
                preview_coords="$2"
                shift 2
                ;;
            *)
                echo "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # If only --grid was specified, add grid to file and exit
    if [[ "$do_grid" == true && "$mode" == "fullscreen" && -z "$custom_output" ]]; then
        add_grid "$grid_file"
        exit $?
    fi

    # Execute capture
    case "$mode" in
        fullscreen)
            capture_fullscreen "$display" "$custom_output"
            ;;
        display)
            capture_fullscreen "$display" "$custom_output"
            ;;
        all)
            capture_all_displays
            ;;
        window)
            capture_window_interactive
            ;;
        app)
            capture_app_window "$app_name" "$custom_output"
            ;;
        region)
            capture_region_interactive
            ;;
        region_coords)
            capture_region_coords "$coords"
            ;;
        at_cursor)
            capture_at_cursor "$cursor_size"
            ;;
        preview)
            preview_click "$preview_coords" "$display"
            ;;
    esac

    local result=$?

    # Add grid overlay if requested
    if [[ "$do_grid" == true && $result -eq 0 ]]; then
        # Get the output file from the capture function
        local latest=$(find_latest_screenshot)
        add_grid "$latest"
    fi

    return $result
}

main "$@"
