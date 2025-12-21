---
name: webcam
description: Capture webcam snapshots with PTZ camera control
---

# Webcam Skill

Capture webcam photos and control pan/tilt/zoom for Insta360 Link 2 cameras.

## Usage

```
/webcam                          # Take snapshot
/webcam --look 45 -20            # Point camera (pan, tilt in degrees)
/webcam --zoom 2.0               # Set zoom level (1.0-4.0)
/webcam --center                 # Center on user
/webcam --ptz                    # Show current PTZ position
/webcam --grid                   # Add grid to latest snapshot
```

## PTZ Control

| Argument | Description | Range |
|----------|-------------|-------|
| `--pan <deg>` | Set pan angle | -145 to +145 |
| `--tilt <deg>` | Set tilt angle | -90 to +100 |
| `--zoom <level>` | Set zoom | 1.0 to 4.0 |
| `--look <pan> <tilt>` | Set pan and tilt together | |
| `--center` | Center camera on user | |
| `--reset` | Reset to center with 1x zoom | |
| `--status` | Show current position | |

## Requirements

- **ffmpeg**: Required for video capture (`brew install ffmpeg`)
- **uvcc**: Optional for PTZ control (`npm install -g uvcc`)

Without uvcc, snapshots work but PTZ controls are unavailable.

## Output

Snapshots are saved to `/tmp/snapshot_YYYYMMDD_HHMMSS.jpg`

## Implementation

```bash
./bin/snapshot.sh $ARGS
```
