---
name: bubble
description: Display floating chat bubble for user communication outside terminal
---

# Bubble - Floating Chat Interface

Display a lightweight, borderless floating bubble for communicating with users outside the terminal. The bubble supports text messages, images, reactions, and text replies.

## Quick Start

```bash
# Show a message (non-blocking)
./bin/bubble.sh --show "Hello! How can I help?"

# Show and wait for response (blocking)
response=$(./bin/bubble.sh --show "What's your name?" --wait)

# Append to conversation (chat-style)
./bin/bubble.sh --append "Working on that..."
./bin/bubble.sh --append "Done! Any questions?" --wait

# Dismiss when done
./bin/bubble.sh --dismiss
```

## Commands

### Display Bubble

```bash
./bin/bubble.sh --show "Your message here"
./bin/bubble.sh --show "With image" --image /tmp/screenshot.jpg
./bin/bubble.sh --show "Positioned" --position 50,50
```

### Read User Response

```bash
# Block until user responds
response=$(./bin/bubble.sh --read)

# Non-blocking check
response=$(./bin/bubble.sh --read-nowait)
```

### Update Message

```bash
# Replace message (clears chat history)
./bin/bubble.sh --update "New message content"
```

### Append Message (Chat-style)

```bash
# Add to conversation history (shows last 6 messages)
./bin/bubble.sh --append "I found 3 issues in your code."
./bin/bubble.sh --append "Would you like me to fix them?"
./bin/bubble.sh --append "All done!" --wait  # Append and wait for response

# Append and reposition with arrow
./bin/bubble.sh --append "Look here!" --point-at 50,30 --arrow right --in-app Firefox
```

### Wait for Response

```bash
# Combine --wait with show/update/append to block until user responds
response=$(./bin/bubble.sh --show "Question?" --wait)
response=$(./bin/bubble.sh --append "Ready?" --wait)
```

### Dismiss

```bash
./bin/bubble.sh --dismiss
```

### Move Bubble

```bash
# Animate bubble to new position
./bin/bubble.sh --move 50,50
./bin/bubble.sh --move 30,70 --in-app Firefox  # App-relative coordinates
```

### Clear Arrow

```bash
# Remove arrow from bubble (required before scrolling/changing content)
./bin/bubble.sh --clear-arrow
```

### Debug

```bash
# Show bubble state, response files, and process status
./bin/bubble.sh --debug
```

## Response Format

Responses are JSON with an `action` field:

```json
// User clicked reply and typed text
{"action": "reply", "text": "user input here", "timestamp": "..."}

// User clicked an emoji reaction
{"action": "reaction", "emoji": "👍", "timestamp": "..."}

// User clicked done (dismisses bubble)
{"action": "done", "timestamp": "..."}
```

## User Interface

The bubble shows:
- **Message text** - Auto-sizes to content
- **💬 Reply icon** - Click to open text input
- **☺ Reaction icon** - Click to show emoji picker

### Emoji Picker Options
- 👍 thumbsup
- 👎 thumbsdown
- ✓ yes
- ✗ no
- ❤️ heart
- ❓ question
- ⏹ done (dismisses bubble)

## Behavior

- **Reactions keep bubble open** - Only ⏹ (done) dismisses
- **Replies keep bubble open** - User can send multiple replies
- **Dark/Light mode** - Respects system appearance
- **Draggable** - User can move bubble anywhere
- **Always on top** - Floats above other windows

## Continuous Conversation Example

```bash
#!/bin/bash

# Start conversation
./bin/bubble.sh --show "What would you like me to help with?"

while true; do
    # Wait for user response
    response=$(./bin/bubble.sh --read)
    action=$(echo "$response" | jq -r '.action')

    if [[ "$action" == "done" ]]; then
        break
    elif [[ "$action" == "reply" ]]; then
        text=$(echo "$response" | jq -r '.text')
        ./bin/bubble.sh --append "Working on: $text"
        # Do work...
        ./bin/bubble.sh --append "Done! Anything else?"
    elif [[ "$action" == "reaction" ]]; then
        emoji=$(echo "$response" | jq -r '.emoji')
        ./bin/bubble.sh --append "Thanks for the $emoji!"
    fi
done

./bin/bubble.sh --dismiss
```

## Simpler Pattern with --wait

```bash
#!/bin/bash

# Show and wait in one command
response=$(./bin/bubble.sh --show "What's your name?" --wait)
name=$(echo "$response" | jq -r '.text')

./bin/bubble.sh --append "Nice to meet you, $name!"
./bin/bubble.sh --append "What can I help with?" --wait
# ... continue conversation
./bin/bubble.sh --dismiss
```

## Options Reference

| Option | Description |
|--------|-------------|
| `--show <msg>` | Display bubble with message (reuses existing bubble if running) |
| `--append <msg>` | Add message to chat history |
| `--update <msg>` | Replace message (clears chat history) |
| `--move <x>,<y>` | Animate bubble to new position |
| `--clear-arrow` | Remove arrow from bubble |
| `--wait` | Block until user responds (use with show/append/update) |
| `--read` | Wait for user response (standalone blocking) |
| `--read-nowait` | Check for response (non-blocking) |
| `--dismiss` | Close the bubble (only when session complete) |
| `--debug` | Show bubble state and process status |
| `--image <path>` | Include image in message |
| `--crop <x>,<y>,<w>,<h>` | Crop image (% 0-100 or pixels if >100) |
| `--screenshot` | Take screenshot as image (use with --append) |
| `--screenshot-crop <x>,<y>,<w>,<h>` | Screenshot + crop in one command |
| `--position <x>,<y>` | Initial position (grid % 0-100) |
| `--point-at <x>,<y>` or `<x>,<y>,<w>,<h>` | Point arrow at coordinates or bounding box (use with `--in-app`) |
| `--point-at-text <text>` | Point arrow at text found via OCR (requires `--in-app`) |
| `--near <text>` | Find text closest to anchor (use with `--point-at-text`) |
| `--arrow <direction>` | Hint arrow direction: left, right, up, down |
| `--in-app <name>` | Target app for coordinate translation |
| `--status` | Show dependencies (no args) or set status line (`--status "text"`) |

## Pointing at UI Elements

Use `--point-at` to have the bubble arrow point at specific elements on screen. Coordinates are grid percentages (0-100) within the target app window.

### Point at Coordinates

```bash
# Point at a specific location (arrow tip lands on coordinates)
./bin/bubble.sh --show "Click here!" --point-at 50,30 --in-app Firefox
```

### Point at Bounding Box (Recommended for LLMs)

When pointing at text or UI elements, use `--point-at` with 4 values (bounding box from OCR). This ensures the bubble never obscures the target content - it positions outside the box automatically.

```bash
# Get precise bounding box from OCR
./bin/interact.sh --in-app Firefox --find-text "Submit" --instance 1
# Output: Found 'Submit' at grid: 45.2,67.8,8.5,2.1

# Extract just the coordinates
bbox=$(./bin/interact.sh --in-app Firefox --find-text "Submit" --instance 1 2>/dev/null | sed 's/.*grid: //')

# Point at the box - bubble positions outside it automatically
./bin/bubble.sh --show "Click this button" --point-at "$bbox" --in-app Firefox
```

**Note:** Use `--instance 1` (or higher) when multiple matches exist. The `--find-text` command returns a precise bounding box for the matched word, not the entire line.

### Point at Text Directly (Recommended)

Use `--point-at-text` for a simpler one-step workflow that handles OCR lookup internally:

```bash
# Simple - point at text by content
./bin/bubble.sh --show "Click this button" --point-at-text "Submit" --in-app Firefox

# With disambiguation - find "comments" near a specific article
./bin/bubble.sh --append "Check these comments" --point-at-text "comments" --near "Pure Silicon" --in-app Firefox
```

This is equivalent to the two-step `--find-text` + `--point-at` workflow above, but in a single command. Use `--near` when the target text appears multiple times on the page.

### Arrow Direction Hints

By default, the bubble uses smart positioning to pick the arrow direction. Use `--arrow` to override:

```bash
# Force arrow to point from the left (bubble appears to the right of target)
./bin/bubble.sh --show "Over here" --point-at 20,50,10,5 --arrow left --in-app Firefox

# Force arrow to point from above (bubble appears below target)
./bin/bubble.sh --show "Down here" --point-at 50,20 --arrow up --in-app Firefox
```

Arrow directions:
- `left` - Arrow points left, bubble is to the RIGHT of target
- `right` - Arrow points right, bubble is to the LEFT of target
- `up` - Arrow points up, bubble is BELOW target
- `down` - Arrow points down, bubble is ABOVE target

## LLM Guidance

### INFO Messages

The bubble outputs guidance messages to stderr:

**After `--show`:**
```
INFO: Bubble created. Use --append/--move/--update to interact. Only --dismiss when session complete or user requests.
```

**After `--point-at`:**
```
INFO: Bubble is now pointing at target. Remember to use --move or --clear-arrow before scrolling or changing page content.
```

### Important Behaviors

1. **Single Bubble Rule**: Only one bubble can exist at a time. Calling `--show` on an existing bubble sends an update command (does not create a new bubble).

2. **Bubble Reuse**: Prefer `--append`, `--move`, and `--update` for ongoing interaction. Only use `--dismiss` when the session is complete or the user requests it.

3. **Point-at Cleanup**: After using `--point-at`, you MUST use `--move` or `--clear-arrow` before:
   - Scrolling the page
   - Changing page content
   - The arrow becomes stale if the target moves

4. **Mutual Exclusivity**: `--move` and `--point-at` cannot be used together. If both are provided, `--point-at` takes precedence with a warning.

### Inline Images

Use `--screenshot-crop` with `--append` to embed cropped screenshots directly in the chat:

```bash
# Take screenshot of Firefox, crop region, embed in chat
./bin/bubble.sh --append "Here's what I see:" --screenshot-crop 30,40,25,20 --in-app Firefox
```

The crop coordinates are percentages (0-100) of the screenshot dimensions.

### Cropping Specific UI Elements (Recommended)

When cropping a specific text element, use `--near` with `--find-text` to get the precise bounding box. Without `--near`, OCR may find the wrong instance of the text.

```bash
# WRONG: May crop the wrong "comments" if multiple exist on page
bbox=$(./bin/interact.sh --in-app Firefox --find-text "comments" --instance 1 | sed 's/.*grid: //')

# CORRECT: Use --near to find "comments" in the action bar specifically
bbox=$(./bin/interact.sh --in-app Firefox --near "share save hide" --find-text "comments" | sed 's/.*grid: //')

# Crop just that element
./bin/bubble.sh --append "The comments link:" --screenshot-crop "$bbox" --in-app Firefox
```

**Tip:** The `--near` parameter finds the match closest to the anchor text, ensuring you get the right element even when the same text appears multiple times on the page.
