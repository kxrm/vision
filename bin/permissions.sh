#!/bin/bash
# permissions.sh - Manage macOS permissions for Vision Tools
#
# Usage:
#   ./permissions.sh              # Show permission status (default)
#   ./permissions.sh --grant      # Interactive walkthrough to grant missing permissions
#   ./permissions.sh --open-all   # Open all relevant System Settings panes at once

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# URL schemes for System Settings privacy panes
URL_SCREEN_RECORDING="x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
URL_ACCESSIBILITY="x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
URL_CAMERA="x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"

# Check Screen Recording permission
check_screen_recording() {
    local test_file="/tmp/screenshot_permission_test_$$.png"
    screencapture -x "$test_file" 2>/dev/null
    if [[ -f "$test_file" ]]; then
        rm -f "$test_file"
        return 0  # granted
    fi
    return 1  # denied
}

# Check Accessibility permission
check_accessibility() {
    local ax_test=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>&1)
    if [[ "$ax_test" != *"not allowed"* && "$ax_test" != *"error"* && -n "$ax_test" ]]; then
        return 0  # granted
    fi
    return 1  # denied
}

# Check Camera permission
check_camera() {
    local camera_test=$(ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -i "video")
    if [[ -n "$camera_test" ]]; then
        return 0  # granted
    fi
    return 1  # denied
}

# Show help
show_help() {
    cat << 'EOF'
Vision Tools Permission Manager

USAGE:
    permissions.sh [OPTIONS]

OPTIONS:
    (default)               Show permission status for all tools
    --grant                 Interactive walkthrough to grant missing permissions
    --open-all              Open all relevant System Settings panes at once
    -h, --help              Show this help message
    -s, --status            Same as default - show permission status

PERMISSIONS REQUIRED:
    Screen Recording        Required by: screenshot.sh, interact.sh, joystick.sh
    Accessibility           Required by: interact.sh, joystick.sh
    Camera                  Required by: snapshot.sh

EXAMPLES:
    ./bin/permissions.sh              # Check what's missing
    ./bin/permissions.sh --grant      # Guided setup for missing permissions
    ./bin/permissions.sh --open-all   # Open all panes to configure manually
EOF
}

# Show status of all permissions
show_status() {
    echo "=== Vision Tools Permissions ==="
    echo ""

    local all_ok=true

    # Screen Recording
    echo -n "Screen Recording: "
    if check_screen_recording; then
        echo "[OK] Granted"
    else
        echo "[DENIED]"
        echo "  Required by: screenshot.sh, interact.sh, joystick.sh"
        echo "  Enable in: System Settings > Privacy & Security > Screen Recording"
        all_ok=false
    fi
    echo ""

    # Accessibility
    echo -n "Accessibility: "
    if check_accessibility; then
        echo "[OK] Granted"
    else
        echo "[DENIED]"
        echo "  Required by: interact.sh, joystick.sh"
        echo "  Enable in: System Settings > Privacy & Security > Accessibility"
        all_ok=false
    fi
    echo ""

    # Camera
    echo -n "Camera: "
    if check_camera; then
        echo "[OK] Granted"
    else
        echo "[DENIED]"
        echo "  Required by: snapshot.sh"
        echo "  Enable in: System Settings > Privacy & Security > Camera"
        all_ok=false
    fi
    echo ""

    if $all_ok; then
        echo "Status: All permissions granted"
        return 0
    else
        echo "Status: Some permissions missing"
        echo ""
        echo "Run './bin/permissions.sh --grant' for guided setup"
        return 1
    fi
}

# Open all System Settings panes at once
open_all_panes() {
    echo "Opening System Settings panes..."
    echo ""
    echo "Please enable your terminal app in each pane that opens."
    echo ""

    open "$URL_SCREEN_RECORDING"
    sleep 0.5
    open "$URL_ACCESSIBILITY"
    sleep 0.5
    open "$URL_CAMERA"

    echo "Opened:"
    echo "  - Privacy & Security > Screen Recording"
    echo "  - Privacy & Security > Accessibility"
    echo "  - Privacy & Security > Camera"
    echo ""
    echo "After enabling permissions, you may need to restart your terminal."
}

# Interactive walkthrough to grant permissions
grant_permissions() {
    echo "=== Vision Tools Permission Setup ==="
    echo ""
    echo "This will walk you through granting the required macOS permissions."
    echo "You'll need to enable your terminal app in System Settings."
    echo ""

    local terminal_app
    # Try to detect the terminal app
    if [[ -n "$TERM_PROGRAM" ]]; then
        terminal_app="$TERM_PROGRAM"
    else
        terminal_app="your terminal app"
    fi

    local step=1
    local total=3
    local any_denied=false

    # Step 1: Screen Recording
    echo "[$step/$total] Screen Recording"
    echo "        Required by: screenshot.sh, interact.sh, joystick.sh"
    echo ""
    if check_screen_recording; then
        echo "        [OK] Already granted"
    else
        any_denied=true
        echo "        [DENIED] Opening System Settings..."
        echo ""
        open "$URL_SCREEN_RECORDING"
        echo "        Please enable \"$terminal_app\" in the list."
        echo "        (You may need to click the + button to add it)"
        echo ""
        read -p "        Press ENTER when done (or 's' to skip): " response
        echo ""
        if [[ "$response" != "s" ]]; then
            if check_screen_recording; then
                echo "        [OK] Screen Recording granted!"
            else
                echo "        [!] Still denied - you may need to restart your terminal"
            fi
        else
            echo "        Skipped"
        fi
    fi
    echo ""
    ((step++))

    # Step 2: Accessibility
    echo "[$step/$total] Accessibility"
    echo "        Required by: interact.sh, joystick.sh"
    echo ""
    if check_accessibility; then
        echo "        [OK] Already granted"
    else
        any_denied=true
        echo "        [DENIED] Opening System Settings..."
        echo ""
        open "$URL_ACCESSIBILITY"
        echo "        Please enable \"$terminal_app\" in the list."
        echo "        (You may need to click the + button to add it)"
        echo ""
        read -p "        Press ENTER when done (or 's' to skip): " response
        echo ""
        if [[ "$response" != "s" ]]; then
            if check_accessibility; then
                echo "        [OK] Accessibility granted!"
            else
                echo "        [!] Still denied - you may need to restart your terminal"
            fi
        else
            echo "        Skipped"
        fi
    fi
    echo ""
    ((step++))

    # Step 3: Camera
    echo "[$step/$total] Camera"
    echo "        Required by: snapshot.sh"
    echo ""
    if check_camera; then
        echo "        [OK] Already granted"
    else
        any_denied=true
        echo "        [DENIED] Opening System Settings..."
        echo ""
        open "$URL_CAMERA"
        echo "        Please enable \"$terminal_app\" in the list."
        echo ""
        read -p "        Press ENTER when done (or 's' to skip): " response
        echo ""
        if [[ "$response" != "s" ]]; then
            if check_camera; then
                echo "        [OK] Camera granted!"
            else
                echo "        [!] Still denied - you may need to restart your terminal"
            fi
        else
            echo "        Skipped"
        fi
    fi
    echo ""

    # Final status
    echo "=== Setup Complete ==="
    echo ""
    show_status

    if $any_denied; then
        echo ""
        echo "Note: If permissions still show as denied, try restarting your terminal."
    fi
}

# Main
case "${1:-}" in
    -h|--help)
        show_help
        ;;
    -s|--status|"")
        show_status
        ;;
    --grant)
        grant_permissions
        ;;
    --open-all)
        open_all_panes
        ;;
    *)
        echo "Unknown option: $1"
        echo ""
        show_help
        exit 1
        ;;
esac
