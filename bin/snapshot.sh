#!/bin/bash
# snapshot.sh - Capture webcam snapshots with PTZ control for Insta360 Link 2
#
# Usage:
#   ./snapshot.sh [--list]              List available video devices
#   ./snapshot.sh [device]              Capture snapshot (default device 0)
#   ./snapshot.sh --snap [device]       Explicit snapshot capture
#   ./snapshot.sh --status              Show current camera position
#   ./snapshot.sh --center              Center the camera (pan=0, tilt=0)
#   ./snapshot.sh --pan <degrees>       Set pan angle (-145 to +145)
#   ./snapshot.sh --tilt <degrees>      Set tilt angle (-90 to +100)
#   ./snapshot.sh --zoom <level>        Set zoom (1.0 to 4.0)
#   ./snapshot.sh --look <pan> <tilt>   Set pan and tilt together
#   ./snapshot.sh --reset               Reset to center with 1x zoom

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PYTHON="$PROJECT_ROOT/venv/bin/python"
LIB_DIR="$PROJECT_ROOT/lib"
OUTPUT_DIR="/tmp"

# Insta360 Link 2 UVC identifiers
VENDOR=11802
PRODUCT=19460

# Conversion: 1 degree = 3600 arc seconds
ARC_PER_DEG=3600

# Calibration offsets for "center" position (looking at user)
# These are the raw arc-second values where the camera looks straight at the user
CENTER_PAN=81000      # 22.5 degrees
CENTER_TILT=-14400    # -4 degrees

# Check for required tools
check_ffmpeg() {
    if ! command -v ffmpeg &> /dev/null; then
        echo "ERROR: ffmpeg is not installed."
        echo "Install with: brew install ffmpeg"
        exit 1
    fi
}

check_uvcc() {
    if ! command -v uvcc &> /dev/null; then
        echo "ERROR: uvcc is not installed."
        echo "Install with: npm install -g uvcc"
        exit 1
    fi
}

# Convert degrees to arc seconds
deg_to_arc() {
    echo $(( $1 * ARC_PER_DEG ))
}

# Convert arc seconds to degrees (for display)
arc_to_deg() {
    echo "scale=1; $1 / $ARC_PER_DEG" | bc
}

# Get current camera position
get_status() {
    check_uvcc
    local json=$(uvcc export --vendor $VENDOR --product $PRODUCT 2>/dev/null)

    local pan_arc=$(echo "$json" | jq '.absolute_pan_tilt[0]')
    local tilt_arc=$(echo "$json" | jq '.absolute_pan_tilt[1]')
    local zoom=$(echo "$json" | jq '.absolute_zoom')

    local pan_deg=$(arc_to_deg $pan_arc)
    local tilt_deg=$(arc_to_deg $tilt_arc)
    local zoom_x=$(echo "scale=1; $zoom / 100" | bc)

    echo "Camera Position:"
    echo "  Pan:  ${pan_deg}°"
    echo "  Tilt: ${tilt_deg}°"
    echo "  Zoom: ${zoom_x}x"
}

# Get raw position (for calibration)
get_position_raw() {
    check_uvcc
    local json=$(uvcc export --vendor $VENDOR --product $PRODUCT 2>/dev/null)
    echo "$json" | jq '{pan: .absolute_pan_tilt[0], tilt: .absolute_pan_tilt[1], zoom: .absolute_zoom}'
}

# Set pan angle (degrees)
set_pan() {
    check_uvcc
    local deg=$1

    # Clamp to valid range
    if (( deg < -145 )); then deg=-145; fi
    if (( deg > 145 )); then deg=145; fi

    # Get current tilt
    local json=$(uvcc export --vendor $VENDOR --product $PRODUCT 2>/dev/null)
    local tilt_arc=$(echo "$json" | jq '.absolute_pan_tilt[1]')

    local pan_arc=$(deg_to_arc $deg)

    uvcc set absolute_pan_tilt $pan_arc $tilt_arc --vendor $VENDOR --product $PRODUCT 2>/dev/null
    echo "Pan set to ${deg}°"
}

# Set tilt angle (degrees)
set_tilt() {
    check_uvcc
    local deg=$1

    # Clamp to valid range
    if (( deg < -90 )); then deg=-90; fi
    if (( deg > 100 )); then deg=100; fi

    # Get current pan
    local json=$(uvcc export --vendor $VENDOR --product $PRODUCT 2>/dev/null)
    local pan_arc=$(echo "$json" | jq '.absolute_pan_tilt[0]')

    local tilt_arc=$(deg_to_arc $deg)

    uvcc set absolute_pan_tilt $pan_arc $tilt_arc --vendor $VENDOR --product $PRODUCT 2>/dev/null
    echo "Tilt set to ${deg}°"
}

# Set both pan and tilt (degrees) - supports decimals
set_look() {
    check_uvcc
    local pan_deg=$1
    local tilt_deg=$2

    # Clamp to valid ranges (using bc for decimal support)
    pan_deg=$(echo "$pan_deg" | awk '{if($1<-145)print -145; else if($1>145)print 145; else print $1}')
    tilt_deg=$(echo "$tilt_deg" | awk '{if($1<-90)print -90; else if($1>100)print 100; else print $1}')

    # Convert to arc seconds (multiply by 3600, truncate to int)
    local pan_arc=$(echo "scale=0; $pan_deg * 3600 / 1" | bc)
    local tilt_arc=$(echo "scale=0; $tilt_deg * 3600 / 1" | bc)

    uvcc set absolute_pan_tilt $pan_arc $tilt_arc --vendor $VENDOR --product $PRODUCT 2>/dev/null
    echo "Looking at pan=${pan_deg}°, tilt=${tilt_deg}°"
}

# Set zoom level (1.0 to 4.0)
set_zoom() {
    check_uvcc
    local level=$1

    # Convert to percentage (1.0 = 100, 4.0 = 400)
    local zoom_pct=$(echo "scale=0; $level * 100 / 1" | bc)

    # Clamp to valid range
    if (( zoom_pct < 100 )); then zoom_pct=100; fi
    if (( zoom_pct > 400 )); then zoom_pct=400; fi

    uvcc set absolute_zoom $zoom_pct --vendor $VENDOR --product $PRODUCT 2>/dev/null
    local zoom_x=$(echo "scale=1; $zoom_pct / 100" | bc)
    echo "Zoom set to ${zoom_x}x"
}

# Center the camera (using calibration offsets, reset zoom to 1x)
center_camera() {
    check_uvcc
    uvcc set absolute_pan_tilt $CENTER_PAN $CENTER_TILT --vendor $VENDOR --product $PRODUCT 2>/dev/null
    uvcc set absolute_zoom 100 --vendor $VENDOR --product $PRODUCT 2>/dev/null
    echo "Camera centered (looking at user, 1x zoom)"
}

# Reset camera to default position (using calibration offsets)
reset_camera() {
    check_uvcc
    uvcc set absolute_pan_tilt $CENTER_PAN $CENTER_TILT --vendor $VENDOR --product $PRODUCT 2>/dev/null
    uvcc set absolute_zoom 100 --vendor $VENDOR --product $PRODUCT 2>/dev/null
    echo "Camera reset to center with 1x zoom"
}

# Add grid overlay to an image
add_grid_overlay() {
    local input_file=$1
    local output_file="${input_file%.*}_grid.${input_file##*.}"

    if [[ ! -f "$PYTHON" ]]; then
        echo "ERROR: Python venv not found. Run: cd $PROJECT_ROOT && ./setup.sh"
        return 1
    fi

    "$PYTHON" "${LIB_DIR}/grid_overlay.py" "$input_file" "$output_file"
    echo ""
    echo "Use grid to estimate bounding box: --calc-frame <left%> <top%> <right%> <bottom%>"
}

# Generate grid overlay for most recent snapshot
show_grid() {
    # Find most recent snapshot
    local latest=$(ls -t "${OUTPUT_DIR}"/snapshot_*.jpg 2>/dev/null | grep -v "_grid" | head -1)

    if [[ -z "$latest" ]]; then
        echo "No snapshots found. Take a snapshot first with: ./snapshot.sh"
        return 1
    fi

    echo "Adding grid to: $latest"
    add_grid_overlay "$latest"
}

# List available video devices
list_devices() {
    check_ffmpeg
    echo "Available video devices:"
    ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -E "^\[AVFoundation.*\] \[[0-9]+\]" | grep -v "Microphone\|audio"
}

# Capture snapshot
capture_snapshot() {
    check_ffmpeg
    local device="${1:-0}"

    # Generate timestamped filename
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local output_file="${OUTPUT_DIR}/snapshot_${timestamp}.jpg"

    echo "Capturing from device ${device}..."

    # Small delay to let camera settle after PTZ movement
    sleep 0.3

    # Capture single frame
    ffmpeg -f avfoundation -framerate 30 -i "${device}" -frames:v 1 -y "${output_file}" 2>/dev/null

    if [[ $? -eq 0 && -f "${output_file}" ]]; then
        echo ""
        echo "Snapshot saved: ${output_file}"
        echo ""
        echo "Ask Claude to analyze it:"
        echo "  Please analyze this image: ${output_file}"
    else
        echo "ERROR: Failed to capture snapshot from device ${device}"
        echo "Try './snapshot.sh --list' to see available devices"
        exit 1
    fi
}

# Calculate pan/tilt adjustment from object position in frame
# Usage: calc_adjustment <x_percent> <y_percent> <current_zoom>
# x_percent: 0=left edge, 50=center, 100=right edge
# y_percent: 0=top edge, 50=center, 100=bottom edge
# Returns suggested pan/tilt deltas to center the object
calc_adjustment() {
    local x_pct=$1
    local y_pct=$2
    local zoom=${3:-100}

    # Field of view at 1x zoom (calibrated from testing)
    # Horizontal: ~50° (measured: 17.5° pan for 35% offset)
    # Vertical: ~46° (measured: 11.5° tilt for 25% offset)
    # At higher zoom, FOV shrinks proportionally
    local base_hfov=50
    local base_vfov=46

    local hfov=$(echo "scale=2; $base_hfov * 100 / $zoom" | bc)
    local vfov=$(echo "scale=2; $base_vfov * 100 / $zoom" | bc)

    # Calculate offset from center (50%)
    local x_offset=$(echo "scale=2; $x_pct - 50" | bc)
    local y_offset=$(echo "scale=2; $y_pct - 50" | bc)

    # Convert percentage offset to degrees
    # Positive x_offset means object is right of center -> need positive pan
    # Positive y_offset means object is below center -> need negative tilt
    local pan_delta=$(echo "scale=1; $x_offset * $hfov / 100" | bc)
    local tilt_delta=$(echo "scale=1; -1 * $y_offset * $vfov / 100" | bc)

    echo "Object position: ${x_pct}% from left, ${y_pct}% from top"
    echo "Current zoom: ${zoom}% ($(echo "scale=1; $zoom/100" | bc)x)"
    echo "Effective FOV: ${hfov}° x ${vfov}°"
    echo ""
    echo "To center this object, adjust by:"
    echo "  Pan:  ${pan_delta}°"
    echo "  Tilt: ${tilt_delta}°"
}

# Calculate framing from object bounding box
# Usage: calc_frame <left%> <top%> <right%> <bottom%> [margin%]
# More accurate than center-point estimation - specify where object edges are
# margin%: extra space around object (default 10%)
calc_frame() {
    local left=$1
    local top=$2
    local right=$3
    local bottom=$4
    local margin=${5:-10}

    # Calculate object center
    local center_x=$(echo "scale=1; ($left + $right) / 2" | bc)
    local center_y=$(echo "scale=1; ($top + $bottom) / 2" | bc)

    # Calculate object size
    local obj_width=$(echo "scale=1; $right - $left" | bc)
    local obj_height=$(echo "scale=1; $bottom - $top" | bc)

    # Target size (with margin)
    local target_pct=$(echo "scale=0; 100 - (2 * $margin)" | bc)

    # Calculate zoom based on larger dimension (to fit object)
    # Aspect ratio of frame is roughly 16:9, so width has more room
    local zoom_for_height=$(echo "scale=0; $target_pct * 100 / $obj_height" | bc)
    local zoom_for_width=$(echo "scale=0; $target_pct * 100 / $obj_width * 16 / 9" | bc)

    # Use the smaller zoom to ensure object fits
    local new_zoom=$zoom_for_height
    if [ "$zoom_for_width" -lt "$zoom_for_height" ]; then
        new_zoom=$zoom_for_width
    fi

    # Clamp zoom
    if [ "$new_zoom" -lt 100 ]; then new_zoom=100; fi
    if [ "$new_zoom" -gt 400 ]; then new_zoom=400; fi

    # Calculate pan/tilt adjustment (at 1x zoom FOV)
    local base_hfov=50
    local base_vfov=46

    local x_offset=$(echo "scale=2; $center_x - 50" | bc)
    local y_offset=$(echo "scale=2; $center_y - 50" | bc)

    local pan_delta=$(echo "scale=1; $x_offset * $base_hfov / 100" | bc)
    local tilt_delta=$(echo "scale=1; -1 * $y_offset * $base_vfov / 100" | bc)

    # Get current position (assumes we're at calibrated center)
    local new_pan=$(echo "scale=1; 22.5 + $pan_delta" | bc)
    local new_tilt=$(echo "scale=1; -4 + $tilt_delta" | bc)
    local new_zoom_x=$(echo "scale=1; $new_zoom / 100" | bc)

    # Round for cleaner command output
    local pan_rounded=$(printf "%.0f" "$new_pan")
    local tilt_rounded=$(printf "%.0f" "$new_tilt")

    echo "Object bounding box: (${left}%, ${top}%) to (${right}%, ${bottom}%)"
    echo "Object center: ${center_x}%, ${center_y}%"
    echo "Object size: ${obj_width}% x ${obj_height}%"
    echo "Target fill: ${target_pct}% (with ${margin}% margin)"
    echo ""
    echo "Recommended settings (from center position):"
    echo "  Pan:  ${new_pan}° (rounded: ${pan_rounded}°)"
    echo "  Tilt: ${new_tilt}° (rounded: ${tilt_rounded}°)"
    echo "  Zoom: ${new_zoom_x}x"
    echo ""
    echo "Command:"
    echo "  ./snapshot.sh --look ${pan_rounded} ${tilt_rounded} && ./snapshot.sh --zoom ${new_zoom_x}"
}

# Calculate correction from current framing error
# Usage: calc-correct <current_x%> <current_y%> <current_zoom>
# Use when object is visible but not centered - specify where it currently appears
# Example: object appears at 60% from left (right of center) -> need to pan right
calc_correct() {
    local current_x=$1
    local current_y=$2
    local current_zoom=${3:-100}

    # FOV at current zoom
    local base_hfov=50
    local base_vfov=46
    local hfov=$(echo "scale=2; $base_hfov * 100 / $current_zoom" | bc)
    local vfov=$(echo "scale=2; $base_vfov * 100 / $current_zoom" | bc)

    # How far from center (50%) is the object?
    local x_error=$(echo "scale=2; $current_x - 50" | bc)
    local y_error=$(echo "scale=2; $current_y - 50" | bc)

    # Convert to degrees
    local pan_correction=$(echo "scale=1; $x_error * $hfov / 100" | bc)
    local tilt_correction=$(echo "scale=1; -1 * $y_error * $vfov / 100" | bc)

    echo "Object currently at: ${current_x}% from left, ${current_y}% from top"
    echo "Current zoom: $(echo "scale=1; $current_zoom/100" | bc)x (FOV: ${hfov}° x ${vfov}°)"
    echo "Error from center: X=${x_error}%, Y=${y_error}%"
    echo ""
    echo "To center, ADJUST current position by:"
    echo "  Pan:  ${pan_correction}° (add to current pan)"
    echo "  Tilt: ${tilt_correction}° (add to current tilt)"
}

# Calculate zoom needed to fill frame with object
# Usage: calc_zoom <object_height_percent> <target_height_percent> <current_zoom>
calc_zoom() {
    local obj_pct=$1
    local target_pct=${2:-80}
    local current_zoom=${3:-100}

    # Calculate zoom multiplier needed
    local zoom_mult=$(echo "scale=2; $target_pct / $obj_pct" | bc)
    local new_zoom=$(echo "scale=0; $current_zoom * $zoom_mult / 1" | bc)

    # Clamp to valid range
    if [ "$new_zoom" -lt 100 ]; then new_zoom=100; fi
    if [ "$new_zoom" -gt 400 ]; then new_zoom=400; fi

    local new_zoom_x=$(echo "scale=1; $new_zoom / 100" | bc)

    echo "Object currently takes ${obj_pct}% of frame height"
    echo "Target: ${target_pct}% of frame height"
    echo "Current zoom: $(echo "scale=1; $current_zoom/100" | bc)x"
    echo ""
    echo "Recommended zoom: ${new_zoom_x}x (${new_zoom}%)"
}

# Show help
show_help() {
    echo "snapshot.sh - Webcam capture with PTZ control for Insta360 Link 2"
    echo ""
    echo "Capture Commands:"
    echo "  ./snapshot.sh [device]              Capture snapshot (default device 0)"
    echo "  ./snapshot.sh --snap [device]       Explicit snapshot capture"
    echo "  ./snapshot.sh --list-devices        List available video devices (--list also works)"
    echo ""
    echo "PTZ Control (Insta360 Link 2):"
    echo "  ./snapshot.sh --ptz                 Show current camera position"
    echo "  ./snapshot.sh --position            Show raw position (for calibration)"
    echo "  ./snapshot.sh --center              Center camera (look at user)"
    echo "  ./snapshot.sh --reset               Reset to center with 1x zoom"
    echo "  ./snapshot.sh --pan <degrees>       Set pan (-145 to +145)"
    echo "  ./snapshot.sh --tilt <degrees>      Set tilt (-90 to +100)"
    echo "  ./snapshot.sh --zoom <level>        Set zoom (1.0 to 4.0)"
    echo "  ./snapshot.sh --look <pan> <tilt>   Set pan and tilt together"
    echo ""
    echo "Calculation Helpers (for LLM navigation):"
    echo "  ./snapshot.sh --calc-frame <left%> <top%> <right%> <bottom%> [margin%]"
    echo "                                      RECOMMENDED: Calculate framing from bounding box"
    echo "                                      Outputs pan, tilt, zoom for one-shot framing"
    echo "  ./snapshot.sh --calc-adjust <x%> <y%> [zoom%]"
    echo "                                      Calculate pan/tilt to center object"
    echo "                                      x%: 0=left, 50=center, 100=right"
    echo "                                      y%: 0=top, 50=center, 100=bottom"
    echo "  ./snapshot.sh --calc-zoom <obj%> [target%] [zoom%]"
    echo "                                      Calculate zoom for object height"
    echo ""
    echo "Examples:"
    echo "  ./snapshot.sh                       # Take snapshot"
    echo "  ./snapshot.sh --look 45 -20         # Look right and down"
    echo "  ./snapshot.sh --zoom 2              # Zoom to 2x"
    echo "  ./snapshot.sh --calc-adjust 25 30 100  # Object at 25% from left, 30% from top"
    echo "  ./snapshot.sh --calc-zoom 40 80 100    # Object is 40% of frame, want 80%"
    echo ""
    echo "Help:"
    echo "  -h, --help                          Show this help message"
    echo "  -s, --status                        Check dependencies and permissions"
}

# Show status of dependencies and permissions
show_status() {
    echo "=== snapshot.sh Status ==="
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

    # ffmpeg
    if command -v ffmpeg &> /dev/null; then
        local ffmpeg_version=$(ffmpeg -version 2>&1 | head -1 | awk '{print $3}')
        echo "  [OK] ffmpeg $ffmpeg_version (video capture)"
    else
        echo "  [MISSING] ffmpeg - Install with: brew install ffmpeg"
        all_ok=false
    fi

    # uvcc (optional for PTZ)
    if command -v uvcc &> /dev/null; then
        echo "  [OK] uvcc (PTZ camera control)"
    else
        echo "  [OPTIONAL] uvcc not installed - PTZ controls unavailable"
        echo "             Install with: npm install -g uvcc"
    fi

    # Pillow (for grid overlay)
    if [[ -f "$PYTHON" ]] && "$PYTHON" -c "import PIL" 2>/dev/null; then
        local pil_version=$("$PYTHON" -c "import PIL; print(PIL.__version__)" 2>/dev/null)
        echo "  [OK] Pillow $pil_version (grid overlay)"
    else
        echo "  [MISSING] Pillow - Run: ./setup.sh"
        all_ok=false
    fi

    echo ""
    echo "Permissions:"

    # Camera permission (check if any video device is accessible)
    local camera_test=$(ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -i "video")
    if [[ -n "$camera_test" ]]; then
        echo "  [OK] Camera"
    else
        echo "  [DENIED] Camera"
        echo "          Enable in: System Settings > Privacy & Security > Camera"
        all_ok=false
    fi

    echo ""
    echo "Camera Hardware:"
    # List video devices
    ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -E "^\[AVFoundation.*\] \[[0-9]+\]" | head -5 | while read line; do
        echo "  $line"
    done

    echo ""
    if $all_ok; then
        echo "Status: All checks passed"
    else
        echo "Status: Issues detected (see above)"
    fi
}

# Main command dispatcher
case "$1" in
    --help|-h)
        show_help
        ;;
    -s|--status)
        show_status
        ;;
    --list-devices|--list|-l)
        list_devices
        ;;
    --grid|-g)
        show_grid
        ;;
    --ptz)
        get_status
        ;;
    --position)
        get_position_raw
        ;;
    --center|-c)
        center_camera
        ;;
    --reset|-r)
        reset_camera
        ;;
    --pan|-p)
        set_pan "$2"
        ;;
    --tilt|-t)
        set_tilt "$2"
        ;;
    --zoom|-z)
        set_zoom "$2"
        ;;
    --look)
        set_look "$2" "$3"
        ;;
    --calc-adjust)
        calc_adjustment "$2" "$3" "$4"
        ;;
    --calc-zoom)
        calc_zoom "$2" "$3" "$4"
        ;;
    --calc-frame)
        calc_frame "$2" "$3" "$4" "$5" "$6"
        ;;
    --calc-correct)
        calc_correct "$2" "$3" "$4"
        ;;
    --snap)
        capture_snapshot "${2:-0}"
        ;;
    ""|[0-9]*)
        capture_snapshot "${1:-0}"
        ;;
    *)
        echo "Unknown command: $1"
        echo "Use --help for usage information"
        exit 1
        ;;
esac
