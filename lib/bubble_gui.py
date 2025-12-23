#!/usr/bin/env python3
"""
Lightweight chat bubble GUI for Claude Code interaction.

A minimal, borderless floating window that displays messages and captures
user responses via reaction icons (reply, emoji reactions, done).

Usage:
    bubble_gui.py --show "message"              # Display bubble
    bubble_gui.py --show "message" --image /tmp/img.jpg
    bubble_gui.py --read                        # Read response (blocks)
    bubble_gui.py --dismiss                     # Close bubble
    bubble_gui.py --status                      # Check dependencies
"""

import sys
import os
import json
import argparse
import socket
import threading
import time
from datetime import datetime

try:
    from AppKit import (
        NSApplication, NSWindow, NSPanel, NSView, NSTextField, NSButton,
        NSImageView, NSImage, NSColor, NSFont, NSBezierPath, NSScreen,
        NSWindowStyleMaskBorderless, NSWindowStyleMaskNonactivatingPanel,
        NSFloatingWindowLevel, NSBackingStoreBuffered, NSTextFieldCell,
        NSLineBreakByWordWrapping, NSViewWidthSizable, NSViewHeightSizable,
        NSMakeRect, NSTrackingArea, NSTrackingMouseEnteredAndExited,
        NSTrackingActiveAlways, NSApp, NSApplicationActivationPolicyAccessory,
        NSMutableParagraphStyle, NSTextAlignmentRight, NSTextAlignmentLeft,
        NSImageScaleProportionallyUpOrDown
    )
    from AppKit import NSAppearanceNameDarkAqua, NSAppearanceNameAqua
    from Foundation import NSObject, NSTimer, NSRunLoop, NSDefaultRunLoopMode, NSMutableAttributedString
    from AppKit import NSForegroundColorAttributeName, NSFontAttributeName, NSParagraphStyleAttributeName
    from Quartz import CGDisplayBounds, CGMainDisplayID, CGWindowListCopyWindowInfo, kCGWindowListOptionOnScreenOnly, kCGNullWindowID
    import objc
except ImportError:
    print("ERROR: AppKit/Foundation not available. Install pyobjc.", file=sys.stderr)
    sys.exit(1)

# File paths
STATE_FILE = f"/tmp/bubble_state_{os.getuid()}.json"
RESPONSE_FILE = f"/tmp/bubble_response_{os.getuid()}.json"
COMMAND_FILE = f"/tmp/bubble_command_{os.getuid()}.json"
ACK_FILE = f"/tmp/bubble_ack_{os.getuid()}.json"
SOCKET_PATH = f"/tmp/bubble_cmd_{os.getuid()}.sock"
DEBUG_LOG = f"/tmp/claude/bubble_debug_{os.getuid()}.log"

# Debug logging
DEBUG = os.environ.get('BUBBLE_DEBUG', '0') == '1'

def debug_log(msg):
    """Log debug message to file if DEBUG is enabled."""
    if not DEBUG:
        return
    try:
        with open(DEBUG_LOG, 'a') as f:
            f.write(f"{datetime.now().isoformat()} {msg}\n")
    except:
        pass

# Constants
CORNER_RADIUS = 14.0
PADDING = 12
ICON_SIZE = 24
ARROW_SIZE = 16  # Size of speech bubble arrow extending from border
MAX_WIDTH = 400
MIN_WIDTH = 100
MAX_IMAGE_WIDTH = 280  # Keep images small for lightweight bubble


def update_position_in_state(x_percent, y_percent, w_percent=None, h_percent=None):
    """Update position and optionally size in the state file.

    Args:
        x_percent: X position as percentage (0-100)
        y_percent: Y position as percentage (0-100)
        w_percent: Optional width as percentage (0-100)
        h_percent: Optional height as percentage (0-100)
    """
    try:
        if os.path.exists(STATE_FILE):
            with open(STATE_FILE, 'r') as f:
                state = json.load(f)
        else:
            state = {}

        state['position'] = [x_percent, y_percent]
        if w_percent is not None and h_percent is not None:
            state['size'] = [w_percent, h_percent]
        state['timestamp'] = datetime.now().isoformat()

        with open(STATE_FILE, 'w') as f:
            json.dump(state, f, indent=2)
        debug_log(f"Updated position in state: {x_percent},{y_percent}")
    except Exception as e:
        debug_log(f"Failed to update position in state: {e}")


def get_window_bounds(app_name):
    """Get the bounds of an app's main window using Quartz."""
    windows = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID)
    if windows is None:
        return None
    for window in windows:
        owner = window.get('kCGWindowOwnerName', '')
        if app_name.lower() in owner.lower():
            bounds = window.get('kCGWindowBounds', {})
            if bounds and bounds.get('Width', 0) > 100:  # Skip tiny windows
                return {
                    'x': int(bounds.get('X', 0)),
                    'y': int(bounds.get('Y', 0)),
                    'width': int(bounds.get('Width', 0)),
                    'height': int(bounds.get('Height', 0))
                }
    return None


MAX_IMAGE_HEIGHT = 180  # Constrain height to avoid huge bubbles


def get_theme_colors():
    """Get colors based on system appearance."""
    try:
        appearance = NSApp.effectiveAppearance()
        is_dark = 'Dark' in str(appearance.name())
    except:
        is_dark = False

    if is_dark:
        return {
            'background': NSColor.colorWithRed_green_blue_alpha_(0.15, 0.15, 0.15, 0.95),
            'text': NSColor.whiteColor(),
            'secondary': NSColor.colorWithWhite_alpha_(0.7, 1.0),
            'icon_faded': 0.4,
            'border': NSColor.colorWithWhite_alpha_(0.3, 1.0),
        }
    else:
        return {
            'background': NSColor.colorWithRed_green_blue_alpha_(1.0, 1.0, 1.0, 0.95),
            'text': NSColor.blackColor(),
            'secondary': NSColor.colorWithWhite_alpha_(0.4, 1.0),
            'icon_faded': 0.5,
            'border': NSColor.colorWithWhite_alpha_(0.8, 1.0),
        }


def parse_markdown(text, base_font_size=14):
    """Parse markdown text and return NSAttributedString.

    Supports: **bold**, *italic*, `code`, ## headers, lists
    """
    import re
    colors = get_theme_colors()

    # Create fonts
    regular_font = NSFont.systemFontOfSize_(base_font_size)
    bold_font = NSFont.boldSystemFontOfSize_(base_font_size)
    italic_font = NSFont.systemFontOfSize_weight_(base_font_size, 0.2)  # Light weight for italic effect
    code_font = NSFont.monospacedSystemFontOfSize_weight_(base_font_size - 1, 0.4)
    header_font = NSFont.boldSystemFontOfSize_(base_font_size + 2)

    # Process line by line for headers and lists
    lines = text.split('\n')
    result = NSMutableAttributedString.alloc().init()

    for i, line in enumerate(lines):
        if i > 0:
            newline = NSMutableAttributedString.alloc().initWithString_('\n')
            result.appendAttributedString_(newline)

        # Check for header
        header_match = re.match(r'^(#{1,3})\s+(.+)$', line)
        if header_match:
            header_text = header_match.group(2)
            attr_line = NSMutableAttributedString.alloc().initWithString_(header_text)
            attr_line.addAttribute_value_range_(NSFontAttributeName, header_font, (0, len(header_text)))
            attr_line.addAttribute_value_range_(NSForegroundColorAttributeName, colors['text'], (0, len(header_text)))
            result.appendAttributedString_(attr_line)
            continue

        # Check for list items (- or 1.)
        list_match = re.match(r'^(\s*)([-*]|\d+\.)\s+(.+)$', line)
        if list_match:
            indent = list_match.group(1)
            bullet = list_match.group(2)
            content = list_match.group(3)
            # Use bullet point for unordered, keep number for ordered
            if bullet in ['-', '*']:
                prefix = indent + '• '
            else:
                prefix = indent + bullet + ' '
            line = prefix + content

        # Process inline markdown: **bold**, *italic*, `code`
        attr_line = _parse_inline_markdown(line, regular_font, bold_font, italic_font, code_font, colors)
        result.appendAttributedString_(attr_line)

    return result


def _parse_inline_markdown(text, regular_font, bold_font, italic_font, code_font, colors):
    """Parse inline markdown (bold, italic, code) and return attributed string."""
    import re

    result = NSMutableAttributedString.alloc().init()

    # Pattern to match **bold**, *italic*, `code`
    pattern = r'(\*\*(.+?)\*\*|\*(.+?)\*|`(.+?)`)'

    last_end = 0
    for match in re.finditer(pattern, text):
        # Add text before match
        if match.start() > last_end:
            before = text[last_end:match.start()]
            attr_before = NSMutableAttributedString.alloc().initWithString_(before)
            attr_before.addAttribute_value_range_(NSFontAttributeName, regular_font, (0, len(before)))
            attr_before.addAttribute_value_range_(NSForegroundColorAttributeName, colors['text'], (0, len(before)))
            result.appendAttributedString_(attr_before)

        # Determine which group matched
        if match.group(2):  # **bold**
            content = match.group(2)
            attr_match = NSMutableAttributedString.alloc().initWithString_(content)
            attr_match.addAttribute_value_range_(NSFontAttributeName, bold_font, (0, len(content)))
            attr_match.addAttribute_value_range_(NSForegroundColorAttributeName, colors['text'], (0, len(content)))
        elif match.group(3):  # *italic*
            content = match.group(3)
            attr_match = NSMutableAttributedString.alloc().initWithString_(content)
            attr_match.addAttribute_value_range_(NSFontAttributeName, italic_font, (0, len(content)))
            attr_match.addAttribute_value_range_(NSForegroundColorAttributeName, colors['text'], (0, len(content)))
        elif match.group(4):  # `code`
            content = match.group(4)
            attr_match = NSMutableAttributedString.alloc().initWithString_(content)
            attr_match.addAttribute_value_range_(NSFontAttributeName, code_font, (0, len(content)))
            # Slightly different color for code
            attr_match.addAttribute_value_range_(NSForegroundColorAttributeName, colors['secondary'], (0, len(content)))

        result.appendAttributedString_(attr_match)
        last_end = match.end()

    # Add remaining text after last match
    if last_end < len(text):
        after = text[last_end:]
        attr_after = NSMutableAttributedString.alloc().initWithString_(after)
        attr_after.addAttribute_value_range_(NSFontAttributeName, regular_font, (0, len(after)))
        attr_after.addAttribute_value_range_(NSForegroundColorAttributeName, colors['text'], (0, len(after)))
        result.appendAttributedString_(attr_after)

    # If no matches, return the whole text with regular font
    if result.length() == 0:
        attr_text = NSMutableAttributedString.alloc().initWithString_(text)
        attr_text.addAttribute_value_range_(NSFontAttributeName, regular_font, (0, len(text)))
        attr_text.addAttribute_value_range_(NSForegroundColorAttributeName, colors['text'], (0, len(text)))
        return attr_text

    return result


class BubbleNSPanel(NSPanel):
    """Custom NSPanel subclass for floating bubble without focus ring."""

    def canBecomeKeyWindow(self):
        return True

    def canBecomeMainWindow(self):
        return False  # Panels shouldn't become main

    # Disable focus ring at window level
    def _enableFirstResponderTracking(self):
        return False


class BubbleContentView(NSView):
    """Content view with rounded rectangle background and shadow."""

    def initWithFrame_(self, frame):
        self = objc.super(BubbleContentView, self).initWithFrame_(frame)
        if self:
            self.setFocusRingType_(1)  # NSFocusRingTypeNone
            self.message = ""
            self.messages = []  # Chat history: [{"role": "claude"|"user", "text": "..."}]
            self.image_path = None
            self.reply_mode = False
            self.picker_visible = False
            self.point_at = None  # Screen coordinates to point at (x, y)
            self.arrow_direction = None  # 'left', 'right', 'up', 'down'
            self.reactions = ['thumbsup', 'thumbsdown', 'yes', 'no', 'heart', 'question', 'done']
            # Status line support
            self.status_label = None
            self.shimmer_timer = None
            self.is_busy = False
            self.shimmer_phase = 0.0
            self.setup_subviews()
        return self

    def setup_subviews(self):
        """Create and position all subviews."""
        colors = get_theme_colors()

        # Message label
        # Use NSTextView for rich content with inline images
        from AppKit import NSTextView, NSTextContainer, NSLayoutManager, NSTextStorage
        from Foundation import NSMakeSize

        # Create text storage, layout manager, and text container
        text_storage = NSTextStorage.alloc().init()
        layout_manager = NSLayoutManager.alloc().init()
        text_storage.addLayoutManager_(layout_manager)

        text_container = NSTextContainer.alloc().initWithSize_(NSMakeSize(200, 10000))
        text_container.setWidthTracksTextView_(True)
        text_container.setLineFragmentPadding_(0)
        layout_manager.addTextContainer_(text_container)

        self.message_label = NSTextView.alloc().initWithFrame_textContainer_(
            NSMakeRect(PADDING, ICON_SIZE + PADDING * 2, 200, 50),
            text_container
        )
        self.message_label.setDrawsBackground_(False)
        self.message_label.setEditable_(False)
        self.message_label.setSelectable_(True)  # Allow text selection
        self.message_label.setTextColor_(colors['text'])
        self.message_label.setFont_(NSFont.systemFontOfSize_(14))
        self.message_label.setFocusRingType_(1)  # NSFocusRingTypeNone
        self.message_label.setVerticallyResizable_(True)
        self.message_label.setHorizontallyResizable_(False)
        self.addSubview_(self.message_label)

        # Image view (hidden initially, shown above message when image is set)
        self.image_view = NSImageView.alloc().initWithFrame_(
            NSMakeRect(PADDING, 100, MAX_IMAGE_WIDTH, MAX_IMAGE_HEIGHT)
        )
        self.image_view.setImageScaling_(NSImageScaleProportionallyUpOrDown)
        self.image_view.setHidden_(True)
        self.image_view.setFocusRingType_(1)
        self.addSubview_(self.image_view)
        self.current_image_size = (0, 0)  # Track actual displayed image size
        self.inline_image_heights = []  # Track heights of inline images in chat

        # Reply button (chat icon)
        self.reply_btn = NSButton.alloc().initWithFrame_(
            NSMakeRect(PADDING, PADDING, ICON_SIZE, ICON_SIZE)
        )
        self.reply_btn.setTitle_("💬")
        self.reply_btn.setBordered_(False)
        self.reply_btn.setTarget_(self)
        self.reply_btn.setAction_(objc.selector(self.replyClicked_, signature=b'v@:@'))
        self.reply_btn.setFocusRingType_(1)  # NSFocusRingTypeNone
        self.addSubview_(self.reply_btn)

        # Reaction button (faded smile)
        self.reaction_btn = NSButton.alloc().initWithFrame_(
            NSMakeRect(PADDING + ICON_SIZE + 8, PADDING, ICON_SIZE, ICON_SIZE)
        )
        self.reaction_btn.setTitle_("☺")
        self.reaction_btn.setBordered_(False)
        self.reaction_btn.setAlphaValue_(colors['icon_faded'])
        self.reaction_btn.setTarget_(self)
        self.reaction_btn.setAction_(objc.selector(self.reactionClicked_, signature=b'v@:@'))
        self.reaction_btn.setFocusRingType_(1)  # NSFocusRingTypeNone
        self.addSubview_(self.reaction_btn)

        # Reply text field (hidden initially)
        self.reply_field = NSTextField.alloc().initWithFrame_(
            NSMakeRect(PADDING, ICON_SIZE + PADDING + 4, 200, 24)
        )
        self.reply_field.setPlaceholderString_("Type your reply...")
        self.reply_field.setHidden_(True)
        self.reply_field.setTarget_(self)
        self.reply_field.setAction_(objc.selector(self.replySubmitted_, signature=b'v@:@'))
        self.reply_field.setFocusRingType_(1)  # NSFocusRingTypeNone
        self.addSubview_(self.reply_field)

        # Emoji picker buttons (hidden initially)
        self.emoji_buttons = []
        emoji_map = {
            'thumbsup': '👍', 'thumbsdown': '👎', 'yes': '✓', 'no': '✗',
            'heart': '❤️', 'question': '❓', 'done': '⏹'
        }
        x_offset = PADDING
        for reaction_id in self.reactions:
            emoji = emoji_map.get(reaction_id, reaction_id)
            btn = NSButton.alloc().initWithFrame_(
                NSMakeRect(x_offset, PADDING - 30, ICON_SIZE, ICON_SIZE)
            )
            btn.setTitle_(emoji)
            btn.setBordered_(False)
            btn.setHidden_(True)
            btn.setTag_(self.reactions.index(reaction_id))
            btn.setTarget_(self)
            btn.setAction_(objc.selector(self.emojiClicked_, signature=b'v@:@'))
            self.addSubview_(btn)
            self.emoji_buttons.append(btn)
            x_offset += ICON_SIZE + 4

        # Status label (left of Reply button, same row)
        self.status_label = NSTextField.alloc().initWithFrame_(
            NSMakeRect(PADDING, PADDING, 150, ICON_SIZE)
        )
        self.status_label.setBezeled_(False)
        self.status_label.setDrawsBackground_(False)
        self.status_label.setEditable_(False)
        self.status_label.setSelectable_(False)
        self.status_label.setFont_(NSFont.systemFontOfSize_(11))
        self.status_label.setTextColor_(colors['secondary'])
        self.status_label.setHidden_(True)
        self.status_label.setFocusRingType_(1)  # NSFocusRingTypeNone
        self.addSubview_(self.status_label)

    def focusRingMaskBounds(self):
        """Return empty bounds to disable focus ring."""
        return NSMakeRect(0, 0, 0, 0)

    def drawFocusRingMask(self):
        """Override to draw nothing for focus ring."""
        pass

    def drawRect_(self, rect):
        """Draw rounded rectangle background with optional callout arrow."""
        colors = get_theme_colors()
        bounds = self.bounds()

        if self.point_at and self.arrow_direction:
            # Draw speech bubble with arrow - bubble is inset, arrow extends to edge
            path = self._create_speech_bubble_path(bounds, colors)
        else:
            # Simple rounded rect fills entire bounds
            path = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
                bounds, CORNER_RADIUS, CORNER_RADIUS
            )

        # Fill background
        colors['background'].set()
        path.fill()

        # Draw subtle border that conforms to shape (rounded rect or speech bubble)
        colors['border'].set()
        path.setLineWidth_(1.0)
        path.stroke()

    def _create_speech_bubble_path(self, bounds, colors):
        """Create a path for rounded rect with speech bubble arrow.

        The bubble is drawn INSET so the arrow extends to the bounds edge.
        """
        w = bounds.size.width
        h = bounds.size.height
        r = CORNER_RADIUS
        a = ARROW_SIZE  # Inset amount on arrow side
        aw = 14  # Arrow width

        path = NSBezierPath.bezierPath()
        direction = self.arrow_direction

        if direction == 'left':
            # Bubble inset on left, arrow points left to edge
            # Bubble rect: (a, 0) to (w, h)
            bx = a  # Bubble left edge
            path.moveToPoint_((bx + r, h))
            path.lineToPoint_((w - r, h))
            path.appendBezierPathWithArcFromPoint_toPoint_radius_((w, h), (w, h - r), r)
            path.lineToPoint_((w, r))
            path.appendBezierPathWithArcFromPoint_toPoint_radius_((w, 0), (w - r, 0), r)
            path.lineToPoint_((bx + r, 0))
            path.appendBezierPathWithArcFromPoint_toPoint_radius_((bx, 0), (bx, r), r)
            path.lineToPoint_((bx, h/2 - aw/2))
            path.lineToPoint_((0, h/2))  # Arrow tip at left edge
            path.lineToPoint_((bx, h/2 + aw/2))
            path.lineToPoint_((bx, h - r))
            path.appendBezierPathWithArcFromPoint_toPoint_radius_((bx, h), (bx + r, h), r)

        elif direction == 'right':
            # Bubble inset on right, arrow points right to edge
            bw = w - a  # Bubble right edge
            path.moveToPoint_((r, h))
            path.lineToPoint_((bw - r, h))
            path.appendBezierPathWithArcFromPoint_toPoint_radius_((bw, h), (bw, h - r), r)
            path.lineToPoint_((bw, h/2 + aw/2))
            path.lineToPoint_((w, h/2))  # Arrow tip at right edge
            path.lineToPoint_((bw, h/2 - aw/2))
            path.lineToPoint_((bw, r))
            path.appendBezierPathWithArcFromPoint_toPoint_radius_((bw, 0), (bw - r, 0), r)
            path.lineToPoint_((r, 0))
            path.appendBezierPathWithArcFromPoint_toPoint_radius_((0, 0), (0, r), r)
            path.lineToPoint_((0, h - r))
            path.appendBezierPathWithArcFromPoint_toPoint_radius_((0, h), (r, h), r)

        elif direction == 'up':
            # Bubble inset on top, arrow points up to edge
            bh = h - a  # Bubble top edge
            path.moveToPoint_((r, bh))
            path.lineToPoint_((w/2 - aw/2, bh))
            path.lineToPoint_((w/2, h))  # Arrow tip at top edge
            path.lineToPoint_((w/2 + aw/2, bh))
            path.lineToPoint_((w - r, bh))
            path.appendBezierPathWithArcFromPoint_toPoint_radius_((w, bh), (w, bh - r), r)
            path.lineToPoint_((w, r))
            path.appendBezierPathWithArcFromPoint_toPoint_radius_((w, 0), (w - r, 0), r)
            path.lineToPoint_((r, 0))
            path.appendBezierPathWithArcFromPoint_toPoint_radius_((0, 0), (0, r), r)
            path.lineToPoint_((0, bh - r))
            path.appendBezierPathWithArcFromPoint_toPoint_radius_((0, bh), (r, bh), r)

        elif direction == 'down':
            # Bubble inset on bottom, arrow points down to edge
            by = a  # Bubble bottom edge
            path.moveToPoint_((r, h))
            path.lineToPoint_((w - r, h))
            path.appendBezierPathWithArcFromPoint_toPoint_radius_((w, h), (w, h - r), r)
            path.lineToPoint_((w, by + r))
            path.appendBezierPathWithArcFromPoint_toPoint_radius_((w, by), (w - r, by), r)
            path.lineToPoint_((w/2 + aw/2, by))
            path.lineToPoint_((w/2, 0))  # Arrow tip at bottom edge
            path.lineToPoint_((w/2 - aw/2, by))
            path.lineToPoint_((r, by))
            path.appendBezierPathWithArcFromPoint_toPoint_radius_((0, by), (0, by + r), r)
            path.lineToPoint_((0, h - r))
            path.appendBezierPathWithArcFromPoint_toPoint_radius_((0, h), (r, h), r)

        else:
            return NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
                bounds, CORNER_RADIUS, CORNER_RADIUS
            )

        path.closePath()
        return path

    def clearArrow(self):
        """Remove the arrow from the bubble."""
        self.point_at = None
        self.arrow_direction = None
        self.layout_subviews()
        self.setNeedsDisplay_(True)

    def setPointAt_(self, point_at_str, in_app=None, arrow_hint=None):
        """Set the point-at target and calculate arrow direction.

        Args:
            point_at_str: "x,y" coordinates OR "x,y,w,h" bounding box
                         (percentages 0-100 or pixels)
                         If 4 values given, uses smart positioning to stay outside the box.
            in_app: Optional app name for app-relative coordinate translation
            arrow_hint: Optional direction hint ('left', 'right', 'up', 'down')
                       If provided, uses this direction instead of auto-detecting.
        """
        try:
            if point_at_str:
                parts = list(map(float, point_at_str.split(',')))

                # Auto-detect: 4 values = bounding box, use smart positioning
                if len(parts) == 4:
                    self._setPointAtBox_(parts, in_app, arrow_hint)
                    return
                elif len(parts) != 2:
                    return  # Invalid format

                px, py = parts

                # Get reference bounds (app window or full screen)
                if in_app:
                    app_bounds = get_window_bounds(in_app)
                    if app_bounds:
                        # Note: screenshot.sh --in-app captures full window including titlebar
                        # So OCR coords are already full-window relative, no chrome offset needed
                        chrome_offset = 0

                        # App-relative coordinates: translate to screen pixels
                        if px <= 100 and py <= 100:
                            x = app_bounds['x'] + (px / 100.0) * app_bounds['width']
                            # Y is from top in app coords, need to convert to macOS (from bottom)
                            # Account for chrome offset - content starts below the chrome
                            display_bounds = CGDisplayBounds(CGMainDisplayID())
                            screen_height = display_bounds.size.height
                            content_height = app_bounds['height'] - chrome_offset
                            app_y = app_bounds['y'] + chrome_offset + (py / 100.0) * content_height
                            y = screen_height - app_y  # Flip for macOS
                        else:
                            # Pixel coords within app (assume already accounts for chrome)
                            x = app_bounds['x'] + px
                            display_bounds = CGDisplayBounds(CGMainDisplayID())
                            y = display_bounds.size.height - (app_bounds['y'] + chrome_offset + py)
                    else:
                        print(f"WARNING: Could not find window for app '{in_app}'", file=sys.stderr)
                        # Fall back to screen-relative
                        in_app = None

                if not in_app:
                    # Screen-relative coordinates
                    display_bounds = CGDisplayBounds(CGMainDisplayID())
                    screen_width = display_bounds.size.width
                    screen_height = display_bounds.size.height
                    if px <= 100 and py <= 100:
                        x = (px / 100.0) * screen_width
                        y = ((100 - py) / 100.0) * screen_height  # Flip y for macOS
                    else:
                        x, y = px, py

                self.point_at = (x, y)

                # Calculate arrow direction based on target position on screen
                # (not current bubble position - that's arbitrary)
                window = self.window()
                if window:
                    frame = window.frame()
                    w = frame.size.width
                    h = frame.size.height

                    display_bounds = CGDisplayBounds(CGMainDisplayID())
                    screen_w = display_bounds.size.width
                    screen_h = display_bounds.size.height

                    # Determine arrow direction - use hint if provided, else auto-detect
                    if arrow_hint in ('left', 'right', 'up', 'down'):
                        # LLM provided explicit direction to avoid obscuring content
                        self.arrow_direction = arrow_hint
                    else:
                        # Auto-detect: use direction from nearest screen edge
                        # This places bubble in largest available space
                        dist_to_left = x
                        dist_to_right = screen_w - x
                        dist_to_bottom = y  # macOS: y=0 is bottom
                        dist_to_top = screen_h - y

                        min_dist = min(dist_to_left, dist_to_right, dist_to_bottom, dist_to_top)

                        if min_dist == dist_to_right:
                            self.arrow_direction = 'right'  # Target near right → arrow points right
                        elif min_dist == dist_to_left:
                            self.arrow_direction = 'left'   # Target near left → arrow points left
                        elif min_dist == dist_to_top:
                            self.arrow_direction = 'up'     # Target near top → arrow points up
                        else:
                            self.arrow_direction = 'down'   # Target near bottom → arrow points down

                    # Position window so arrow tip lands exactly on target
                    # Arrow tip positions in view coords:
                    #   left: (0, h/2), right: (w, h/2)
                    #   up: (w/2, h), down: (w/2, 0)
                    if self.arrow_direction == 'left':
                        new_x = x  # Arrow tip at left edge points at target
                        new_y = y - h / 2  # Center vertically on target
                    elif self.arrow_direction == 'right':
                        new_x = x - w  # Arrow tip at right edge points at target
                        new_y = y - h / 2
                    elif self.arrow_direction == 'up':
                        new_x = x - w / 2  # Center horizontally
                        new_y = y - h  # Arrow tip at top edge points at target
                    else:  # down
                        new_x = x - w / 2
                        new_y = y  # Arrow tip at bottom edge points at target

                    # Keep bubble on screen
                    margin = 10
                    new_x = max(margin, min(new_x, screen_w - w - margin))
                    new_y = max(margin, min(new_y, screen_h - h - margin))

                    new_frame = NSMakeRect(new_x, new_y, w, h)
                    window.setFrame_display_animate_(new_frame, True, True)

                    # Save updated position and size to state file (convert to grid %)
                    x_pct = (new_x + w / 2) / screen_w * 100
                    y_pct = 100 - (new_y + h / 2) / screen_h * 100
                    w_pct = (w / screen_w * 100) + 4  # Add padding
                    h_pct = (h / screen_h * 100) + 4
                    update_position_in_state(x_pct, y_pct, w_pct, h_pct)
                else:
                    self.arrow_direction = None
            else:
                self.point_at = None
                self.arrow_direction = None

            self.layout_subviews()
            self.setNeedsDisplay_(True)
        except (ValueError, AttributeError):
            self.point_at = None
            self.arrow_direction = None

    def _setPointAtBox_(self, box_coords, in_app=None, arrow_hint=None):
        """Position bubble to avoid obscuring a target bounding box.

        Args:
            box_coords: [x, y, w, h] bounding box (percentages 0-100 or pixels)
            in_app: Optional app name for app-relative coordinates
            arrow_hint: Optional direction hint ('left', 'right', 'up', 'down')
        """
        try:
            bx, by, bw, bh = box_coords

            # Get screen dimensions
            display_bounds = CGDisplayBounds(CGMainDisplayID())
            screen_w = display_bounds.size.width
            screen_h = display_bounds.size.height

            # Convert to screen coordinates
            if in_app:
                app_bounds = get_window_bounds(in_app)
                if app_bounds:
                    # Convert percentages to screen pixels
                    if bx <= 100 and by <= 100 and bw <= 100 and bh <= 100:
                        # Box coords are percentages within app
                        box_x = app_bounds['x'] + (bx / 100.0) * app_bounds['width']
                        box_w = (bw / 100.0) * app_bounds['width']
                        # Y from top in app coords -> macOS from bottom
                        app_y_top = app_bounds['y'] + (by / 100.0) * app_bounds['height']
                        box_h = (bh / 100.0) * app_bounds['height']
                        box_y = screen_h - app_y_top - box_h  # Bottom of box in macOS coords
                    else:
                        box_x = app_bounds['x'] + bx
                        box_w = bw
                        box_y = screen_h - (app_bounds['y'] + by + bh)
                        box_h = bh
                else:
                    in_app = None

            if not in_app:
                # Screen-relative coordinates
                if bx <= 100 and by <= 100 and bw <= 100 and bh <= 100:
                    box_x = (bx / 100.0) * screen_w
                    box_w = (bw / 100.0) * screen_w
                    box_y = ((100 - by - bh) / 100.0) * screen_h  # Flip y
                    box_h = (bh / 100.0) * screen_h
                else:
                    box_x, box_w = bx, bw
                    box_y = screen_h - by - bh
                    box_h = bh

            # Arrow points at center of box
            target_x = box_x + box_w / 2
            target_y = box_y + box_h / 2
            self.point_at = (target_x, target_y)

            window = self.window()
            if not window:
                return

            frame = window.frame()
            bubble_w = frame.size.width
            bubble_h = frame.size.height

            # Calculate room on each side of the TARGET BOX (not just the point)
            room_left = box_x - bubble_w - 10  # Room for bubble left of box
            room_right = screen_w - (box_x + box_w) - bubble_w - 10  # Right of box
            room_above = screen_h - (box_y + box_h) - bubble_h - 10  # Above box
            room_below = box_y - bubble_h - 10  # Below box

            # Determine arrow direction - use hint or find best side
            if arrow_hint in ('left', 'right', 'up', 'down'):
                self.arrow_direction = arrow_hint
            else:
                # Pick the side with the most room
                rooms = {
                    'right': room_left,   # Bubble left of box, arrow points right
                    'left': room_right,   # Bubble right of box, arrow points left
                    'down': room_above,   # Bubble above box, arrow points down
                    'up': room_below      # Bubble below box, arrow points up
                }
                self.arrow_direction = max(rooms, key=rooms.get)

            # Position bubble completely outside the target box
            margin = 5  # Small gap between bubble and box
            if self.arrow_direction == 'left':
                # Bubble to the RIGHT of box, arrow points left at box
                new_x = box_x + box_w + margin
                new_y = target_y - bubble_h / 2
            elif self.arrow_direction == 'right':
                # Bubble to the LEFT of box, arrow points right at box
                new_x = box_x - bubble_w - margin
                new_y = target_y - bubble_h / 2
            elif self.arrow_direction == 'up':
                # Bubble BELOW box, arrow points up at box
                new_x = target_x - bubble_w / 2
                new_y = box_y - bubble_h - margin
            else:  # down
                # Bubble ABOVE box, arrow points down at box
                new_x = target_x - bubble_w / 2
                new_y = box_y + box_h + margin

            # Keep on screen
            new_x = max(10, min(new_x, screen_w - bubble_w - 10))
            new_y = max(10, min(new_y, screen_h - bubble_h - 10))

            new_frame = NSMakeRect(new_x, new_y, bubble_w, bubble_h)
            window.setFrame_display_animate_(new_frame, True, True)

            # Save updated position and size to state file (convert to grid %)
            x_pct = (new_x + bubble_w / 2) / screen_w * 100
            y_pct = 100 - (new_y + bubble_h / 2) / screen_h * 100
            w_pct = (bubble_w / screen_w * 100) + 4  # Add padding
            h_pct = (bubble_h / screen_h * 100) + 4
            update_position_in_state(x_pct, y_pct, w_pct, h_pct)

            self.layout_subviews()
            self.setNeedsDisplay_(True)

        except (ValueError, AttributeError) as e:
            print(f"_setPointAtBox_ error: {e}", file=sys.stderr)
            self.point_at = None
            self.arrow_direction = None

    def setMessage_(self, message):
        """Update the message text and resize with markdown rendering."""
        self.message = message
        self.raw_message = message  # Keep raw for height calculation
        # Add initial message to chat history
        if not self.messages:
            self.messages.append({"role": "claude", "text": message})
        # Render markdown
        attr_string = parse_markdown(message)
        # NSTextView uses textStorage instead of setAttributedStringValue_
        self.message_label.textStorage().setAttributedString_(attr_string)
        # Resize window to fit content, then layout
        self._resize_for_content()
        self.layout_subviews()

    def setImage_(self, image_path, crop=None):
        """Load and display an image with optional cropping.

        Args:
            image_path: Path to the image file
            crop: Optional tuple (x, y, w, h) in pixels or "x%,y%,w%,h%" for percentage crop
        """
        if not image_path or not os.path.exists(image_path):
            self.image_view.setHidden_(True)
            self.current_image_size = (0, 0)
            return

        # Load the image
        image = NSImage.alloc().initWithContentsOfFile_(image_path)
        if not image:
            self.image_view.setHidden_(True)
            self.current_image_size = (0, 0)
            return

        orig_size = image.size()
        orig_w, orig_h = orig_size.width, orig_size.height

        # Apply cropping if specified
        if crop:
            image = self._crop_image(image, crop, orig_w, orig_h)
            if image:
                orig_size = image.size()
                orig_w, orig_h = orig_size.width, orig_size.height

        # Calculate scaled size to fit within MAX_IMAGE dimensions
        scale = min(MAX_IMAGE_WIDTH / orig_w, MAX_IMAGE_HEIGHT / orig_h, 1.0)
        display_w = int(orig_w * scale)
        display_h = int(orig_h * scale)

        self.current_image_size = (display_w, display_h)
        self.image_view.setImage_(image)
        self.image_view.setHidden_(False)

        # Trigger resize and layout
        self._resize_for_content()
        self.layout_subviews()
        self.setNeedsDisplay_(True)

    def _crop_image(self, image, crop, orig_w, orig_h):
        """Crop an image to the specified region.

        Args:
            image: NSImage to crop
            crop: Crop spec - tuple (x, y, w, h) or string "x%,y%,w%,h%"
        """
        try:
            # Parse crop specification
            if isinstance(crop, str):
                parts = crop.replace('%', '').split(',')
                if len(parts) == 4:
                    cx, cy, cw, ch = map(float, parts)
                    # If percentages (values <= 100), convert to pixels
                    if all(v <= 100 for v in [cx, cy, cw, ch]):
                        cx = (cx / 100.0) * orig_w
                        cy = (cy / 100.0) * orig_h
                        cw = (cw / 100.0) * orig_w
                        ch = (ch / 100.0) * orig_h
                else:
                    return image
            elif isinstance(crop, (tuple, list)) and len(crop) == 4:
                cx, cy, cw, ch = crop
            else:
                return image

            # Clamp to image bounds
            cx = max(0, min(cx, orig_w - 1))
            cy = max(0, min(cy, orig_h - 1))
            cw = min(cw, orig_w - cx)
            ch = min(ch, orig_h - cy)

            if cw <= 0 or ch <= 0:
                return image

            # Create cropped image using CIImage
            from Quartz import CIImage, CIFilter, CIVector
            from AppKit import NSBitmapImageRep, NSCalibratedRGBColorSpace

            # Get bitmap representation
            tiff_data = image.TIFFRepresentation()
            bitmap = NSBitmapImageRep.imageRepWithData_(tiff_data)

            # Create CIImage and crop
            ci_image = CIImage.imageWithData_(tiff_data)
            # CIImage uses bottom-left origin, so flip y
            crop_rect = CIVector.vectorWithX_Y_Z_W_(cx, orig_h - cy - ch, cw, ch)

            crop_filter = CIFilter.filterWithName_('CICrop')
            crop_filter.setValue_forKey_(ci_image, 'inputImage')
            crop_filter.setValue_forKey_(crop_rect, 'inputRectangle')

            cropped_ci = crop_filter.valueForKey_('outputImage')
            if not cropped_ci:
                return image

            # Convert back to NSImage
            from AppKit import NSGraphicsContext, NSCompositingOperationSourceOver
            cropped_image = NSImage.alloc().initWithSize_((cw, ch))
            cropped_image.lockFocus()

            # Draw the cropped CIImage
            from Quartz import CIContext
            context = CIContext.contextWithOptions_(None)
            cg_image = context.createCGImage_fromRect_(cropped_ci, cropped_ci.extent())
            if cg_image:
                from AppKit import NSGraphicsContext
                ns_context = NSGraphicsContext.currentContext()
                cg_context = ns_context.CGContext()
                from Quartz import CGContextDrawImage, CGRectMake
                CGContextDrawImage(cg_context, CGRectMake(0, 0, cw, ch), cg_image)

            cropped_image.unlockFocus()
            return cropped_image

        except Exception as e:
            print(f"Crop failed: {e}", file=sys.stderr)
            return image

    def layout_subviews(self):
        """Recalculate sizes and positions."""
        bounds = self.bounds()
        width = bounds.size.width
        height = bounds.size.height

        # Calculate padding adjustments for arrow direction
        pad_left = PADDING
        pad_right = PADDING
        pad_top = PADDING
        pad_bottom = PADDING

        if self.arrow_direction == 'left':
            pad_left += ARROW_SIZE
        elif self.arrow_direction == 'right':
            pad_right += ARROW_SIZE
        elif self.arrow_direction == 'up':
            pad_top += ARROW_SIZE
        elif self.arrow_direction == 'down':
            pad_bottom += ARROW_SIZE

        # Position icons at bottom right
        icon_y = pad_bottom
        self.reply_btn.setFrame_(
            NSMakeRect(width - pad_right - ICON_SIZE * 2 - 8, icon_y, ICON_SIZE, ICON_SIZE)
        )
        self.reaction_btn.setFrame_(
            NSMakeRect(width - pad_right - ICON_SIZE, icon_y, ICON_SIZE, ICON_SIZE)
        )

        # Position status label (left of Reply button)
        if self.status_label and not self.status_label.isHidden():
            # Calculate available width for status (from left padding to Reply button)
            reply_x = width - pad_right - ICON_SIZE * 2 - 8
            status_width = reply_x - pad_left - 8  # Leave gap before Reply
            self.status_label.setFrame_(
                NSMakeRect(pad_left, icon_y + 2, status_width, ICON_SIZE)
            )

        # Calculate actual text height for proper layout
        msg_width = width - pad_left - pad_right
        text_height = 20  # minimum
        if self.message:
            from AppKit import NSStringDrawingUsesLineFragmentOrigin
            from Foundation import NSString
            font = NSFont.systemFontOfSize_(14)
            attrs = {NSFontAttributeName: font}
            ns_string = NSString.stringWithString_(self.message)
            bounding_rect = ns_string.boundingRectWithSize_options_attributes_(
                (msg_width, 10000),
                NSStringDrawingUsesLineFragmentOrigin,
                attrs
            )
            text_height = max(20, bounding_rect.size.height + 4)

            # Add inline image heights
            if hasattr(self, 'inline_image_heights') and self.inline_image_heights:
                text_height += sum(self.inline_image_heights) + len(self.inline_image_heights) * 8

        # Position image view (at top, if visible)
        img_w, img_h = self.current_image_size
        # Calculate minimum y position for message (above icons)
        icon_area_top = icon_y + ICON_SIZE + 8  # Icons + gap

        if img_h > 0 and not self.image_view.isHidden():
            img_y = height - pad_top - img_h
            self.image_view.setFrame_(
                NSMakeRect(pad_left, img_y, img_w, img_h)
            )
            # Message positioned just below image
            msg_y = img_y - 4 - text_height
            # Clamp to stay above icons
            if msg_y < icon_area_top:
                msg_y = icon_area_top
                text_height = img_y - 4 - msg_y
        else:
            # Message at top (below padding)
            msg_y = height - pad_top - text_height

        # Ensure message doesn't overlap icons at bottom
        icon_area_top = icon_y + ICON_SIZE + 8  # Icons + gap
        if msg_y < icon_area_top:
            # Clamp message to stay above icon area
            msg_y = icon_area_top
            text_height = height - pad_top - msg_y  # Adjust height to fit

        # Position message label with calculated height (no extra whitespace)
        self.message_label.setFrame_(
            NSMakeRect(pad_left, msg_y, msg_width, text_height)
        )

        # Position reply field (between message and icons)
        if not self.reply_field.isHidden():
            self.reply_field.setFrame_(
                NSMakeRect(pad_left, ICON_SIZE + pad_bottom + 4, width - pad_left - pad_right, 24)
            )

        # Position emoji picker (emojis on left, reaction button stays right-aligned)
        if self.picker_visible:
            x_offset = pad_left
            for btn in self.emoji_buttons:
                btn.setFrame_(NSMakeRect(x_offset, icon_y, ICON_SIZE, ICON_SIZE))
                btn.setHidden_(False)
                x_offset += ICON_SIZE + 4
            # Reaction button stays in its original right-aligned position

    def replyClicked_(self, sender):
        """Toggle reply text field."""
        window = self.window()

        # If reply field is visible, hide it
        if self.reply_mode:
            self.reply_mode = False
            self.reply_field.setHidden_(True)
            if window:
                frame = window.frame()
                frame.size.height -= 30
                # Adjust origin based on arrow direction to keep arrow tip anchored
                # Left/right arrows: tip is at middle height, adjust by HALF delta
                # Up arrow: tip is at top, adjust by FULL delta
                # Down arrow: tip is at bottom, no adjustment
                if self.arrow_direction == 'up':
                    frame.origin.y += 30  # Shrink from bottom, keep top anchored
                elif self.arrow_direction in ('left', 'right'):
                    frame.origin.y += 15  # Shrink equally from both ends, keep middle anchored
                # For 'down' or None, origin stays same
                window.setFrame_display_animate_(frame, True, True)
            self.layout_subviews()
            return

        # Hide reaction picker first if visible
        if self.picker_visible:
            self._hide_picker(window)

        # Hide status label when user interacts
        self.handleStatus_(None)

        # Show reply field
        self.reply_mode = True
        self.reply_field.setHidden_(False)

        # Expand bubble height (respecting arrow anchoring)
        if window:
            frame = window.frame()
            frame.size.height += 30
            # Adjust origin based on arrow direction to keep arrow tip anchored
            # Left/right arrows: tip is at middle height, adjust by HALF delta
            # Up arrow: tip is at top, adjust by FULL delta
            # Down arrow: tip is at bottom, no adjustment
            if self.arrow_direction == 'up':
                frame.origin.y -= 30  # Expand downward, keep top anchored
            elif self.arrow_direction in ('left', 'right'):
                frame.origin.y -= 15  # Expand equally both directions, keep middle anchored
            # For 'down' or None, origin stays same (expand upward)
            window.setFrame_display_animate_(frame, True, True)

            # Make window key and activate for text input
            window.makeKeyWindow()
            NSApp.activateIgnoringOtherApps_(True)

        self.layout_subviews()

        # Set focus to text field after layout
        self.reply_field.selectText_(None)
        if window:
            window.makeFirstResponder_(self.reply_field)

    def reactionClicked_(self, sender):
        """Toggle emoji picker visibility."""
        window = self.window()

        # If picker is visible, hide it
        if self.picker_visible:
            self._hide_picker(window)
            return

        # Hide reply field first if visible
        if self.reply_mode:
            self._hide_reply(window)

        # Hide status label when user interacts
        self.handleStatus_(None)

        # Show picker (replaces reply button, keeps reaction button to dismiss)
        self.picker_visible = True

        # Hide reply button, show emoji buttons, keep reaction button visible to dismiss
        self.reply_btn.setHidden_(True)
        for btn in self.emoji_buttons:
            btn.setHidden_(False)

        self.layout_subviews()
        self.setNeedsDisplay_(True)

    def _hide_picker(self, window):
        """Hide the emoji picker and show reply/reaction buttons."""
        self.picker_visible = False

        self.reply_btn.setHidden_(False)
        self.reaction_btn.setHidden_(False)
        for btn in self.emoji_buttons:
            btn.setHidden_(True)
        self.layout_subviews()
        self.setNeedsDisplay_(True)

    def _hide_reply(self, window):
        """Hide the reply field and shrink window."""
        self.reply_mode = False
        self.reply_field.setHidden_(True)
        if window:
            frame = window.frame()
            frame.size.height -= 30
            # Adjust origin based on arrow direction to keep arrow tip anchored
            # Left/right arrows: tip is at middle height, adjust by HALF delta
            # Up arrow: tip is at top, adjust by FULL delta
            # Down arrow: tip is at bottom, no adjustment
            if self.arrow_direction == 'up':
                frame.origin.y += 30  # Shrink from bottom, keep top anchored
            elif self.arrow_direction in ('left', 'right'):
                frame.origin.y += 15  # Shrink equally from both ends, keep middle anchored
            # For 'down' or None, origin stays same
            window.setFrame_display_animate_(frame, True, True)
        self.layout_subviews()

    def _parse_busy_prefix(self, status_text):
        """Parse busy: prefix from status text.

        Returns: (is_busy, display_text)
        """
        if status_text and status_text.startswith('busy:'):
            return True, status_text[5:]
        return False, status_text or ''

    def handleStatus_(self, status_text):
        """Handle status text update.

        Args:
            status_text: Status string, optionally prefixed with 'busy:' for shimmer
        """
        if not status_text:
            # Empty status = hide status line
            if self.status_label:
                self.status_label.setHidden_(True)
            self.stop_shimmer()
            return

        is_busy, display_text = self._parse_busy_prefix(status_text)

        if self.status_label:
            self.status_label.setStringValue_(display_text)
            self.status_label.setHidden_(False)

        # Control shimmer based on busy state
        if is_busy and not self.is_busy:
            self.start_shimmer()
        elif not is_busy and self.is_busy:
            self.stop_shimmer()
        self.is_busy = is_busy

        self.layout_subviews()

    def start_shimmer(self):
        """Start shimmer animation on status label."""
        if self.shimmer_timer:
            return  # Already running
        self.shimmer_phase = 0.0
        self.shimmer_timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            0.05, self, 'shimmerTick:', None, True
        )

    def shimmerTick_(self, timer):
        """Animation tick for shimmer effect (called by NSTimer)."""
        import math
        self.shimmer_phase += 0.12
        # Sine wave: ranges from 0.4 to 1.0
        alpha = 0.4 + 0.6 * (0.5 + 0.5 * math.sin(self.shimmer_phase))
        if self.status_label:
            self.status_label.setAlphaValue_(alpha)

    def stop_shimmer(self):
        """Stop shimmer animation."""
        if self.shimmer_timer:
            self.shimmer_timer.invalidate()
            self.shimmer_timer = None
        if self.status_label:
            self.status_label.setAlphaValue_(1.0)
        self.is_busy = False

    def replySubmitted_(self, sender):
        """Handle reply submission."""
        text = self.reply_field.stringValue()
        if not text.strip():
            return

        # Add user message to conversation display
        self.appendMessage_(text, "user")

        self.write_response('reply', text=text)

        # Clear field and collapse, but keep bubble open for continuous conversation
        self.reply_field.setStringValue_("")
        self.reply_field.setHidden_(True)
        self.reply_mode = False

        window = self.window()
        if window:
            frame = window.frame()
            frame.size.height -= 30
            frame.origin.y += 30
            window.setFrame_display_animate_(frame, True, True)

        # Refresh display with new message
        self._refresh_display()

    def emojiClicked_(self, sender):
        """Handle emoji selection."""
        idx = sender.tag()
        reaction_id = self.reactions[idx]

        if reaction_id == 'done':
            # Done dismisses the bubble
            self.write_response('done')
            self.dismiss()
        else:
            # Other reactions write response but keep bubble open
            emoji_map = {
                'thumbsup': '👍', 'thumbsdown': '👎', 'yes': '✓', 'no': '✗',
                'heart': '❤️', 'question': '❓'
            }
            emoji = emoji_map.get(reaction_id, reaction_id)
            self.write_response('reaction', emoji=emoji)

            # Hide picker and restore reply/reaction buttons
            self._hide_picker(self.window())

    def write_response(self, action, text=None, emoji=None):
        """Write response to file."""
        response = {
            'action': action,
            'timestamp': datetime.now().isoformat()
        }
        if text:
            response['text'] = text
        if emoji:
            response['emoji'] = emoji

        with open(RESPONSE_FILE, 'w') as f:
            json.dump(response, f, indent=2)

    def updateMessage_(self, new_message):
        """Update the bubble message (called via IPC)."""
        self.message = new_message
        self.messages = [{"role": "claude", "text": new_message}]
        self._refresh_display()

    def appendMessage_(self, text, role="claude", image_path=None):
        """Append a message to the chat history, optionally with an inline image."""
        msg = {"role": role, "text": text}
        if image_path and os.path.exists(image_path):
            msg["image"] = image_path
        self.messages.append(msg)
        self._refresh_display()

    def _refresh_display(self):
        """Refresh the display with current messages."""
        colors = get_theme_colors()

        if not self.messages:
            self.message_label.setStringValue_("")
            return

        # Reset inline image tracking
        self.inline_image_heights = []

        # Create attributed string with markdown support
        attr_string = NSMutableAttributedString.alloc().init()

        # Paragraph styles for alignment
        left_style = NSMutableParagraphStyle.alloc().init()
        left_style.setAlignment_(NSTextAlignmentLeft)
        left_style.setLineBreakMode_(NSLineBreakByWordWrapping)

        right_style = NSMutableParagraphStyle.alloc().init()
        right_style.setAlignment_(NSTextAlignmentRight)
        right_style.setLineBreakMode_(NSLineBreakByWordWrapping)

        lines = []
        for i, msg in enumerate(self.messages[-6:]):  # Show last 6 messages
            role = msg.get("role", "claude")
            text = msg.get("text", "")
            image_path = msg.get("image")

            if i > 0:
                # Add newline between messages
                newline = NSMutableAttributedString.alloc().initWithString_("\n")
                attr_string.appendAttributedString_(newline)

            if role == "user":
                # Right-align user messages with markdown support
                user_text = f"You: {text}"
                lines.append(user_text)
                msg_attr = parse_markdown(user_text)
                # Apply right alignment and secondary color to entire string
                full_range = (0, msg_attr.length())
                msg_attr.addAttribute_value_range_(NSParagraphStyleAttributeName, right_style, full_range)
                msg_attr.addAttribute_value_range_(NSForegroundColorAttributeName, colors['secondary'], full_range)
            else:
                # Left-align Claude messages with markdown
                lines.append(text)
                msg_attr = parse_markdown(text)
                # Apply left alignment
                full_range = (0, msg_attr.length())
                msg_attr.addAttribute_value_range_(NSParagraphStyleAttributeName, left_style, full_range)

            attr_string.appendAttributedString_(msg_attr)

            # Add inline image if present
            if image_path and os.path.exists(image_path):
                try:
                    from AppKit import NSTextAttachment, NSImage, NSTextAttachmentCell, NSAttributedString
                    from Foundation import NSMakeSize

                    # Add newline before image
                    newline = NSMutableAttributedString.alloc().initWithString_("\n")
                    attr_string.appendAttributedString_(newline)

                    # Load and scale image
                    image = NSImage.alloc().initWithContentsOfFile_(image_path)
                    if image:
                        # Scale image to fit bubble width (max ~350px)
                        orig_size = image.size()
                        max_width = 350
                        scale = 1.0
                        if orig_size.width > max_width:
                            scale = max_width / orig_size.width

                        # Calculate final display size
                        display_width = orig_size.width * scale
                        display_height = orig_size.height * scale

                        # Apply size to image
                        if scale < 1.0:
                            new_size = NSMakeSize(display_width, display_height)
                            image.setSize_(new_size)

                        # Track this image's height for window sizing
                        self.inline_image_heights.append(display_height)

                        # Create text attachment with image
                        attachment = NSTextAttachment.alloc().init()
                        cell = NSTextAttachmentCell.alloc().initImageCell_(image)
                        attachment.setAttachmentCell_(cell)

                        # Create attributed string from attachment
                        img_attr = NSAttributedString.attributedStringWithAttachment_(attachment)
                        attr_string.appendAttributedString_(img_attr)
                        lines.append("[image]")
                except Exception as e:
                    debug_log(f"Failed to embed image {image_path}: {e}")

        self.message = "\n".join(lines)
        # NSTextView uses textStorage instead of setAttributedStringValue_
        self.message_label.textStorage().setAttributedString_(attr_string)

        # Resize window if needed
        self._resize_for_content()
        self.layout_subviews()
        self.setNeedsDisplay_(True)

    def _resize_for_content(self):
        """Resize window to fit content using actual text metrics."""
        window = self.window()
        if not window:
            return

        current_frame = window.frame()

        # Calculate padding for arrow
        pad_left = PADDING + (ARROW_SIZE if self.arrow_direction == 'left' else 0)
        pad_right = PADDING + (ARROW_SIZE if self.arrow_direction == 'right' else 0)
        pad_top = PADDING + (ARROW_SIZE if self.arrow_direction == 'up' else 0)
        pad_bottom = PADDING + (ARROW_SIZE if self.arrow_direction == 'down' else 0)

        # Use NSString's size calculation for accurate measurement
        font = NSFont.systemFontOfSize_(14)
        attrs = {NSFontAttributeName: font}

        from AppKit import NSStringDrawingUsesLineFragmentOrigin
        from Foundation import NSString

        # Check if we have inline images
        has_inline_images = hasattr(self, 'inline_image_heights') and self.inline_image_heights

        # Calculate dynamic width based on content
        icon_bar_width = ICON_SIZE * 2 + 16  # Two icons plus spacing
        min_content_width = icon_bar_width + pad_left + pad_right

        if has_inline_images or (self.current_image_size[1] > 0 and not self.image_view.isHidden()):
            # Images need full width
            new_width = MAX_WIDTH
        else:
            # Measure natural text width (unconstrained)
            ns_string = NSString.stringWithString_(self.message)
            unconstrained_rect = ns_string.boundingRectWithSize_options_attributes_(
                (10000, 10000),
                NSStringDrawingUsesLineFragmentOrigin,
                attrs
            )
            natural_text_width = unconstrained_rect.size.width
            content_width = natural_text_width + pad_left + pad_right + 20

            # Dynamic width clamped to limits
            new_width = max(min_content_width, min(content_width, MAX_WIDTH))

        # Now calculate height using the determined width
        text_width = new_width - pad_left - pad_right
        ns_string = NSString.stringWithString_(self.message)
        bounding_rect = ns_string.boundingRectWithSize_options_attributes_(
            (text_width, 10000),
            NSStringDrawingUsesLineFragmentOrigin,
            attrs
        )
        text_height = bounding_rect.size.height

        # Add extra height for markdown formatting (headers are taller, lists have spacing)
        line_count = self.message.count('\n') + 1
        if '##' in self.message or line_count > 3:
            text_height += line_count * 4

        # Add image height if visible (old image_view above text)
        img_height = 0
        if self.current_image_size[1] > 0 and not self.image_view.isHidden():
            img_height = self.current_image_size[1] + 4

        # Add heights of inline images in chat
        inline_img_height = 0
        if has_inline_images:
            inline_img_height = sum(self.inline_image_heights) + len(self.inline_image_heights) * 8

        # Components: old image + text area + inline images + gap + icon bar + padding
        needed_height = img_height + text_height + inline_img_height + 8 + ICON_SIZE + pad_top + pad_bottom

        # Apply height limits
        min_height = 80
        max_height = 800
        new_height = max(min_height, min(needed_height, max_height))

        # Only resize if significant change (avoid jitter)
        width_changed = abs(new_width - current_frame.size.width) > 5
        height_changed = abs(new_height - current_frame.size.height) > 5

        if width_changed or height_changed:
            # Get screen bounds to keep bubble on-screen
            screen = NSScreen.mainScreen()
            screen_frame = screen.visibleFrame() if screen else None

            # Calculate new position
            if self.point_at and self.arrow_direction:
                # Anchor arrow tip to original point_at coordinate
                # Arrow tip is AT the window bounds edge (not extending beyond)
                x, y = self.point_at
                if self.arrow_direction == 'left':
                    new_x = x  # Arrow tip at left edge
                    new_y = y - new_height / 2
                elif self.arrow_direction == 'right':
                    new_x = x - new_width  # Arrow tip at right edge
                    new_y = y - new_height / 2
                elif self.arrow_direction == 'up':
                    new_x = x - new_width / 2
                    new_y = y - new_height  # Arrow tip at top edge
                else:  # down
                    new_x = x - new_width / 2
                    new_y = y  # Arrow tip at bottom edge
            else:
                # Non-point-at case: grow from current position
                delta_h = new_height - current_frame.size.height
                new_x = current_frame.origin.x
                new_y = current_frame.origin.y - delta_h

            # Keep bubble on screen
            if screen_frame:
                # Don't go off right edge
                max_x = screen_frame.origin.x + screen_frame.size.width - new_width
                if new_x > max_x:
                    new_x = max_x
                # Don't go off left edge
                if new_x < screen_frame.origin.x:
                    new_x = screen_frame.origin.x
                # Don't go off bottom
                if new_y < screen_frame.origin.y:
                    new_y = screen_frame.origin.y
                # Don't go off top
                max_y = screen_frame.origin.y + screen_frame.size.height - new_height
                if new_y > max_y:
                    new_y = max_y

            new_frame = NSMakeRect(new_x, new_y, new_width, new_height)
            window.setFrame_display_animate_(new_frame, True, True)

            # Save updated position and size to state file (convert to grid %)
            # Use CGDisplayBounds for consistency with other position-saving code
            display_bounds = CGDisplayBounds(CGMainDisplayID())
            screen_w = display_bounds.size.width
            screen_h = display_bounds.size.height
            x_pct = (new_x + new_width / 2) / screen_w * 100
            y_pct = 100 - (new_y + new_height / 2) / screen_h * 100
            w_pct = (new_width / screen_w * 100) + 4  # Add padding
            h_pct = (new_height / screen_h * 100) + 4
            update_position_in_state(x_pct, y_pct, w_pct, h_pct)

    def dismiss(self):
        """Close the window."""
        window = self.window()
        if window:
            NSApp.terminate_(None)


class BubbleWindow:
    """Manager for the bubble window."""

    def __init__(self):
        self.window = None
        self.content_view = None
        self.command_timer = None
        self.crop = None  # Crop specification for images

    def start_command_polling(self):
        """Start polling for commands from shell script."""
        self.command_timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            0.15,  # Check every 150ms for responsive command handling
            self,
            objc.selector(self.checkCommands_, signature=b'v@:@'),
            None,
            True
        )

    def checkCommands_(self, timer):
        """Check for commands from shell script."""
        debug_log("checkCommands_ called")
        if not os.path.exists(COMMAND_FILE):
            return

        debug_log(f"Found command file")
        try:
            with open(COMMAND_FILE, 'r') as f:
                content = f.read()

            debug_log(f"Read content: {content[:100]}")

            # Parse JSON - if this fails, we log and clean up
            try:
                cmd = json.loads(content)
            except json.JSONDecodeError as e:
                print(f"ERROR: Invalid JSON in command file: {e}", file=sys.stderr)
                print(f"Content was: {content[:200]}", file=sys.stderr)
                debug_log(f"JSON parse error: {e}")
                # Remove bad command file to prevent infinite retry
                try:
                    os.unlink(COMMAND_FILE)
                except:
                    pass
                return

            # Remove command file after successful parse
            try:
                os.unlink(COMMAND_FILE)
                debug_log("Removed command file")
            except:
                pass

            command = cmd.get('command')
            success = False
            debug_log(f"Processing command: {command}")

            if command == 'update':
                new_message = cmd.get('message', '')
                position = cmd.get('position')
                point_at = cmd.get('point_at')
                in_app = cmd.get('in_app')
                arrow_hint = cmd.get('arrow')
                status = cmd.get('status')
                if self.content_view:
                    debug_log(f"Calling updateMessage_ with: {new_message[:50]}")
                    self.content_view.updateMessage_(new_message)
                    # Handle status line (empty string = hide)
                    self.content_view.handleStatus_(status)
                    # Handle repositioning if point_at specified
                    if point_at:
                        debug_log(f"Setting point_at={point_at} with arrow={arrow_hint}")
                        self.content_view.setPointAt_(point_at, in_app, arrow_hint)
                    # Handle position change if specified
                    elif position:
                        self.content_view.moveTo_(position, in_app)
                    success = True
                    debug_log("updateMessage_ completed")
            elif command == 'append':
                message = cmd.get('message', '')
                role = cmd.get('role', 'claude')
                image_path = cmd.get('image')
                point_at = cmd.get('point_at')
                in_app = cmd.get('in_app')
                arrow_hint = cmd.get('arrow')
                status = cmd.get('status')
                if self.content_view:
                    debug_log(f"Calling appendMessage_ with role={role}, image={image_path}: {message[:50]}")
                    self.content_view.appendMessage_(message, role, image_path)
                    # Handle status line (empty string = hide)
                    self.content_view.handleStatus_(status)
                    # Handle repositioning if point_at specified (auto-detects x,y vs x,y,w,h)
                    if point_at:
                        debug_log(f"Setting point_at={point_at} with arrow={arrow_hint}")
                        self.content_view.setPointAt_(point_at, in_app, arrow_hint)
                    success = True
                    debug_log("appendMessage_ completed")
            elif command == 'move':
                # Animate bubble to new position
                position = cmd.get('position', '')
                point_at = cmd.get('point_at')
                in_app = cmd.get('in_app')
                if position and self.window:
                    self.animate_to_position(position, point_at, in_app)
                    success = True
            elif command == 'clear-arrow':
                # Remove the arrow from the bubble
                if self.content_view:
                    self.content_view.clearArrow()
                    success = True
            elif command == 'point-at':
                # Point at a target (repositions bubble to point optimally)
                point_at = cmd.get('point_at')
                in_app = cmd.get('in_app')
                if point_at and self.content_view:
                    self.content_view.setPointAt_(point_at, in_app)
                    success = True
            elif command == 'status':
                # Update only the status line (used by --read to show "Listening...")
                status = cmd.get('status', '')
                if self.content_view:
                    self.content_view.handleStatus_(status)
                    success = True
            elif command == 'dismiss':
                # Write ack before terminating
                self._write_ack(command)
                NSApp.terminate_(None)
                return

            # Write acknowledgment file on success
            if success:
                self._write_ack(command)
                debug_log(f"Wrote ack for command: {command}")

        except IOError as e:
            print(f"ERROR: Failed to read command file: {e}", file=sys.stderr)
            # Try to clean up
            try:
                os.unlink(COMMAND_FILE)
            except:
                pass

    def _write_ack(self, command):
        """Write acknowledgment file to confirm command was processed."""
        try:
            ack = {
                'status': 'ok',
                'command': command,
                'timestamp': datetime.now().isoformat()
            }
            with open(ACK_FILE, 'w') as f:
                json.dump(ack, f)
        except IOError as e:
            print(f"WARNING: Failed to write ack file: {e}", file=sys.stderr)

    def animate_to_position(self, position, point_at=None, in_app=None):
        """Animate the bubble to a new screen position.

        Args:
            position: "x,y" position (grid % or pixels)
            point_at: Optional "x,y" target to point at (if not provided, clears arrow)
            in_app: Optional app name for app-relative point-at coordinates
        """
        try:
            # Parse position (grid % or pixels)
            px, py = map(float, position.split(','))

            display_bounds = CGDisplayBounds(CGMainDisplayID())
            screen_width = display_bounds.size.width
            screen_height = display_bounds.size.height

            current_frame = self.window.frame()

            # Convert grid percentage to pixels
            # Y is flipped so 0=top, 100=bottom (user-friendly)
            if px <= 100 and py <= 100:
                x = (px / 100.0) * screen_width - current_frame.size.width / 2
                y = ((100 - py) / 100.0) * screen_height - current_frame.size.height / 2
            else:
                x, y = px, py

            # Keep on screen
            x = max(10, min(x, screen_width - current_frame.size.width - 10))
            y = max(10, min(y, screen_height - current_frame.size.height - 10))

            new_frame = NSMakeRect(x, y, current_frame.size.width, current_frame.size.height)

            # Animate the move
            self.window.setFrame_display_animate_(new_frame, True, True)

            # Save updated position and size to state file (convert back to grid %)
            w = current_frame.size.width
            h = current_frame.size.height
            x_pct = (x + w / 2) / screen_width * 100
            y_pct = 100 - (y + h / 2) / screen_height * 100
            w_pct = (w / screen_width * 100) + 4  # Add padding
            h_pct = (h / screen_height * 100) + 4
            update_position_in_state(x_pct, y_pct, w_pct, h_pct)

            # Update point_at target if provided, otherwise clear the arrow
            if self.content_view:
                if point_at:
                    self.content_view.setPointAt_(point_at, in_app)
                else:
                    # Clear arrow when moving without a new point_at target
                    self.content_view.clearArrow()
        except (ValueError, AttributeError):
            pass

    def clear_arrow(self):
        """Clear the arrow from the bubble."""
        if self.content_view:
            self.content_view.clearArrow()

    def create_window(self, message, image_path=None, position=None, point_at=None, in_app=None, arrow_hint=None, status_text=None):
        """Create and show the bubble window."""
        # Calculate size based on content
        width, height = self.calculate_size(message, image_path)

        # Add space for arrow if pointing at something
        if point_at:
            width += ARROW_SIZE
            height += ARROW_SIZE

        # Get main display bounds (with fallback to NSScreen if CG returns 0)
        display_bounds = CGDisplayBounds(CGMainDisplayID())
        screen_width = display_bounds.size.width
        screen_height = display_bounds.size.height

        # Fallback to NSScreen if CGDisplayBounds returns 0
        if screen_width == 0 or screen_height == 0:
            main_screen = NSScreen.mainScreen()
            if main_screen:
                frame = main_screen.frame()
                screen_width = frame.size.width
                screen_height = frame.size.height
            else:
                # Ultimate fallback to common resolution
                screen_width = 1920
                screen_height = 1080

        # Default position: bottom-right of main display
        if position is None:
            x = screen_width - width - 40
            y = 100  # Near bottom (macOS uses bottom-left origin)
        else:
            px, py = position
            # If grid percentages (0-100), convert to pixels
            # Y is flipped so 0=top, 100=bottom (user-friendly, matches point-at)
            if px <= 100 and py <= 100:
                x = (px / 100.0) * screen_width
                y = ((100 - py) / 100.0) * screen_height  # Flip y for macOS
            else:
                x, y = px, py

        # Clamp to screen bounds (keep bubble fully visible)
        margin = 10
        original_x, original_y = x, y
        x = max(margin, min(x, screen_width - width - margin))
        y = max(margin, min(y, screen_height - height - margin))

        # Warn if position was clamped
        if abs(x - original_x) > 1 or abs(y - original_y) > 1:
            print(f"WARNING: Position clamped to keep bubble on screen", file=sys.stderr)

        frame = NSMakeRect(x, y, width, height)

        # Create borderless panel (no focus ring, floats above other windows)
        self.window = BubbleNSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
            frame,
            NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel,
            NSBackingStoreBuffered,
            False
        )

        # Configure panel
        self.window.setLevel_(NSFloatingWindowLevel)
        self.window.setOpaque_(False)
        self.window.setBackgroundColor_(NSColor.clearColor())
        self.window.setHasShadow_(True)
        self.window.setMovableByWindowBackground_(True)
        self.window.setCollectionBehavior_(1 << 0)  # Can join all spaces
        self.window.setFloatingPanel_(True)
        self.window.setBecomesKeyOnlyIfNeeded_(True)
        self.window.setHidesOnDeactivate_(False)

        # Enable mouse tracking
        self.window.setAcceptsMouseMovedEvents_(True)

        # Create content view
        self.content_view = BubbleContentView.alloc().initWithFrame_(
            NSMakeRect(0, 0, width, height)
        )
        self.content_view.setMessage_(message)

        # Set image if provided
        if image_path:
            self.content_view.setImage_(image_path, self.crop)

        self.window.setContentView_(self.content_view)

        # Disable focus rings on all controls
        self.content_view.setFocusRingType_(1)  # NSFocusRingTypeNone

        # Set point-at target if provided (auto-detects x,y vs x,y,w,h)
        if point_at:
            self.content_view.setPointAt_(point_at, in_app, arrow_hint)

        # Set initial status if provided
        if status_text:
            self.content_view.handleStatus_(status_text)

        # Show window without making it key (avoids focus ring)
        self.window.orderFrontRegardless()

        # Save state with actual window position and size (not input position)
        # Calculate actual center as grid percentage
        actual_x_pct = (x + width / 2) / screen_width * 100
        actual_y_pct = 100 - (y + height / 2) / screen_height * 100
        # Calculate size as grid percentage (with padding for safety)
        size_w_pct = (width / screen_width * 100) + 4  # Add 2% padding each side
        size_h_pct = (height / screen_height * 100) + 4
        self.save_state(message, image_path, [actual_x_pct, actual_y_pct], [size_w_pct, size_h_pct])

        # Start polling for commands
        self.start_command_polling()

    def calculate_size(self, message, image_path=None):
        """Calculate bubble size based on content."""
        from AppKit import NSStringDrawingUsesLineFragmentOrigin
        from Foundation import NSString

        # Use proper text measurement
        font = NSFont.systemFontOfSize_(14)
        attrs = {NSFontAttributeName: font}
        ns_string = NSString.stringWithString_(message)

        # First, measure text width without constraints to get natural width
        unconstrained_rect = ns_string.boundingRectWithSize_options_attributes_(
            (10000, 10000),
            NSStringDrawingUsesLineFragmentOrigin,
            attrs
        )
        natural_text_width = unconstrained_rect.size.width

        # Calculate width: text + padding + space for icons (reply + reaction buttons)
        icon_bar_width = ICON_SIZE * 2 + 16  # Two icons plus spacing
        content_width = natural_text_width + PADDING * 2

        # Width must accommodate icon bar at minimum
        min_content_width = icon_bar_width + PADDING * 2

        # Dynamic width: fit content but respect min/max
        if image_path and os.path.exists(image_path):
            # Images need more width
            width = MAX_WIDTH
        else:
            # For text-only, use natural width clamped to limits
            width = max(min_content_width, min(content_width + 20, MAX_WIDTH))

        # Calculate text height using the determined width
        text_width = width - PADDING * 2
        bounding_rect = ns_string.boundingRectWithSize_options_attributes_(
            (text_width, 10000),
            NSStringDrawingUsesLineFragmentOrigin,
            attrs
        )
        text_height = bounding_rect.size.height

        # Add extra for markdown formatting and newlines
        line_count = message.count('\n') + 1
        if '##' in message or line_count > 2:
            text_height += line_count * 6  # Extra spacing per line

        # Add space for icons
        height = text_height + ICON_SIZE + PADDING * 3 + 10

        # Add image height if present
        if image_path and os.path.exists(image_path):
            height += 150  # Image preview height

        return (width, height)

    def save_state(self, message, image_path, position, size=None):
        """Save current state to file."""
        state = {
            'visible': True,
            'pid': os.getpid(),
            'message': message,
            'image_path': image_path,
            'position': position,
            'size': size,  # [width%, height%] in grid percentages
            'timestamp': datetime.now().isoformat()
        }
        with open(STATE_FILE, 'w') as f:
            json.dump(state, f, indent=2)


def read_response(block=True, timeout=None):
    """Read response from file."""
    start = time.time()

    while True:
        if os.path.exists(RESPONSE_FILE):
            try:
                with open(RESPONSE_FILE, 'r') as f:
                    response = json.load(f)
                # Delete file after reading
                os.unlink(RESPONSE_FILE)
                return response
            except (json.JSONDecodeError, IOError):
                pass

        if not block:
            return None

        if timeout and (time.time() - start) > timeout:
            return None

        time.sleep(0.1)


def check_status():
    """Check dependencies and show status."""
    print("Bubble GUI Status")
    print("-" * 40)

    # Check PyObjC
    try:
        from AppKit import NSWindow
        print("[OK] PyObjC/AppKit available")
    except ImportError:
        print("[MISSING] PyObjC/AppKit - install with: pip install pyobjc")

    # Check state file
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, 'r') as f:
                state = json.load(f)
            print(f"[INFO] Bubble state: visible={state.get('visible', False)}, pid={state.get('pid')}")
        except:
            print("[INFO] No active bubble")
    else:
        print("[INFO] No active bubble")

    # Check socket
    if os.path.exists(SOCKET_PATH):
        print(f"[INFO] IPC socket exists: {SOCKET_PATH}")
    else:
        print("[INFO] No IPC socket")


def dismiss_bubble():
    """Dismiss any running bubble."""
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, 'r') as f:
                state = json.load(f)
            pid = state.get('pid')
            if pid:
                os.kill(pid, 15)  # SIGTERM
                print("Bubble dismissed")
        except:
            pass
        os.unlink(STATE_FILE)


def main():
    parser = argparse.ArgumentParser(description="Lightweight chat bubble GUI")
    parser.add_argument("--show", metavar="MESSAGE", help="Display bubble with message")
    parser.add_argument("--image", metavar="PATH", help="Include image in bubble")
    parser.add_argument("--crop", metavar="X,Y,W,H", help="Crop image region (pixels or %% like 25,25,50,50)")
    parser.add_argument("--position", metavar="X,Y", help="Position (grid %% or pixels)")
    parser.add_argument("--point-at", metavar="X,Y[,W,H]", dest="point_at", help="Point arrow at location (or bounding box)")
    parser.add_argument("--arrow", metavar="DIR", choices=['left', 'right', 'up', 'down'], help="Hint arrow direction")
    parser.add_argument("--in-app", metavar="APP", dest="in_app", help="App name for app-relative point-at coords")
    parser.add_argument("--read", action="store_true", help="Read response (blocks)")
    parser.add_argument("--read-nowait", action="store_true", help="Read response (non-blocking)")
    parser.add_argument("--dismiss", action="store_true", help="Dismiss bubble")
    parser.add_argument("--status", action="store_true", help="Show status")
    parser.add_argument("--status-text", metavar="TEXT", dest="status_text", help="Status line text (use 'busy:text' for shimmer)")

    args = parser.parse_args()

    if args.status:
        check_status()
        return

    if args.dismiss:
        dismiss_bubble()
        return

    if args.read or args.read_nowait:
        response = read_response(block=args.read)
        if response:
            print(json.dumps(response))
        else:
            print("{}")
        return

    if args.show:
        # Initialize app
        app = NSApplication.sharedApplication()
        app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)

        # Create and show bubble
        bubble = BubbleWindow()

        position = None
        if args.position:
            parts = args.position.split(',')
            if len(parts) == 2:
                position = (float(parts[0]), float(parts[1]))

        # Set crop if specified
        if args.crop:
            bubble.crop = args.crop

        bubble.create_window(args.show, args.image, position, args.point_at, args.in_app, args.arrow, args.status_text)

        # Run event loop
        app.run()
        return

    parser.print_help()
    sys.exit(1)


if __name__ == "__main__":
    main()
