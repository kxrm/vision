#!/bin/bash
#
# joystick.sh - Reactive game controller for real-time UI interaction
#
# Runs a game loop that:
#   1. Captures screen state
#   2. Finds objects by color
#   3. Applies strategy (chase, flee, mirror)
#   4. Sends appropriate keypresses
#   5. Repeats at game speed
#
# Usage:
#   ./joystick.sh --in-app "App Name" --target green --self blue --strategy chase
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PYTHON="$PROJECT_ROOT/venv/bin/python"

# Defaults
APP=""
TARGET_COLOR="green"
SELF_COLOR="blue"
STRATEGY="chase"
KEYS="arrows"  # arrows or wasd
FPS=10
DURATION=30
AXIS="both"  # both, x, or y
AVOID_WALLS=true
DEBUG=false

show_help() {
    cat << 'EOF'
joystick.sh - Reactive Game Controller

USAGE:
    ./joystick.sh --in-app <app> [OPTIONS]

REQUIRED:
    --in-app <app>          Target application name

OPTIONS:
    -h, --help              Show this help message
    -s, --status            Check dependencies and permissions
    --target <color>        Color to track/target (default: green)
    --self <color>          Color representing self/player (default: blue)
    --strategy <strategy>   Movement strategy (default: chase)
    --keys <type>           Key scheme: arrows or wasd (default: arrows)
    --fps <n>               Frames per second (default: 10)
    --duration <seconds>    How long to run (default: 30)
    --axis <axis>           Movement axis: both, x, or y (default: both)
    --no-avoid-walls        Disable wall avoidance
    --debug                 Show debug output

STRATEGIES:
    chase       Move toward target color (Snake chasing food)
    flee        Move away from target color (avoiding enemies)
    mirror      Match target's position on axis (Pong paddle tracking ball)
    patrol      Move in a pattern, react when target appears

COLORS:
    Supports: red, green, blue, yellow, orange, purple, white, black, gold, cyan, magenta
    Or hex: "#FF5500" or "rgb:255,85,0"

EXAMPLES:
    # Snake: chase green food
    ./joystick.sh --in-app Python --target green --self blue --strategy chase

    # Pong: mirror ball on Y axis
    ./joystick.sh --in-app Python --target white --self green --strategy mirror --axis y

    # Avoid enemies
    ./joystick.sh --in-app Python --target red --self blue --strategy flee
EOF
}

# Show status of dependencies and permissions
show_status() {
    echo "=== joystick.sh Status ==="
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
        echo "  [OK] cliclick $cliclick_version (keyboard input)"
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

    # pyobjc-framework-Quartz (for screenshots)
    if [[ -f "$PYTHON" ]] && "$PYTHON" -c "import Quartz" 2>/dev/null; then
        echo "  [OK] pyobjc-framework-Quartz (screen capture)"
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

    # Accessibility (for keyboard input)
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

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --in-app)
            APP="$2"
            shift 2
            ;;
        --target)
            TARGET_COLOR="$2"
            shift 2
            ;;
        --self)
            SELF_COLOR="$2"
            shift 2
            ;;
        --strategy)
            STRATEGY="$2"
            shift 2
            ;;
        --keys)
            KEYS="$2"
            shift 2
            ;;
        --fps)
            FPS="$2"
            shift 2
            ;;
        --duration)
            DURATION="$2"
            shift 2
            ;;
        --axis)
            AXIS="$2"
            shift 2
            ;;
        --no-avoid-walls)
            AVOID_WALLS=false
            shift
            ;;
        --debug)
            DEBUG=true
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        -s|--status)
            show_status
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

if [[ -z "$APP" ]]; then
    echo "ERROR: --in-app is required"
    show_help
    exit 1
fi

# Run the game loop in Python
"$PYTHON" << PYEOF
import Quartz
from Quartz import CGWindowListCopyWindowInfo, kCGWindowListOptionOnScreenOnly, kCGNullWindowID
from Quartz import CGWindowListCreateImage, kCGWindowImageDefault, CGRectNull
from Quartz import CGImageGetWidth, CGImageGetHeight, CGImageGetDataProvider, CGDataProviderCopyData
import time
import subprocess
import sys
import os
import glob
from collections import defaultdict

# Configuration from shell
APP = "$APP"
TARGET_COLOR = "$TARGET_COLOR"
SELF_COLOR = "$SELF_COLOR"
STRATEGY = "$STRATEGY"
KEYS = "$KEYS"
FPS = $FPS
DURATION = $DURATION
AXIS = "$AXIS"
AVOID_WALLS = $( [[ "$AVOID_WALLS" == "true" ]] && echo "True" || echo "False" )
DEBUG = $( [[ "$DEBUG" == "true" ]] && echo "True" || echo "False" )

# Color definitions (RGB ranges for detection)
COLOR_RANGES = {
    'red':     {'min': (150, 0, 0),     'max': (255, 100, 100)},
    # Food green detection - requires pure green (g >> r and g >> b)
    'green':   {'min': (0, 150, 0),     'max': (100, 255, 100), 'pure_green': True},
    'blue':    {'min': (0, 0, 150),     'max': (100, 100, 255)},
    'yellow':  {'min': (200, 200, 0),   'max': (255, 255, 100)},
    'orange':  {'min': (200, 100, 0),   'max': (255, 180, 80)},
    'gold':    {'min': (200, 170, 0),   'max': (255, 230, 100)},
    'purple':  {'min': (100, 0, 150),   'max': (200, 100, 255)},
    'cyan':    {'min': (0, 200, 200),   'max': (100, 255, 255)},
    'magenta': {'min': (200, 0, 200),   'max': (255, 100, 255)},
    'white':   {'min': (200, 200, 200), 'max': (255, 255, 255)},
    'black':   {'min': (0, 0, 0),       'max': (50, 50, 50)},
    # Rainbow snake detection - any bright saturated color (not black/white/gray)
    'rainbow': {'min': (100, 0, 0),     'max': (255, 255, 255), 'saturated': True},
}

# Key mappings
KEY_MAP = {
    'arrows': {'up': 'arrow-up', 'down': 'arrow-down', 'left': 'arrow-left', 'right': 'arrow-right'},
    'wasd':   {'up': 'w', 'down': 's', 'left': 'a', 'right': 'd'},
}

# Tight clockwise circle - turn every N frames
_last_dir = 'right'
_steps_since_turn = 0
STEPS_PER_TURN = 3  # Turn every 3 frames for tight circle

def get_circle_move(bounds, self_pos):
    """Tight clockwise circle - keep turning to create small loop."""
    global _last_dir, _steps_since_turn

    # Clockwise turn order
    DIRS = ['right', 'down', 'left', 'up']

    _steps_since_turn += 1

    # Turn clockwise every N steps
    if _steps_since_turn >= STEPS_PER_TURN:
        current_idx = DIRS.index(_last_dir)
        _last_dir = DIRS[(current_idx + 1) % 4]
        _steps_since_turn = 0

    return _last_dir

def get_window_info(app_name):
    """Get window ID and bounds for the target application."""
    windows = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID)
    for window in windows:
        owner = window.get('kCGWindowOwnerName', '')
        if app_name.lower() in owner.lower():
            bounds = window.get('kCGWindowBounds', {})
            return {
                'x': int(bounds.get('X', 0)),
                'y': int(bounds.get('Y', 0)),
                'width': int(bounds.get('Width', 0)),
                'height': int(bounds.get('Height', 0)),
                'id': window.get('kCGWindowNumber', 0)
            }
    return None

_frame_number = 0
_cleanup_done = False

def capture_window(window_id, temp_file='/tmp/joystick_frame.png'):
    """Capture screenshot of specific window using screencapture."""
    global _frame_number, _cleanup_done
    import os
    import glob
    from PIL import Image

    # Clean up old debug frames on first call
    if DEBUG and not _cleanup_done:
        for old_frame in glob.glob('/tmp/snake_frame_*.png'):
            try:
                os.remove(old_frame)
            except:
                pass
        _cleanup_done = True

    # Use macOS screencapture for reliable window capture
    # -o excludes the window shadow for accurate coordinates
    result = subprocess.run(
        ['screencapture', '-x', '-o', '-l', str(window_id), temp_file],
        capture_output=True
    )

    if result.returncode != 0 or not os.path.exists(temp_file):
        return None, 0, 0

    # Read image with PIL
    img = Image.open(temp_file)
    width, height = img.size

    # Save audit trail when in debug mode
    if DEBUG:
        audit_file = f'/tmp/snake_frame_{_frame_number:04d}.png'
        img.save(audit_file)
        _frame_number += 1

    # Convert to RGB if needed and get pixel data
    if img.mode != 'RGB':
        img = img.convert('RGB')

    pixel_data = img.tobytes()

    return pixel_data, width, height, 3  # 3 bytes per pixel (RGB)

def find_color_center(pixel_data, width, height, color_name, bytes_per_pixel=3):
    """Find the center of mass of pixels matching the target color."""
    if color_name not in COLOR_RANGES:
        print(f"Unknown color: {color_name}")
        return None

    color_range = COLOR_RANGES[color_name]
    min_r, min_g, min_b = color_range['min']
    max_r, max_g, max_b = color_range['max']
    check_saturated = color_range.get('saturated', False)
    check_pure_green = color_range.get('pure_green', False)

    # Sample pixels (every 2nd pixel for speed)
    total_x, total_y, count = 0, 0, 0

    for y in range(0, height, 2):
        for x in range(0, width, 2):
            idx = (y * width + x) * bytes_per_pixel
            if idx + 2 >= len(pixel_data):
                continue

            r = pixel_data[idx]
            g = pixel_data[idx + 1]
            b = pixel_data[idx + 2]

            # For saturated colors (rainbow), check that at least one channel is high
            # and not all channels are similar (gray)
            if check_saturated:
                # Skip title bar area (window buttons are at top ~100px at 2x retina)
                if y < 100:
                    continue
                max_val = max(r, g, b)
                min_val = min(r, g, b)
                # Must be bright (max > 150) and saturated (difference > 100)
                if max_val > 150 and (max_val - min_val) > 100:
                    # Exclude known colors (food is pure green 0,255,0)
                    if not (g > 200 and r < 50 and b < 50):  # Not pure green food
                        total_x += x
                        total_y += y
                        count += 1
            elif check_pure_green:
                # Food is lime green (r=86, g=188, b=55 measured)
                # Must be clearly green dominant (g >> r and g >> b)
                if g > 150 and r < 100 and b < 80 and g > r + 80 and g > b + 80:
                    total_x += x
                    total_y += y
                    count += 1
            elif (min_r <= r <= max_r and
                  min_g <= g <= max_g and
                  min_b <= b <= max_b):
                total_x += x
                total_y += y
                count += 1

    if count > 0:
        return (total_x // count, total_y // count, count)
    return None

def find_leading_edge(pixel_data, width, height, color_name, direction, bytes_per_pixel=3):
    """Find the leading edge of colored pixels based on movement direction.

    Returns the extreme point in the direction of movement (approximates snake head).
    - RIGHT: rightmost pixels
    - LEFT: leftmost pixels
    - UP: topmost pixels
    - DOWN: bottommost pixels
    """
    if color_name not in COLOR_RANGES:
        return None

    color_range = COLOR_RANGES[color_name]
    check_saturated = color_range.get('saturated', False)

    # Track extreme positions - separate lists for each edge
    min_x, max_x = width, 0
    min_y, max_y = height, 0
    left_edge = []   # pixels at min_x (leftmost)
    right_edge = []  # pixels at max_x (rightmost)
    top_edge = []    # pixels at min_y (topmost)
    bottom_edge = [] # pixels at max_y (bottommost)
    count = 0

    for y in range(0, height, 2):
        for x in range(0, width, 2):
            idx = (y * width + x) * bytes_per_pixel
            if idx + 2 >= len(pixel_data):
                continue

            r = pixel_data[idx]
            g = pixel_data[idx + 1]
            b = pixel_data[idx + 2]

            # Check if this pixel matches (simplified for rainbow/saturated)
            matches = False
            if check_saturated:
                if y < 100:  # Skip title bar
                    continue
                max_val = max(r, g, b)
                min_val = min(r, g, b)
                if max_val > 150 and (max_val - min_val) > 100:
                    if not (g > 200 and r < 50 and b < 50):  # Not food
                        matches = True

            if matches:
                count += 1
                # Track left edge (min x)
                if x < min_x:
                    min_x = x
                    left_edge = [(x, y)]
                elif x == min_x:
                    left_edge.append((x, y))
                # Track right edge (max x)
                if x > max_x:
                    max_x = x
                    right_edge = [(x, y)]
                elif x == max_x:
                    right_edge.append((x, y))
                # Track top edge (min y)
                if y < min_y:
                    min_y = y
                    top_edge = [(x, y)]
                elif y == min_y:
                    top_edge.append((x, y))
                # Track bottom edge (max y)
                if y > max_y:
                    max_y = y
                    bottom_edge = [(x, y)]
                elif y == max_y:
                    bottom_edge.append((x, y))

    if count == 0:
        return None

    # Return the leading edge based on direction
    if direction == 'right' and right_edge:
        # Rightmost pixels - average their Y positions
        avg_y = sum(p[1] for p in right_edge) // len(right_edge)
        return (max_x, avg_y, count)
    elif direction == 'left' and left_edge:
        avg_y = sum(p[1] for p in left_edge) // len(left_edge)
        return (min_x, avg_y, count)
    elif direction == 'up' and top_edge:
        avg_x = sum(p[0] for p in top_edge) // len(top_edge)
        return (avg_x, min_y, count)
    elif direction == 'down' and bottom_edge:
        avg_x = sum(p[0] for p in bottom_edge) // len(bottom_edge)
        return (avg_x, max_y, count)
    else:
        # No direction or fallback - return centroid
        return None

def detect_game_over(pixel_data, width, height, bytes_per_pixel=3):
    """Detect if game over screen is showing (red text in CENTER of screen)."""
    # Game Over screen has:
    # 1. Red "Game Over!" text in center
    # 2. White "Final Score" and "Press C" text
    # 3. NO green food
    # 4. NO rainbow snake (mostly black background)

    red_count_center = 0
    white_count = 0  # For "Final Score" text
    green_count = 0
    saturated_count = 0  # Rainbow snake detection

    # Skip title bar area
    title_bar_height = 80

    # Define center region for text
    center_left = int(width * 0.30)
    center_right = int(width * 0.70)
    text_top = int(height * 0.35)
    text_bottom = int(height * 0.65)

    for y in range(title_bar_height, height, 4):
        for x in range(0, width, 4):
            idx = (y * width + x) * bytes_per_pixel
            if idx + 2 >= len(pixel_data):
                continue

            r = pixel_data[idx]
            g = pixel_data[idx + 1]
            b = pixel_data[idx + 2]

            in_center = center_left < x < center_right and text_top < y < text_bottom

            # Red text detection (crimson red - lower threshold)
            if r > 150 and g < 100 and b < 100 and r > g + 50:
                if in_center:
                    red_count_center += 1

            # White text detection ("Final Score:", "Press C")
            if r > 180 and g > 180 and b > 180:
                if in_center:
                    white_count += 1

            # Green (food) detection
            if g > 200 and r < 80 and b < 80:
                green_count += 1

            # Saturated color detection (rainbow snake has bright saturated colors)
            max_val = max(r, g, b)
            min_val = min(r, g, b)
            if max_val > 150 and (max_val - min_val) > 80:
                saturated_count += 1

    # Game over if:
    # 1. Some red in center (text) - threshold lowered to 10
    # 2. Some white in center (other text)
    # 3. No green food
    # 4. Low saturated pixels (no rainbow snake visible)
    is_game_over = (red_count_center > 10 and
                    white_count > 20 and
                    green_count < 5 and
                    saturated_count < 200)

    if DEBUG and (is_game_over or red_count_center > 5):
        print(f"  [GameOver: red={red_count_center}, white={white_count}, green={green_count}, sat={saturated_count}, result={is_game_over}]")
    return is_game_over

def send_restart_key(app_name):
    """Send 'c' key to restart game."""
    # First activate the app
    activate_app(app_name)
    time.sleep(0.1)

    script = f'''
    tell application "System Events"
        tell process "{app_name}"
            keystroke "c"
        end tell
    end tell
    '''
    subprocess.run(['osascript', '-e', script], capture_output=True)
    time.sleep(0.5)  # Wait for game to fully restart

def press_key(key_name, app_name=None):
    """Press a key directly to the app using AppleScript."""
    # Map arrow keys to AppleScript key codes
    key_code_map = {
        'arrow-up': 126,
        'arrow-down': 125,
        'arrow-left': 123,
        'arrow-right': 124,
    }

    if key_name in key_code_map:
        code = key_code_map[key_name]
        # Send key code directly to the app's process
        script = f'''
        tell application "System Events"
            tell process "{app_name}"
                key code {code}
            end tell
        end tell
        '''
        subprocess.run(['osascript', '-e', script], capture_output=True)
    elif key_name in ['w', 'a', 's', 'd']:
        script = f'''
        tell application "System Events"
            tell process "{app_name}"
                keystroke "{key_name}"
            end tell
        end tell
        '''
        subprocess.run(['osascript', '-e', script], capture_output=True)
    else:
        # Fallback to cliclick
        subprocess.run(['cliclick', f'kp:{key_name}'], capture_output=True)

# Direction state tracking
_current_direction = None
_last_key_time = 0

# Opposite directions (can't reverse in snake)
OPPOSITE = {
    'up': 'down', 'down': 'up',
    'left': 'right', 'right': 'left'
}

def smart_press_key(desired_direction, app_name, keys):
    """
    Only send key if direction actually needs to change.
    Also prevents illegal reversals (can't go left if going right).
    Returns True if key was sent.
    """
    global _current_direction, _last_key_time

    if desired_direction is None:
        return False

    # Don't send if already going this direction
    if desired_direction == _current_direction:
        return False

    # Don't allow reversal (snake can't go backwards)
    if _current_direction and OPPOSITE.get(_current_direction) == desired_direction:
        if DEBUG:
            print(f"  [Blocked reversal: {_current_direction} -> {desired_direction}]")
        return False

    # Send the key
    key_name = keys.get(desired_direction)
    if key_name:
        press_key(key_name, app_name)
        _current_direction = desired_direction
        _last_key_time = time.time()
        return True

    return False

def reset_direction_state():
    """Reset direction tracking (call on game restart)."""
    global _current_direction, _last_key_time
    _current_direction = None
    _last_key_time = 0

def activate_app(app_name):
    """Bring app to foreground."""
    script = f'tell application "{app_name}" to activate'
    subprocess.run(['osascript', '-e', script], capture_output=True)

# Track estimated snake position based on moves
class SnakeTracker:
    def __init__(self, width, height):
        self.width = width
        self.height = height
        self.reset()

    def reset(self):
        """Reset to center position (snake starts at center)."""
        self.x = self.width // 2
        self.y = self.height // 2
        self.direction = None  # No direction until first move
        self.move_count = 0

    def update(self, move):
        """Update estimated position based on move sent."""
        if move is None:
            return

        # At 2x retina, each game block is ~40 pixels
        # Game runs at 15 FPS, joystick at 8 FPS, so ~2 moves per frame
        step = 80  # Estimate movement per joystick frame

        self.direction = move
        self.move_count += 1

        if move == 'right':
            self.x += step
        elif move == 'left':
            self.x -= step
        elif move == 'down':
            self.y += step
        elif move == 'up':
            self.y -= step

    def get_position(self):
        return (self.x, self.y)

_tracker = None
_circle_index = 0
_circle_steps = 0
CIRCLE_PATTERN = ['right', 'down', 'left', 'up']  # Start with right (most room from center)
STEPS_PER_DIRECTION = 1  # How many frames before turning (1 key per direction)

def calculate_move(target_pos, self_pos, strategy, axis, bounds, avoid_walls):
    """Calculate which direction to move based on strategy with smart wall avoidance."""
    global _tracker, _circle_index, _circle_steps

    if _tracker is None:
        _tracker = SnakeTracker(bounds['width'], bounds['height'])

    # For circle/patrol strategy, execute pattern regardless of target
    if strategy in ['circle', 'patrol', 'spiral']:
        move = get_circle_move(bounds, self_pos)
        _tracker.update(move)
        return move

    if target_pos is None:
        return None

    tx, ty, _ = target_pos

    # Game area boundaries (accounting for retina 2x and title bar ~56px)
    # Game is 800x600 at 1x, so 1600x1200 at 2x retina
    # Title bar adds ~56px at top
    title_bar = 56
    game_left = 40  # Small margin from left edge
    game_right = bounds['width'] - 40  # ~1560 at 2x
    game_top = title_bar + 40  # ~96, accounting for Score/Speed text
    game_bottom = title_bar + 1200 - 40  # ~1216 at 2x

    center_x = bounds['width'] // 2
    center_y = (game_top + game_bottom) // 2

    # Use tracked position as snake position
    sx, sy = _tracker.get_position()

    # Override with detected position if available
    if self_pos:
        sx, sy, _ = self_pos
        # Also update tracker to match detection
        _tracker.x, _tracker.y = sx, sy

    dx = tx - sx
    dy = ty - sy

    move = None

    # Check if WE are in danger zone (near walls)
    danger_left = sx < game_left + 100
    danger_right = sx > game_right - 100
    danger_top = sy < game_top + 100
    danger_bottom = sy > game_bottom - 100

    # Check if target is safe
    target_safe = (game_left + 150 < tx < game_right - 150 and
                   game_top + 150 < ty < game_bottom - 150)

    if strategy == 'chase':
        # Validate target is within game bounds (with some margin for detection noise)
        target_valid = (game_left - 50 < tx < game_right + 50 and
                       game_top - 50 < ty < game_bottom + 50)

        if not target_valid:
            if DEBUG:
                print(f"  [Invalid target: ({tx},{ty}) outside ({game_left},{game_top})-({game_right},{game_bottom})]")
            # Invalid target - go toward center safely
            if sx > center_x + 100:
                move = 'left'
            elif sx < center_x - 100:
                move = 'right'
            elif sy > center_y + 100:
                move = 'up'
            else:
                move = 'down'
            _tracker.update(move)
            return move

        wall_margin = 200  # Turn when this close to wall (increased for safety)

        # Check if we're about to hit a wall (only if wall avoidance enabled)
        if avoid_walls:
            about_to_hit_right = sx > game_right - wall_margin
            about_to_hit_left = sx < game_left + wall_margin
            about_to_hit_bottom = sy > game_bottom - wall_margin
            about_to_hit_top = sy < game_top + wall_margin
        else:
            about_to_hit_right = about_to_hit_left = about_to_hit_bottom = about_to_hit_top = False

        # Get current direction
        curr_dir = _current_direction

        # Define opposite directions
        opposite = {'up': 'down', 'down': 'up', 'left': 'right', 'right': 'left'}

        # Helper: get perpendicular directions that are safe
        def get_safe_perpendicular(curr):
            if curr in ['left', 'right']:
                perps = []
                if not about_to_hit_top:
                    perps.append('up')
                if not about_to_hit_bottom:
                    perps.append('down')
                # Prefer direction toward target
                if 'up' in perps and 'down' in perps:
                    return 'up' if dy < 0 else 'down'
                return perps[0] if perps else None
            else:  # up or down
                perps = []
                if not about_to_hit_left:
                    perps.append('left')
                if not about_to_hit_right:
                    perps.append('right')
                # Prefer direction toward target
                if 'left' in perps and 'right' in perps:
                    return 'left' if dx < 0 else 'right'
                return perps[0] if perps else None

        # Priority 1: Wall avoidance - if about to hit wall, turn immediately
        if curr_dir == 'right' and about_to_hit_right:
            move = get_safe_perpendicular('right')
        elif curr_dir == 'left' and about_to_hit_left:
            move = get_safe_perpendicular('left')
        elif curr_dir == 'down' and about_to_hit_bottom:
            move = get_safe_perpendicular('down')
        elif curr_dir == 'up' and about_to_hit_top:
            move = get_safe_perpendicular('up')

        # Priority 2: Check if we've overshot significantly
        # Only turn perpendicular if we're far past the target on our current axis
        # Use 100px threshold to avoid over-correcting when close
        if move is None:
            overshoot_amount = 0
            if curr_dir == 'right' and dx < 0:  # Going right but target is left
                overshoot_amount = -dx  # How far past we are
            elif curr_dir == 'left' and dx > 0:  # Going left but target is right
                overshoot_amount = dx
            elif curr_dir == 'down' and dy < 0:  # Going down but target is up
                overshoot_amount = -dy
            elif curr_dir == 'up' and dy > 0:  # Going up but target is down
                overshoot_amount = dy

            # Only react if we've overshot by more than 100px (significant overshoot)
            if overshoot_amount > 100 and curr_dir:
                # Turn perpendicular instead of reversing
                move = get_safe_perpendicular(curr_dir)
                if DEBUG and move:
                    print(f"  [Overshoot by {overshoot_amount}px: turning {move}]")

        # Priority 3: Normal chase - move toward target
        # Use tighter thresholds when closer for more precise targeting
        close_threshold = 25  # Use fine control when within 50px
        far_threshold = 50    # Use coarse control when further

        if move is None:
            # Determine which threshold to use based on distance
            dist = (dx**2 + dy**2) ** 0.5
            threshold = close_threshold if dist < 100 else far_threshold

            # Prefer to align on one axis first, then close in
            if abs(dx) > abs(dy):
                # Target is more horizontal - move horizontal first
                if dx > threshold and not about_to_hit_right and curr_dir != 'left':
                    move = 'right'
                elif dx < -threshold and not about_to_hit_left and curr_dir != 'right':
                    move = 'left'
                elif dy > threshold and not about_to_hit_bottom and curr_dir != 'up':
                    move = 'down'
                elif dy < -threshold and not about_to_hit_top and curr_dir != 'down':
                    move = 'up'
            else:
                # Target is more vertical - move vertical first
                if dy > threshold and not about_to_hit_bottom and curr_dir != 'up':
                    move = 'down'
                elif dy < -threshold and not about_to_hit_top and curr_dir != 'down':
                    move = 'up'
                elif dx > threshold and not about_to_hit_right and curr_dir != 'left':
                    move = 'right'
                elif dx < -threshold and not about_to_hit_left and curr_dir != 'right':
                    move = 'left'

        # Priority 4: Very close to target - GO DIRECTLY to food
        if move is None and abs(dx) < 60 and abs(dy) < 60:
            dist = (dx**2 + dy**2) ** 0.5
            # When EXTREMELY close (< 35px), KEEP current direction ONLY if moving toward food
            # Check if current direction is closing distance
            moving_toward = False
            if curr_dir == 'right' and dx > 0:  # Food is to the right, going right
                moving_toward = True
            elif curr_dir == 'left' and dx < 0:  # Food is to the left, going left
                moving_toward = True
            elif curr_dir == 'down' and dy > 0:  # Food is below, going down
                moving_toward = True
            elif curr_dir == 'up' and dy < 0:  # Food is above, going up
                moving_toward = True

            if dist < 50 and curr_dir and moving_toward:
                move = curr_dir  # Keep going, we're closing in
                if DEBUG:
                    print(f"  [Very close ({int(dist)}px): maintaining {curr_dir}]")
            # When EXTREMELY close (< 25px), just keep going regardless of direction
            elif dist < 25 and curr_dir:
                move = curr_dir  # Momentum will carry us through
                if DEBUG:
                    print(f"  [Extremely close ({int(dist)}px): momentum {curr_dir}]")
            # When close (< 50px), beeline to target
            elif dist < 50:
                # Try primary direction first
                primary_set = False
                if abs(dx) >= abs(dy):
                    # Want to go horizontal
                    if dx > 0 and curr_dir != 'left':
                        move = 'right'
                        primary_set = True
                    elif dx < 0 and curr_dir != 'right':
                        move = 'left'
                        primary_set = True
                    # If can't go horizontal (would reverse), go vertical
                    if not primary_set:
                        if dy > 0 and curr_dir != 'up':
                            move = 'down'
                        elif dy < 0 and curr_dir != 'down':
                            move = 'up'
                        elif dy != 0:  # Any vertical is better than nothing
                            move = 'down' if curr_dir != 'up' else 'up'
                else:
                    # Want to go vertical
                    if dy > 0 and curr_dir != 'up':
                        move = 'down'
                        primary_set = True
                    elif dy < 0 and curr_dir != 'down':
                        move = 'up'
                        primary_set = True
                    # If can't go vertical, go horizontal
                    if not primary_set:
                        if dx > 0 and curr_dir != 'left':
                            move = 'right'
                        elif dx < 0 and curr_dir != 'right':
                            move = 'left'
                        elif dx != 0:
                            move = 'right' if curr_dir != 'left' else 'left'
            else:
                # Moderately close - check if moving toward food
                moving_toward = False
                if curr_dir == 'right' and dx > 0:
                    moving_toward = True
                elif curr_dir == 'left' and dx < 0:
                    moving_toward = True
                elif curr_dir == 'down' and dy > 0:
                    moving_toward = True
                elif curr_dir == 'up' and dy < 0:
                    moving_toward = True

                if moving_toward and curr_dir:
                    move = curr_dir
                elif curr_dir:
                    move = get_safe_perpendicular(curr_dir)
                    if DEBUG:
                        print(f"  [Close but moving away - turning {move}]")

        # Priority 5: Fallback - just keep going if safe
        if move is None and curr_dir:
            # Check if current direction is safe
            safe_to_continue = True
            if curr_dir == 'right' and about_to_hit_right:
                safe_to_continue = False
            elif curr_dir == 'left' and about_to_hit_left:
                safe_to_continue = False
            elif curr_dir == 'down' and about_to_hit_bottom:
                safe_to_continue = False
            elif curr_dir == 'up' and about_to_hit_top:
                safe_to_continue = False

            if safe_to_continue:
                move = curr_dir
            else:
                move = get_safe_perpendicular(curr_dir)

    elif strategy == 'flee':
        if axis in ['both', 'x'] and abs(dx) > 10:
            move = 'left' if dx > 0 else 'right'
        if axis in ['both', 'y'] and abs(dy) > 10:
            if move is None or abs(dy) > abs(dx):
                move = 'up' if dy > 0 else 'down'

    elif strategy == 'mirror':
        if axis in ['y', 'both'] and abs(dy) > 10:
            move = 'down' if dy > 0 else 'up'
        elif axis == 'x' and abs(dx) > 10:
            move = 'right' if dx > 0 else 'left'

    # Note: circle/patrol strategy is handled at the start of this function

    # Update position tracker
    _tracker.update(move)

    return move

def reset_tracker():
    """Reset tracker when game restarts."""
    global _tracker, _last_dir, _steps_since_turn
    if _tracker:
        _tracker.reset()
    # Reset circle state
    _last_dir = 'right'
    _steps_since_turn = 0

def main():
    print(f"Joystick starting: app={APP}, target={TARGET_COLOR}, self={SELF_COLOR}, strategy={STRATEGY}")

    # Activate the app
    activate_app(APP)
    time.sleep(0.3)

    # Get window info
    window_info = get_window_info(APP)
    if not window_info:
        print(f"ERROR: Could not find window for app: {APP}")
        sys.exit(1)

    print(f"Window found: {window_info['width']}x{window_info['height']} points (id={window_info['id']})")
    # Capture one frame to check actual image dimensions
    test_result = capture_window(window_info['id'])
    if test_result[0] is not None:
        _, img_w, img_h, _ = test_result
        print(f"Image capture: {img_w}x{img_h} pixels (scale: {img_w/window_info['width']:.1f}x)")

    keys = KEY_MAP.get(KEYS, KEY_MAP['arrows'])
    frame_time = 1.0 / FPS
    end_time = time.time() + DURATION
    frame_count = 0

    print(f"Running for {DURATION}s at {FPS} FPS...")
    print("---")

    # Clean up old screenshots from previous runs
    for pattern in ['/tmp/snake_gameover_*.png', '/tmp/snake_death_*.png']:
        for old_file in glob.glob(pattern):
            try:
                os.remove(old_file)
            except:
                pass

    games_played = 0
    total_frames = 0
    game_over_frames = 0  # Consecutive frames with game over detected
    GAME_OVER_THRESHOLD = 3  # Require 3 consecutive frames to confirm game over
    game_over_screenshots = []  # List of (frame_num, filepath) for OCR at end
    death_screenshots = []  # List of (game_num, filepath) - frame before game over
    last_frame_path = None  # Track last frame for final score if no game over
    # Keep buffer of recent gameplay frames (before game over detection)
    recent_frames = []  # Buffer of last N gameplay frame paths
    FRAME_BUFFER_SIZE = 5

    try:
        while time.time() < end_time:
            frame_start = time.time()

            # Capture window
            result = capture_window(window_info['id'])
            if result[0] is None:
                if DEBUG:
                    print("Failed to capture window")
                time.sleep(frame_time)
                continue

            pixel_data, width, height, bpp = result

            # Check for game over (require consecutive frames to avoid false positives)
            is_game_over = detect_game_over(pixel_data, width, height, bpp)

            if is_game_over:
                game_over_frames += 1
                if game_over_frames >= GAME_OVER_THRESHOLD:
                    import shutil
                    # Check if this is a real game (had gameplay frames) or leftover screen
                    # Use the oldest frame in buffer (furthest from game over)
                    death_frame = recent_frames[0] if recent_frames else None
                    if death_frame and os.path.exists(death_frame):
                        # Real game - count it and save death frame
                        games_played += 1
                        death_path = f'/tmp/snake_death_{games_played}.png'
                        shutil.copy(death_frame, death_path)
                        death_screenshots.append((games_played, death_path))
                        # Save game over frame for OCR score extraction
                        go_frame_path = f'/tmp/snake_gameover_{games_played}.png'
                        current_frame = f'/tmp/snake_frame_{total_frames:04d}.png'
                        if DEBUG and os.path.exists(current_frame):
                            shutil.copy(current_frame, go_frame_path)
                            game_over_screenshots.append((games_played, go_frame_path))
                        if DEBUG:
                            print(f"Game Over! (game {games_played}) - death: {death_path}")
                    else:
                        # Leftover game over screen from previous session - skip it
                        if DEBUG:
                            print(f"Skipping leftover game over screen (no gameplay frames)")
                    send_restart_key(APP)
                    reset_tracker()  # Reset position tracking for new game
                    reset_direction_state()  # Reset direction tracking
                    frame_count = 0
                    game_over_frames = 0  # Reset counter
                    recent_frames = []  # Clear the buffer for next game
                    continue
            else:
                # Not game over - this is a gameplay frame
                # Add to rolling buffer of recent frames
                if DEBUG:
                    frame_path = f'/tmp/snake_frame_{total_frames:04d}.png'
                    recent_frames.append(frame_path)
                    # Keep only last N frames
                    if len(recent_frames) > FRAME_BUFFER_SIZE:
                        recent_frames.pop(0)
                game_over_frames = 0  # Reset counter

            # Find target and self positions
            target_pos = find_color_center(pixel_data, width, height, TARGET_COLOR, bpp)
            self_pos = find_color_center(pixel_data, width, height, SELF_COLOR, bpp)

            # For chase strategy, offset centroid toward direction of travel to approximate head
            # Snake head is ~40px ahead of centroid in the direction of movement
            HEAD_OFFSET = 40
            if STRATEGY == 'chase' and _current_direction and self_pos:
                sx, sy, sc = self_pos
                if _current_direction == 'right':
                    self_pos = (sx + HEAD_OFFSET, sy, sc)
                elif _current_direction == 'left':
                    self_pos = (sx - HEAD_OFFSET, sy, sc)
                elif _current_direction == 'up':
                    self_pos = (sx, sy - HEAD_OFFSET, sc)
                elif _current_direction == 'down':
                    self_pos = (sx, sy + HEAD_OFFSET, sc)

            # Calculate move
            move = calculate_move(target_pos, self_pos, STRATEGY, AXIS,
                                  {'width': width, 'height': height}, AVOID_WALLS)

            # Execute move using smart key delivery
            key_sent = False
            if move:
                key_sent = smart_press_key(move, APP, keys)

            if DEBUG:
                dir_info = f"[dir={_current_direction}]" if _current_direction else "[dir=None]"
                sent_info = " *SENT*" if key_sent else ""
                # Calculate distance and add warnings
                extra_info = ""
                if target_pos and self_pos:
                    tx, ty, tc = target_pos
                    sx, sy, sc = self_pos
                    dist = int(((tx - sx) ** 2 + (ty - sy) ** 2) ** 0.5)
                    dx, dy = tx - sx, ty - sy
                    extra_info = f" dist={dist} delta=({dx},{dy})"
                    # Warn if target has unusual pixel count (might be snake)
                    if tc > 50:
                        extra_info += " [!target_count_high]"
                print(f"Frame {frame_count}: target={target_pos}, self={self_pos}, move={move} {dir_info}{sent_info}{extra_info}")

            # Track last frame path for final score OCR
            if DEBUG:
                last_frame_path = f'/tmp/snake_frame_{total_frames:04d}.png'

            frame_count += 1
            total_frames += 1

            # Maintain frame rate
            elapsed = time.time() - frame_start
            if elapsed < frame_time:
                time.sleep(frame_time - elapsed)

    except KeyboardInterrupt:
        print("\nInterrupted by user")

    print("---")
    print(f"Joystick finished: {total_frames} frames, {games_played} restarts")

    # OCR score extraction from screenshots using ocr_find.py
    def extract_score_ocr(image_path):
        """Extract score from screenshot using macOS Vision OCR via ocr_find.py."""
        import re
        import json
        try:
            # Use ocr_find.py which uses macOS Vision framework
            ocr_script = '${PROJECT_ROOT}/lib/ocr_find.py'
            python_path = '${PROJECT_ROOT}/venv/bin/python'

            result = subprocess.run(
                [python_path, ocr_script, image_path, '--find', 'Score', '--json'],
                capture_output=True, text=True, timeout=15
            )

            if result.returncode == 0 and result.stdout.strip():
                data = json.loads(result.stdout)
                text = data.get('text', '')

                # Extract number from "Final Score: XX" or "Score: XX"
                match = re.search(r'(\d+)', text)
                if match:
                    return int(match.group(1))

            if DEBUG and result.stderr:
                print(f"  OCR stderr: {result.stderr[:100]}")
            return None
        except Exception as e:
            if DEBUG:
                print(f"  OCR error on {image_path}: {e}")
            return None

    # Extract scores from game over screenshots
    scores = []
    for game_num, go_path in game_over_screenshots:
        score = extract_score_ocr(go_path)
        if score is not None:
            scores.append(score)
            print(f"Game {game_num}: Score {score}")
        else:
            print(f"Game {game_num}: Score unknown (OCR failed)")

    # Get final score from last frame if game was still running
    final_score = None
    if last_frame_path and os.path.exists(last_frame_path):
        final_score = extract_score_ocr(last_frame_path)
        if final_score is not None:
            scores.append(final_score)
            print(f"Final (in progress): Score {final_score}")

    # Analyze death causes from death screenshots
    def analyze_death_cause(image_path, game_width, game_height):
        """Analyze death frame to determine cause: wall or self collision."""
        from PIL import Image
        try:
            img = Image.open(image_path)
            width, height = img.size
            pixels = img.load()

            # Game boundaries (approximate, accounting for title bar)
            margin = 120  # pixels from edge to consider "wall collision" (increased for accuracy)
            title_bar = 100  # Skip title bar area

            # Find snake pixels (look for saturated colored pixels)
            snake_pixels = []
            for y in range(title_bar, height):
                for x in range(width):
                    r, g, b = pixels[x, y][:3]
                    max_val = max(r, g, b)
                    min_val = min(r, g, b)
                    # Saturated color = snake
                    if max_val > 150 and (max_val - min_val) > 80:
                        # Not green food
                        if not (g > 180 and r < 100 and b < 80):
                            snake_pixels.append((x, y))

            if not snake_pixels:
                return "unknown", "No snake detected"

            # Find bounding box of snake
            xs = [p[0] for p in snake_pixels]
            ys = [p[1] for p in snake_pixels]
            min_x, max_x = min(xs), max(xs)
            min_y, max_y = min(ys), max(ys)

            # Check for wall collision (any part of snake near edge)
            wall_hit = []
            if min_x < margin:
                wall_hit.append("left")
            if max_x > width - margin:
                wall_hit.append("right")
            if min_y < title_bar + margin:
                wall_hit.append("top")
            if max_y > height - margin:
                wall_hit.append("bottom")

            if wall_hit:
                return "wall", f"Hit {'+'.join(wall_hit)} wall (snake at x={min_x}-{max_x}, y={min_y}-{max_y})"

            # If not wall, likely self-collision
            return "self", f"Likely self-collision (snake at x={min_x}-{max_x}, y={min_y}-{max_y})"

        except Exception as e:
            return "error", str(e)

    # Print death analysis
    if death_screenshots:
        print(f"\n--- DEATH ANALYSIS ---")
        wall_deaths = 0
        self_deaths = 0
        for game_num, death_path in death_screenshots:
            cause, detail = analyze_death_cause(death_path, width, height)
            if cause == "wall":
                wall_deaths += 1
            elif cause == "self":
                self_deaths += 1
            print(f"Game {game_num}: {cause.upper()} - {detail}")
            print(f"  Death frame: {death_path}")

        print(f"\nSummary: {wall_deaths} wall collisions, {self_deaths} self collisions")

    # Report best score
    if scores:
        best_score = max(scores)
        print(f"---")
        print(f"BEST SCORE: {best_score}")
    else:
        print(f"No scores extracted (OCR failed or no games completed)")

if __name__ == '__main__':
    main()
PYEOF
