# Vision Tools

Vision-based automation tools for macOS. Enables LLMs to see and interact with the desktop through screenshots, OCR, mouse/keyboard control, and webcam capture.

## Features

- **Screenshot Capture**: Full screen, app windows, regions, with coordinate grids
- **OCR-Based Interaction**: Click on text, read pages, find elements
- **Mouse & Keyboard**: Clicks, typing, key combos, scrolling
- **Webcam with PTZ**: Capture snapshots, control pan/tilt/zoom
- **Game Controller**: Vision-based autonomous gameplay

## Quick Start

```bash
# Setup
./setup.sh

# Take a screenshot
./bin/screenshot.sh

# Read a webpage
./bin/interact.sh --in-app Firefox --read-page

# Click on text
./bin/interact.sh --in-app Firefox --click-text "Sign In"

# Take a webcam snapshot
./bin/snapshot.sh
```

## Installation

### Prerequisites

- macOS 12+ (uses Vision framework, Accessibility API)
- Python 3.11+
- Homebrew

### Required Tools

```bash
brew install cliclick    # Mouse/keyboard automation
brew install ffmpeg      # Webcam capture
```

### Optional Tools

```bash
npm install -g uvcc      # PTZ camera control (Insta360 Link 2)
```

### Setup

```bash
./setup.sh
```

This creates a Python virtual environment and installs dependencies.

### Permissions

macOS requires explicit permission grants:

| Permission | Required By |
|------------|-------------|
| Screen Recording | screenshot.sh, interact.sh, joystick.sh |
| Accessibility | interact.sh, joystick.sh |
| Camera | snapshot.sh |

**Check permission status:**
```bash
./bin/permissions.sh
```

**Interactive setup walkthrough:**
```bash
./bin/permissions.sh --grant
# Or via setup.sh:
./setup.sh --permissions
```

**Open all permission panes at once:**
```bash
./bin/permissions.sh --open-all
```

Each tool also has `--status` to check its specific requirements:
```bash
./bin/screenshot.sh --status
./bin/interact.sh --status
```

## Tools

| Tool | Purpose |
|------|---------|
| `./bin/screenshot.sh` | Desktop screenshots |
| `./bin/interact.sh` | Mouse, keyboard, OCR, app control |
| `./bin/snapshot.sh` | Webcam capture with PTZ |
| `./bin/joystick.sh` | Vision-based game controller |

## Documentation

See [CLAUDE.md](CLAUDE.md) for detailed usage, examples, and best practices.

## Project Structure

```
vision/
├── bin/           # CLI tools (shell scripts)
├── lib/           # Python support library
├── skills/        # Claude Code skills
├── agents/        # Subagent definitions
├── docs/          # Extended documentation
└── venv/          # Python virtual environment (not in git)
```

## Claude Code Integration

### Skills

```
/screenshot              # Capture screenshots
/browse go reddit.com    # Web interaction
/webcam                  # Webcam capture
/game --in-app Snake     # Game controller
```

### Subagents

```
/agent game-controller   # Autonomous game player
```

## Examples

### Web Browsing

```bash
# Navigate to a URL
./bin/interact.sh --chain "in-app:Firefox" "combo:cmd+l" "paste:news.ycombinator.com" "key:return"

# Read page content
./bin/interact.sh --in-app Firefox --read-page

# Click with disambiguation
./bin/interact.sh --in-app Firefox --near "Show HN" --click-text "comments"
```

### Screenshot with Grid

```bash
./bin/screenshot.sh --in-app Safari
./bin/screenshot.sh --grid
```

### Webcam PTZ

```bash
./bin/snapshot.sh --look 45 -20    # Pan right, tilt down
./bin/snapshot.sh --zoom 2.0       # Zoom in
./bin/snapshot.sh                  # Take photo
```

### Game Automation

```bash
./bin/joystick.sh --in-app "Python" --target green --self blue --strategy chase --duration 60
```
