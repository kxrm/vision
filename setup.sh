#!/bin/bash
# Vision Tools Setup Script
# Creates virtual environment and installs dependencies

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Handle --permissions flag
if [[ "${1:-}" == "--permissions" ]]; then
    exec "$SCRIPT_DIR/bin/permissions.sh" --grant
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat << 'EOF'
Vision Tools Setup

USAGE:
    ./setup.sh                # Install dependencies and set up environment
    ./setup.sh --permissions  # Run interactive permission setup
    ./setup.sh -h, --help     # Show this help

After running setup, you may need to grant macOS permissions:
    ./bin/permissions.sh      # Check permission status
    ./bin/permissions.sh --grant  # Guided permission setup
EOF
    exit 0
fi

echo "Setting up Vision Tools..."

# Check Python version
PYTHON_CMD="${PYTHON:-python3}"
if ! command -v "$PYTHON_CMD" &> /dev/null; then
    echo "Error: Python 3 not found. Install Python 3.11+ to continue."
    exit 1
fi

PYTHON_VERSION=$("$PYTHON_CMD" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
echo "Using Python $PYTHON_VERSION"

# Create venv if not exists
if [[ ! -d "$SCRIPT_DIR/venv" ]]; then
    echo "Creating virtual environment..."
    "$PYTHON_CMD" -m venv "$SCRIPT_DIR/venv"
fi

# Install dependencies
echo "Installing Python dependencies..."
"$SCRIPT_DIR/venv/bin/pip" install --upgrade pip -q
"$SCRIPT_DIR/venv/bin/pip" install -r "$SCRIPT_DIR/requirements.txt" -q

# Make scripts executable
chmod +x "$SCRIPT_DIR/bin/"*.sh 2>/dev/null || true

# Check for external dependencies
echo ""
echo "Checking external dependencies..."

if command -v cliclick &> /dev/null; then
    echo "  [OK] cliclick"
else
    echo "  [MISSING] cliclick - Install with: brew install cliclick"
fi

if command -v ffmpeg &> /dev/null; then
    echo "  [OK] ffmpeg"
else
    echo "  [MISSING] ffmpeg - Install with: brew install ffmpeg (required for webcam)"
fi

if command -v uvcc &> /dev/null; then
    echo "  [OK] uvcc"
else
    echo "  [OPTIONAL] uvcc - Install with: npm install -g uvcc (for PTZ camera control)"
fi

echo ""
echo "Setup complete! Tools available at ./bin/"
echo ""
echo "Quick start:"
echo "  ./bin/screenshot.sh              # Capture screenshot"
echo "  ./bin/interact.sh --help         # See interaction options"
echo "  ./bin/snapshot.sh                # Capture webcam"
echo "  ./bin/joystick.sh --help         # Game controller"
echo ""
echo "Permissions:"
echo "  ./bin/permissions.sh             # Check macOS permission status"
echo "  ./bin/permissions.sh --grant     # Guided permission setup"
