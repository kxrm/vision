#!/bin/bash
# bubble.sh - Floating chat bubble interface for Claude Code
#
# Usage:
#   ./bubble.sh --show "message"         # Display bubble
#   ./bubble.sh --append "message"       # Add to chat history
#   ./bubble.sh --update "message"       # Replace message
#   ./bubble.sh --read                   # Wait for response
#   ./bubble.sh --dismiss                # Close bubble
#
# Options:
#   --image <path>                       # Include image
#   --screenshot                         # Take screenshot as image
#   --screenshot-crop <x>,<y>,<w>,<h>    # Screenshot with crop region
#   --position <x>,<y>                   # Position (grid % 0-100)
#   --point-at <x>,<y> or <x>,<y>,<w>,<h> # Point arrow at location or bounding box
#   --point-at-text <text>               # Point at text found via OCR (requires --in-app)
#   --near <text>                        # Find text closest to anchor (with --point-at-text)
#   --arrow <direction>                  # Arrow hint: left, right, up, down
#   --in-app <name>                      # App for coordinate translation
#   --move <x>,<y>                       # Animate to new position
#   --clear-arrow                        # Remove arrow from bubble
#   --wait                               # Block until user responds
#   --status                             # Show dependencies
#   --debug                              # Show debug info

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"
PYTHON="${SCRIPT_DIR}/../venv/bin/python"
GUI_SCRIPT="${LIB_DIR}/bubble_gui.py"

# File paths (must match bubble_gui.py)
uid=$(id -u)
STATE_FILE="/tmp/bubble_state_${uid}.json"
RESPONSE_FILE="/tmp/bubble_response_${uid}.json"
COMMAND_FILE="/tmp/bubble_command_${uid}.json"
ACK_FILE="/tmp/bubble_ack_${uid}.json"
DEBUG_LOG="/tmp/claude/bubble_debug_${uid}.log"

# Debug mode from environment
DEBUG="${BUBBLE_DEBUG:-0}"

debug_log() {
    if [[ "$DEBUG" == "1" ]]; then
        mkdir -p /tmp/claude
        echo "$(date +%Y-%m-%dT%H:%M:%S) [shell] $1" >> "$DEBUG_LOG"
    fi
}

# Properly escape text for JSON using Python (also unescapes \\! from Claude Code)
json_escape() {
    printf '%s' "$1" | "$PYTHON" -c '
import sys, json
text = sys.stdin.read()
# Claude Code escapes ! as \\! - unescape it
text = text.replace("\\\\!", "!").replace("\\!", "!")
print(json.dumps(text)[1:-1], end="")
'
}

check_python() {
    if [[ ! -x "$PYTHON" ]]; then
        echo "ERROR: Python venv not found at $PYTHON" >&2
        echo "Run: python3 -m venv ${SCRIPT_DIR}/../venv && ${SCRIPT_DIR}/../venv/bin/pip install pyobjc pillow" >&2
        exit 1
    fi
}

check_gui() {
    if [[ ! -f "$GUI_SCRIPT" ]]; then
        echo "ERROR: bubble_gui.py not found at $GUI_SCRIPT" >&2
        exit 1
    fi
}

is_bubble_running() {
    if [[ -f "$STATE_FILE" ]]; then
        local pid
        pid=$(grep -o '"pid": *[0-9]*' "$STATE_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

send_command() {
    local cmd="$1"
    debug_log "send_command: $cmd"

    # Use mkdir for atomic locking (macOS compatible)
    local lock_dir="/tmp/bubble_lock_${uid}.d"
    local lock_acquired=0
    local attempts=0
    while [[ $attempts -lt 50 ]]; do
        if mkdir "$lock_dir" 2>/dev/null; then
            lock_acquired=1
            break
        fi
        sleep 0.1
        ((attempts++)) || true
    done

    if [[ $lock_acquired -eq 0 ]]; then
        debug_log "Failed to acquire lock"
        # Remove stale lock and try once more
        rmdir "$lock_dir" 2>/dev/null || true
        if ! mkdir "$lock_dir" 2>/dev/null; then
            return 1
        fi
    fi

    # Critical section
    # Remove any stale ack file
    rm -f "$ACK_FILE"

    # Write command
    echo "$cmd" > "$COMMAND_FILE"
    debug_log "Wrote command file"

    # Release lock
    rmdir "$lock_dir" 2>/dev/null || true

    # Wait for acknowledgment (max 3 seconds)
    local waited=0
    while [[ ! -f "$ACK_FILE" ]] && [[ $waited -lt 30 ]]; do
        sleep 0.1
        ((waited++)) || true
    done

    if [[ -f "$ACK_FILE" ]]; then
        debug_log "Received ack"
        rm -f "$ACK_FILE"
        return 0
    else
        debug_log "No ack received (timeout)"
        return 1
    fi
}

wait_for_response() {
    local timeout="${1:-}"
    local waited=0
    local max_wait=36000  # 1 hour max

    if [[ -n "$timeout" ]]; then
        max_wait=$((timeout * 10))
    fi

    while [[ $waited -lt $max_wait ]]; do
        if [[ -f "$RESPONSE_FILE" ]]; then
            cat "$RESPONSE_FILE"
            rm -f "$RESPONSE_FILE"
            return 0
        fi
        sleep 0.1
        ((waited++)) || true
    done

    echo "{}"
    return 1
}

# Check if a reply is pending and output status
check_reply_pending() {
    if [[ -f "$RESPONSE_FILE" ]]; then
        echo "REPLY_PENDING: true"
    else
        echo "REPLY_PENDING: false"
    fi
}

show_usage() {
    cat <<'EOF'
bubble.sh - Floating chat bubble for Claude Code

Usage:
  bubble.sh --show "message"              Show bubble (reuses existing if running)
  bubble.sh --append "message"            Add message to chat
  bubble.sh --update "message"            Replace message
  bubble.sh --read                        Wait for user response
  bubble.sh --read-nowait                 Check for response (non-blocking)
  bubble.sh --dismiss                     Close bubble (only when session complete)
  bubble.sh --move <x>,<y>                Animate to new position
  bubble.sh --clear-arrow                 Remove arrow from bubble
  bubble.sh --debug                       Show bubble state and process info
  bubble.sh --status                      Show dependencies
  bubble.sh --status "text"               Set status line (use "busy:text" for shimmer)

Options:
  --image <path>                          Include image
  --crop <x>,<y>,<w>,<h>                  Crop image (% 0-100, or pixels if >100)
  --screenshot                            Take screenshot as image
  --screenshot-crop <x>,<y>,<w>,<h>       Screenshot + crop in one command
  --position <x>,<y>                      Initial position (% 0-100, or pixels if >100)
  --point-at <x>,<y> or <x>,<y>,<w>,<h>   Point arrow at location (or bounding box for smart positioning)
  --point-at-text <text>                  Point arrow at text found via OCR (requires --in-app)
  --near <text>                           Find text closest to anchor (use with --point-at-text)
  --arrow <direction>                     Arrow hint: left, right, up, down
  --in-app <name>                         App for coordinate translation
  --wait                                  Block until user responds

Coordinates:
  Values 0-100 are percentages of screen/app window
  Values >100 are treated as pixel coordinates

Environment:
  BUBBLE_DEBUG=1                          Enable debug logging to /tmp/claude/

Examples:
  bubble.sh --show "Hello!" --position 80,50
  bubble.sh --append "Found 3 issues." --wait
  bubble.sh --append "Screenshot:" --screenshot-crop 30,40,25,20 --in-app Firefox
  bubble.sh --move 50,50
  bubble.sh --point-at 30,40 --in-app Firefox
  bubble.sh --show "Click here!" --point-at-text "Submit" --in-app Firefox
  bubble.sh --append "This comment" --point-at-text "comments" --near "article title" --in-app Firefox
EOF
}

# Parse arguments
MESSAGE=""
IMAGE=""
CROP=""
POSITION=""
POINT_AT=""
POINT_AT_TEXT=""
NEAR_TEXT=""
ARROW=""
IN_APP=""
DO_SCREENSHOT=""
SCREENSHOT_CROP=""
WAIT_FOR_RESPONSE=""
STATUS_TEXT=""

ACTION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --show)
            ACTION="show"
            MESSAGE="$2"
            shift 2
            ;;
        --append)
            ACTION="append"
            MESSAGE="$2"
            shift 2
            ;;
        --update)
            ACTION="update"
            MESSAGE="$2"
            shift 2
            ;;
        --read)
            ACTION="read"
            shift
            ;;
        --read-nowait)
            ACTION="read-nowait"
            shift
            ;;
        --dismiss)
            ACTION="dismiss"
            shift
            ;;
        --move)
            ACTION="move"
            POSITION="$2"
            shift 2
            ;;
        --clear-arrow)
            ACTION="clear-arrow"
            shift
            ;;
        --get-position)
            ACTION="get-position"
            shift
            ;;
        --park)
            # Move bubble to a corner to get it out of the way
            # Default to bottom-right corner, or specify: tl, tr, bl, br
            ACTION="park"
            PARK_CORNER="${2:-br}"
            if [[ "${PARK_CORNER:0:2}" != "--" && "${PARK_CORNER}" =~ ^(tl|tr|bl|br)$ ]]; then
                shift 2
            else
                PARK_CORNER="br"
                shift
            fi
            ;;
        --status)
            # If next arg exists and doesn't start with --, it's status text
            if [[ -n "${2:-}" && "${2:0:2}" != "--" ]]; then
                STATUS_TEXT="$2"
                shift 2
            else
                # No text arg = show dependencies (existing behavior)
                ACTION="status"
                shift
            fi
            ;;
        --debug)
            ACTION="debug"
            shift
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        --image)
            IMAGE="$2"
            shift 2
            ;;
        --screenshot)
            DO_SCREENSHOT="1"
            shift
            ;;
        --screenshot-crop)
            DO_SCREENSHOT="1"
            SCREENSHOT_CROP="$2"
            shift 2
            ;;
        --crop)
            CROP="$2"
            shift 2
            ;;
        --position)
            POSITION="$2"
            shift 2
            ;;
        --point-at)
            POINT_AT="$2"
            shift 2
            ;;
        --point-at-text)
            POINT_AT_TEXT="$2"
            shift 2
            ;;
        --near)
            NEAR_TEXT="$2"
            shift 2
            ;;
        --arrow)
            ARROW="$2"
            shift 2
            ;;
        --in-app)
            IN_APP="$2"
            shift 2
            ;;
        --wait)
            WAIT_FOR_RESPONSE="1"
            shift
            ;;
        *)
            echo "Unknown option: $1" >&2
            show_usage
            exit 1
            ;;
    esac
done

# Default action
if [[ -z "$ACTION" ]]; then
    show_usage
    exit 1
fi

check_python
check_gui

# Resolve --point-at-text to coordinates using find_text.py
if [[ -n "$POINT_AT_TEXT" ]]; then
    if [[ -z "$IN_APP" ]]; then
        echo "ERROR: --point-at-text requires --in-app to be set" >&2
        exit 1
    fi

    # Build find_text.py arguments
    find_args=("$POINT_AT_TEXT" --in-app "$IN_APP")
    if [[ -n "$NEAR_TEXT" ]]; then
        find_args+=(--near "$NEAR_TEXT")
    fi

    # Run find_text.py to get bounding box (disable set -e for this command)
    bbox=$("$PYTHON" "$LIB_DIR/find_text.py" "${find_args[@]}" 2>&1) || true
    find_status=${PIPESTATUS[0]:-$?}

    # Check if output looks like coordinates (x,y,w,h format)
    if ! [[ "$bbox" =~ ^[0-9]+\.[0-9]+,[0-9]+\.[0-9]+,[0-9]+\.[0-9]+,[0-9]+\.[0-9]+$ ]]; then
        echo "ERROR: Could not find text '$POINT_AT_TEXT'" >&2
        [[ -n "$bbox" ]] && echo "$bbox" >&2
        exit 1
    fi

    # Set POINT_AT to the resolved coordinates
    POINT_AT="$bbox"
    debug_log "Resolved --point-at-text '$POINT_AT_TEXT' to: $POINT_AT"
fi

debug_log "Action: $ACTION, Message: ${MESSAGE:0:50}"

case "$ACTION" in
    show)
        # Clear any stale response file from previous sessions
        rm -f "$RESPONSE_FILE"

        # Reuse existing bubble if running
        if is_bubble_running; then
            # Send update command to existing bubble instead of creating new one
            escaped_msg=$(json_escape "$MESSAGE")
            escaped_status=$(json_escape "${STATUS_TEXT:-}")
            cmd="{\"command\": \"update\", \"message\": \"$escaped_msg\", \"status\": \"$escaped_status\""
            if [[ -n "$POSITION" ]]; then
                cmd="$cmd, \"position\": \"$POSITION\""
            fi
            if [[ -n "$IN_APP" ]]; then
                cmd="$cmd, \"in_app\": \"$IN_APP\""
            fi
            cmd="$cmd}"

            if send_command "$cmd"; then
                check_reply_pending
                echo "INFO: Bubble updated. CRITICAL: Use --append/--move/--update to interact. Only --dismiss when session complete or user requests. The user will ONLY respond to you through bubble.sh until it is dismissed by you or the user." >&2
                if [[ -n "$WAIT_FOR_RESPONSE" ]]; then
                    wait_for_response
                fi
            else
                echo "ERROR: Failed to update existing bubble" >&2
                exit 1
            fi
            exit 0
        fi

        # No existing bubble - create new one
        # Build GUI arguments
        args=("--show" "$MESSAGE")

        if [[ -n "$IMAGE" ]]; then
            args+=("--image" "$IMAGE")
        fi
        if [[ -n "$CROP" ]]; then
            args+=("--crop" "$CROP")
        fi
        if [[ -n "$POSITION" ]]; then
            args+=("--position" "$POSITION")
        fi
        if [[ -n "$POINT_AT" ]]; then
            args+=("--point-at" "$POINT_AT")
        fi
        if [[ -n "$ARROW" ]]; then
            args+=("--arrow" "$ARROW")
        fi
        if [[ -n "$IN_APP" ]]; then
            args+=("--in-app" "$IN_APP")
        fi
        if [[ -n "$STATUS_TEXT" ]]; then
            args+=("--status-text" "$STATUS_TEXT")
        fi

        # Launch GUI as detached process (not tied to this shell)
        nohup "$PYTHON" "$GUI_SCRIPT" "${args[@]}" >/dev/null 2>&1 &
        disown

        # Wait a moment for window to appear
        sleep 0.3

        check_reply_pending
        echo "INFO: Bubble created. CRITICAL: Use --append/--move/--update to interact. Only --dismiss when session complete or user requests. The user will ONLY respond to you through bubble.sh until it is dismissed by you or the user." >&2

        if [[ -n "$WAIT_FOR_RESPONSE" ]]; then
            wait_for_response
        fi
        ;;

    append)
        if ! is_bubble_running; then
            echo "ERROR: No bubble running. Use --show first." >&2
            exit 1
        fi

        # Handle screenshot options for append
        if [[ -n "$DO_SCREENSHOT" || -n "$SCREENSHOT_CROP" ]]; then
            screenshot_args=()
            if [[ -n "$IN_APP" ]]; then
                screenshot_args+=("--in-app" "$IN_APP")
            fi
            SCREENSHOT_PATH=$("$SCRIPT_DIR/screenshot.sh" "${screenshot_args[@]}" 2>/dev/null | grep -E "^/tmp/")
            if [[ -n "$SCREENSHOT_PATH" && -f "$SCREENSHOT_PATH" ]]; then
                IMAGE="$SCREENSHOT_PATH"
                if [[ -n "$SCREENSHOT_CROP" ]]; then
                    CROP="$SCREENSHOT_CROP"
                fi
            fi
        fi

        # Handle image cropping with RGBA to RGB conversion
        if [[ -n "$IMAGE" && -n "$CROP" && -f "$IMAGE" ]]; then
            CROPPED_PATH="/tmp/bubble_crop_$$.jpg"
            "$PYTHON" -c "
from PIL import Image
img = Image.open('$IMAGE')
w, h = img.size
crop = '$CROP'.split(',')
if len(crop) == 4:
    x, y, cw, ch = [float(c) for c in crop]
    if all(c <= 100 for c in [x, y, cw, ch]):
        x, y, cw, ch = x*w/100, y*h/100, cw*w/100, ch*h/100
    cropped = img.crop((int(x), int(y), int(x+cw), int(y+ch)))
    if cropped.mode == 'RGBA':
        cropped = cropped.convert('RGB')
    cropped.save('$CROPPED_PATH', quality=85)
" 2>/dev/null && IMAGE="$CROPPED_PATH"
        fi

        # Build command JSON
        escaped_msg=$(json_escape "$MESSAGE")
        escaped_status=$(json_escape "${STATUS_TEXT:-}")
        cmd="{\"command\": \"append\", \"message\": \"$escaped_msg\", \"role\": \"claude\", \"status\": \"$escaped_status\""

        if [[ -n "$IMAGE" && -f "$IMAGE" ]]; then
            cmd="$cmd, \"image\": \"$IMAGE\""
        fi

        # Add point-at for repositioning while appending (auto-detects x,y vs x,y,w,h)
        if [[ -n "$POINT_AT" ]]; then
            cmd="$cmd, \"point_at\": \"$POINT_AT\""
            if [[ -n "$IN_APP" ]]; then
                cmd="$cmd, \"in_app\": \"$IN_APP\""
            fi
            if [[ -n "$ARROW" ]]; then
                cmd="$cmd, \"arrow\": \"$ARROW\""
            fi
        fi

        cmd="$cmd}"

        debug_log "Sending append command: $cmd"

        if send_command "$cmd"; then
            check_reply_pending
            if [[ -n "$WAIT_FOR_RESPONSE" ]]; then
                wait_for_response
            fi
        else
            echo "ERROR: Failed to send append command" >&2
            exit 1
        fi
        ;;

    update)
        if ! is_bubble_running; then
            echo "ERROR: No bubble running. Use --show first." >&2
            exit 1
        fi

        escaped_msg=$(json_escape "$MESSAGE")
        escaped_status=$(json_escape "${STATUS_TEXT:-}")
        cmd="{\"command\": \"update\", \"message\": \"$escaped_msg\", \"status\": \"$escaped_status\""

        # Add point-at for repositioning while updating
        if [[ -n "$POINT_AT" ]]; then
            cmd="$cmd, \"point_at\": \"$POINT_AT\""
            if [[ -n "$IN_APP" ]]; then
                cmd="$cmd, \"in_app\": \"$IN_APP\""
            fi
            if [[ -n "$ARROW" ]]; then
                cmd="$cmd, \"arrow\": \"$ARROW\""
            fi
        fi

        cmd="$cmd}"

        if send_command "$cmd"; then
            check_reply_pending
            if [[ -n "$WAIT_FOR_RESPONSE" ]]; then
                wait_for_response
            fi
        else
            echo "ERROR: Failed to send update command" >&2
            exit 1
        fi
        ;;

    move)
        if ! is_bubble_running; then
            echo "ERROR: No bubble running. Use --show first." >&2
            exit 1
        fi

        # Check for mutual exclusivity with point-at
        if [[ -n "$POINT_AT" ]]; then
            echo "WARNING: --move and --point-at are mutually exclusive. Using --point-at instead." >&2
            # Fall through to point-at handling
            ACTION="point-at"
        fi

        if [[ "$ACTION" == "move" ]]; then
            # Build move command
            cmd="{\"command\": \"move\", \"position\": \"$POSITION\""
            if [[ -n "$IN_APP" ]]; then
                cmd="$cmd, \"in_app\": \"$IN_APP\""
            fi
            cmd="$cmd}"

            send_command "$cmd" || echo "ERROR: Failed to send move command" >&2
        else
            # ACTION was changed to point-at, handle it here
            cmd="{\"command\": \"point-at\", \"point_at\": \"$POINT_AT\""
            if [[ -n "$IN_APP" ]]; then
                cmd="$cmd, \"in_app\": \"$IN_APP\""
            fi
            cmd="$cmd}"

            if send_command "$cmd"; then
                echo "INFO: Bubble is now pointing at target. Remember to use --move or --clear-arrow before scrolling or changing page content." >&2
            else
                echo "ERROR: Failed to send point-at command" >&2
            fi
        fi
        ;;

    clear-arrow)
        if ! is_bubble_running; then
            echo "ERROR: No bubble running. Use --show first." >&2
            exit 1
        fi

        send_command '{"command": "clear-arrow"}' || echo "ERROR: Failed to clear arrow" >&2
        ;;

    get-position)
        # Get the bubble's current position and size
        # This reads from state file - for live position, would need GUI query
        if ! is_bubble_running; then
            echo "{}"
            exit 0
        fi

        if [[ -f "$STATE_FILE" ]]; then
            # Parse position from JSON - can be array [x,y] or string "x,y" or null
            position=$("$PYTHON" -c "
import json
try:
    with open('$STATE_FILE') as f:
        data = json.load(f)
    pos = data.get('position')
    if pos:
        if isinstance(pos, list):
            print(f'{pos[0]},{pos[1]}')
        else:
            print(pos)
except:
    pass
" 2>/dev/null)
            if [[ -n "$position" ]]; then
                # Get actual size from state file, or use default estimate
                size=$("$PYTHON" -c "
import json
try:
    with open('$STATE_FILE') as f:
        data = json.load(f)
    sz = data.get('size')
    if sz and isinstance(sz, list) and len(sz) == 2:
        print(f'{sz[0]:.1f},{sz[1]:.1f}')
except:
    pass
" 2>/dev/null)
                if [[ -n "$size" ]]; then
                    echo "@bubble position:$position size:$size"
                else
                    # Fallback to estimate if size not available
                    echo "@bubble position:$position size:28,12"
                fi
            else
                echo "@bubble position:unknown"
            fi
        else
            echo "@bubble position:unknown"
        fi
        ;;

    park)
        # Move bubble to a corner to get it out of the way
        if ! is_bubble_running; then
            echo "ERROR: No bubble running. Use --show first." >&2
            exit 1
        fi

        # Map corner names to positions (grid %)
        case "$PARK_CORNER" in
            tl) park_pos="5,5" ;;      # Top-left
            tr) park_pos="85,5" ;;     # Top-right
            bl) park_pos="5,85" ;;     # Bottom-left
            br) park_pos="85,75" ;;    # Bottom-right (default)
            *)  park_pos="85,75" ;;
        esac

        cmd="{\"command\": \"move\", \"position\": \"$park_pos\"}"
        if send_command "$cmd"; then
            echo "Bubble parked at $PARK_CORNER corner ($park_pos)"
        else
            echo "ERROR: Failed to park bubble" >&2
            exit 1
        fi
        ;;

    read)
        if ! is_bubble_running; then
            rm -f "$RESPONSE_FILE"  # Clean up stale file
            echo "{}"
            exit 0
        fi
        # Set status to "Listening..." while waiting for reply
        send_command '{"command": "status", "status": "Listening..."}' 2>/dev/null || true
        wait_for_response
        ;;

    read-nowait)
        if [[ -f "$RESPONSE_FILE" ]]; then
            cat "$RESPONSE_FILE"
            rm -f "$RESPONSE_FILE"
        else
            echo "{}"
        fi
        ;;

    dismiss)
        # Get PID before we do anything (state file might get deleted)
        bubble_pid=""
        if [[ -f "$STATE_FILE" ]]; then
            bubble_pid=$(grep -o '"pid": *[0-9]*' "$STATE_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "")
        fi

        # Try graceful dismiss via command
        if [[ -n "$bubble_pid" ]] && kill -0 "$bubble_pid" 2>/dev/null; then
            send_command '{"command": "dismiss"}' 2>/dev/null || true
            # Wait briefly for graceful exit
            sleep 0.3
        fi

        # If process still running, kill it explicitly
        if [[ -n "$bubble_pid" ]] && kill -0 "$bubble_pid" 2>/dev/null; then
            debug_log "Bubble still running after dismiss command, killing PID $bubble_pid"
            kill "$bubble_pid" 2>/dev/null || true
            sleep 0.1
            # Force kill if still alive
            kill -9 "$bubble_pid" 2>/dev/null || true
        fi

        # Clean up files
        rm -f "$STATE_FILE" "$RESPONSE_FILE" "$COMMAND_FILE" "$ACK_FILE"
        rmdir "/tmp/bubble_lock_${uid}.d" 2>/dev/null || true
        ;;

    status)
        "$PYTHON" "$GUI_SCRIPT" --status
        ;;

    debug)
        echo "=== Bubble Debug Info ==="
        echo "State file: $STATE_FILE"
        if [[ -f "$STATE_FILE" ]]; then
            cat "$STATE_FILE"
        else
            echo "(not found)"
        fi
        echo ""
        echo "Response file: $RESPONSE_FILE"
        if [[ -f "$RESPONSE_FILE" ]]; then
            cat "$RESPONSE_FILE"
        else
            echo "(not found)"
        fi
        echo ""
        echo "Command file: $COMMAND_FILE"
        if [[ -f "$COMMAND_FILE" ]]; then
            cat "$COMMAND_FILE"
        else
            echo "(not found)"
        fi
        echo ""
        if is_bubble_running; then
            echo "Bubble status: RUNNING"
        else
            echo "Bubble status: NOT RUNNING"
        fi
        ;;
esac
