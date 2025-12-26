---
name: screenshot
description: Capture screenshots of displays, apps, or regions for visual analysis
---

# Screenshot Skill

Captures desktop screenshots for vision-based automation.

## Usage

```
/screenshot                      # Main display
/screenshot --in-app Safari      # Specific app window
/screenshot --display 2          # Second display
/screenshot --grid               # Add coordinate grid overlay
/screenshot --at-cursor 400      # 400x400 region around cursor
/screenshot --preview 50,50      # Preview where click at 50%,50% lands
```

## Arguments

| Argument | Description |
|----------|-------------|
| `--display <n>` | Capture specific display (1, 2, etc.) |
| `--all` | Capture all displays (separate files) |
| `--window` | Interactive window picker (click to select) |
| `--in-app <name>` | Capture window of named application |
| `--region` | Interactive rectangular selection |
| `--region <x,y,w,h>` | Capture specific coordinates |
| `--at-cursor [size]` | Region centered on cursor (default: 400px) |
| `--grid [file]` | Add grid overlay (to latest or specified file) |
| `--preview <x>,<y>` | Show where click at x%,y% would land |
| `--cursor` | Include mouse cursor |
| `--output <file>` | Custom output filename |
| `--format <jpg\|png>` | Output format (default: jpg) |
| `--full-res` | Skip resize (keeps original resolution) |
| `--list-windows` | List available windows |
| `--list-displays` | List displays with offsets |

## Output

Screenshots are saved to `/tmp/screenshot_YYYYMMDD_HHMMSS.jpg`

**Note:** Screenshots are resized to 1568px max by default (Anthropic API limit). Use `--full-res` for operations that need original resolution.

## Implementation

```bash
./bin/screenshot.sh $ARGS
```
