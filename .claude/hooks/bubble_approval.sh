#!/bin/bash
# Bubble approval hook for Claude Code tool permissions
# Routes permission requests to bubble GUI when active

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUBBLE="$PROJECT_ROOT/bin/bubble.sh"

# State file location
uid=$(id -u)
STATE_FILE="/tmp/bubble_state_${uid}.json"
RESPONSE_FILE="/tmp/bubble_response_${uid}.json"

# Whitelisted command patterns (skip approval for these)
# These match the patterns in settings.local.json permissions.allow
is_whitelisted_bash() {
    local cmd="$1"

    # Safe read-only commands
    if [[ "$cmd" =~ ^(grep|ls|cat|find|echo|head|tail|wc|file|which|pwd|date|id)[[:space:]] ]] || \
       [[ "$cmd" =~ ^(grep|ls|cat|find|echo|head|tail|wc|file|which|pwd|date|id)$ ]]; then
        return 0
    fi

    # Project bin scripts
    if [[ "$cmd" == ./bin/* ]] || [[ "$cmd" == /Users/jay/ai/vision/bin/* ]]; then
        return 0
    fi

    # Project venv python
    if [[ "$cmd" == ./venv/bin/python* ]] || [[ "$cmd" == /Users/jay/ai/vision/venv/bin/python* ]]; then
        return 0
    fi

    # Commands with env var prefixes (like DEBUG_OCR=1 ./bin/...)
    if [[ "$cmd" == *=*\ ./bin/* ]] || [[ "$cmd" == *=*\ ./venv/* ]]; then
        return 0
    fi

    # osascript (AppleScript)
    if [[ "$cmd" == osascript* ]]; then
        return 0
    fi

    # rm (allowed in settings)
    if [[ "$cmd" == rm ]] || [[ "$cmd" == rm\ * ]]; then
        return 0
    fi

    # cliclick
    if [[ "$cmd" == cliclick* ]]; then
        return 0
    fi

    # mkdir for /tmp/claude
    if [[ "$cmd" == "mkdir -p /tmp/claude"* ]]; then
        return 0
    fi

    return 1
}

# Check if bubble is running
is_bubble_running() {
    if [[ -f "$STATE_FILE" ]]; then
        local pid=$(grep -o '"pid": *[0-9]*' "$STATE_FILE" | grep -o '[0-9]*')
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# Wait for response with timeout (polling --read-nowait)
wait_response_timeout() {
    local timeout_secs="${1:-30}"
    local elapsed=0

    # Clear any stale response
    rm -f "$RESPONSE_FILE"

    while [[ $elapsed -lt $timeout_secs ]]; do
        local response=$("$BUBBLE" --read-nowait 2>/dev/null)
        if [[ -n "$response" && "$response" != "{}" ]]; then
            echo "$response"
            return 0
        fi
        sleep 1
        ((elapsed++))
    done

    # Timeout
    echo "{}"
    return 1
}

# Read tool info from stdin (JSON)
input=$(cat)

# If no bubble running, exit 0 (let normal flow happen)
if ! is_bubble_running; then
    exit 0
fi

# Extract tool info
tool_name=$(echo "$input" | jq -r '.tool_name // "Unknown"')
tool_input=$(echo "$input" | jq -r '.tool_input // {}')

# Check whitelist for Bash commands
if [[ "$tool_name" == "Bash" ]]; then
    cmd=$(echo "$tool_input" | jq -r '.command // ""')
    if is_whitelisted_bash "$cmd"; then
        # Whitelisted - skip approval, let normal flow happen
        exit 0
    fi
fi

# Check whitelist for Read commands (safe paths)
if [[ "$tool_name" == "Read" ]]; then
    file_path=$(echo "$tool_input" | jq -r '.file_path // ""')
    # Allow reads from /tmp/ (screenshots, etc.)
    if [[ "$file_path" == /tmp/* ]] || [[ "$file_path" == /private/tmp/* ]]; then
        exit 0
    fi
    # Allow reads from project directory
    if [[ "$file_path" == "$PROJECT_ROOT"/* ]]; then
        exit 0
    fi
fi

# Format concise message based on tool type
case "$tool_name" in
    Bash)
        cmd=$(echo "$tool_input" | jq -r '.command // ""' | head -c 100)
        desc=$(echo "$tool_input" | jq -r '.description // ""')
        detail="${desc:-$cmd}"
        ;;
    Write)
        detail=$(echo "$tool_input" | jq -r '.file_path // ""')
        ;;
    Edit)
        detail=$(echo "$tool_input" | jq -r '.file_path // ""')
        ;;
    NotebookEdit)
        detail=$(echo "$tool_input" | jq -r '.notebook_path // ""')
        ;;
    Read)
        detail=$(echo "$tool_input" | jq -r '.file_path // ""')
        ;;
    *)
        detail="Approval needed"
        ;;
esac

# Format as distinct approval request with markdown
message="**🔐 Approve?**
\`$tool_name\` $detail"

# Send to bubble with approval prompt (redirect output to avoid polluting stdout)
"$BUBBLE" --append "$message" >/dev/null 2>&1
"$BUBBLE" --status "busy:Awaiting approval..." >/dev/null 2>&1

# Wait for response (30 second timeout)
response=$(wait_response_timeout 30)
action=$(echo "$response" | jq -r '.action // ""')
text=$(echo "$response" | jq -r '.text // ""')
text_lower=$(echo "$text" | tr '[:upper:]' '[:lower:]')

# Clear status (use space to avoid empty string issues)
"$BUBBLE" --status " " >/dev/null 2>&1

# Handle response
if [[ "$action" == "reaction" ]]; then
    emoji=$(echo "$response" | jq -r '.emoji // ""')
    case "$emoji" in
        "👍"|"✓"|"❤️")
            echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Approved via bubble"}}'
            exit 0
            ;;
        *)
            echo "Denied via bubble ($emoji)" >&2
            exit 2
            ;;
    esac
elif [[ "$action" == "reply" ]]; then
    if [[ "$text_lower" =~ ^(yes|y|ok|approve|allow|go|sure|yep|yeah)$ ]]; then
        echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Approved via bubble"}}'
        exit 0
    else
        # User provided alternative or denial
        echo "User response: $text" >&2
        exit 2
    fi
elif [[ "$action" == "done" ]]; then
    echo "Denied (done pressed)" >&2
    exit 2
else
    # Timeout or no response
    echo "Timeout - auto-denied after 30s" >&2
    exit 2
fi
