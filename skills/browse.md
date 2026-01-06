---
name: browse
description: Web browsing and UI interaction via OCR
---

# Browse Skill

Navigate web browsers and interact with UI elements using OCR-based vision.

## Quick Commands

```
/browse go reddit.com            # Navigate to URL
/browse click "Sign In"          # Click text via OCR
/browse read                     # Read current page content
/browse scroll down              # Scroll page
/browse type "search query"      # Type into focused field
```

## Full Usage

This skill wraps `interact.sh` with simplified commands:

| Command | Description | Equivalent |
|---------|-------------|------------|
| `go <url>` | Navigate to URL (reuses existing tab) | `--chain "browse:<url>"` |
| `click <text>` | Click text via OCR | `--click-text "<text>"` |
| `click <text> near <anchor>` | Click text near anchor | `--near "<anchor>" --click-text "<text>"` |
| `read` | Read page content | `--read-page` |
| `scroll <dir>` | Scroll (up/down/left/right) | `--scroll <dir> page` |
| `type <text>` | Type text | `--type "<text>"` |
| `key <key>` | Press key | `--key <key>` |
| `combo <keys>` | Key combination | `--combo <keys>` |

## Browser Context

The skill automatically manages `--in-app` context. Specify browser with:

```
/browse --app Firefox go reddit.com
/browse --app "Google Chrome" click "Sign In"
```

Default: Firefox

## Examples

```
# Navigate and interact
/browse go news.ycombinator.com
/browse click "new"
/browse scroll down

# Handle multiple matches with context
/browse click "comments" near "Show HN"

# Read page for analysis
/browse read
```

## Implementation

```bash
# go command (uses browse: for smart tab reuse)
./bin/interact.sh --in-app "$APP" --chain "browse:$URL"

# click command
./bin/interact.sh --in-app "$APP" --click-text "$TEXT"

# click near command
./bin/interact.sh --in-app "$APP" --near "$ANCHOR" --click-text "$TEXT"

# read command
./bin/interact.sh --in-app "$APP" --read-page

# scroll command
./bin/interact.sh --in-app "$APP" --scroll $DIR page

# type command
./bin/interact.sh --in-app "$APP" --type "$TEXT"
```
