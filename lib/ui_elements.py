#!/usr/bin/env python3
"""
UI Element detection using macOS Accessibility API via ctypes.
Finds toggles, buttons, checkboxes, and other interactive elements.
"""

import sys
import json
import argparse
import subprocess
from typing import Optional, List, Any
import ctypes
from ctypes import c_void_p, c_int32, c_int64, c_double, byref, POINTER, c_bool, c_uint32

# Load CoreFoundation and ApplicationServices
CF = ctypes.cdll.LoadLibrary('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
AppServices = ctypes.cdll.LoadLibrary('/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices')

# CoreFoundation types and functions
CFTypeRef = c_void_p
CFStringRef = c_void_p
CFArrayRef = c_void_p
CFIndex = c_int64
AXUIElementRef = c_void_p
AXError = c_int32

# CoreFoundation functions
CF.CFRelease.argtypes = [CFTypeRef]
CF.CFRelease.restype = None

CF.CFArrayGetCount.argtypes = [CFArrayRef]
CF.CFArrayGetCount.restype = CFIndex

CF.CFArrayGetValueAtIndex.argtypes = [CFArrayRef, CFIndex]
CF.CFArrayGetValueAtIndex.restype = c_void_p

CF.CFStringGetCString.argtypes = [CFStringRef, ctypes.c_char_p, CFIndex, c_uint32]
CF.CFStringGetCString.restype = c_bool

CF.CFStringCreateWithCString.argtypes = [c_void_p, ctypes.c_char_p, c_uint32]
CF.CFStringCreateWithCString.restype = CFStringRef

CF.CFGetTypeID.argtypes = [CFTypeRef]
CF.CFGetTypeID.restype = c_uint32

CF.CFStringGetTypeID.argtypes = []
CF.CFStringGetTypeID.restype = c_uint32

CF.CFNumberGetTypeID.argtypes = []
CF.CFNumberGetTypeID.restype = c_uint32

CF.CFBooleanGetTypeID.argtypes = []
CF.CFBooleanGetTypeID.restype = c_uint32

CF.CFNumberGetValue.argtypes = [c_void_p, c_int32, c_void_p]
CF.CFNumberGetValue.restype = c_bool

CF.CFBooleanGetValue.argtypes = [c_void_p]
CF.CFBooleanGetValue.restype = c_bool

# AX functions
AppServices.AXUIElementCreateApplication.argtypes = [c_int32]
AppServices.AXUIElementCreateApplication.restype = AXUIElementRef

AppServices.AXUIElementCopyAttributeValue.argtypes = [AXUIElementRef, CFStringRef, POINTER(CFTypeRef)]
AppServices.AXUIElementCopyAttributeValue.restype = AXError

AppServices.AXUIElementCopyAttributeNames.argtypes = [AXUIElementRef, POINTER(CFArrayRef)]
AppServices.AXUIElementCopyAttributeNames.restype = AXError

AppServices.AXValueGetType.argtypes = [c_void_p]
AppServices.AXValueGetType.restype = c_int32

AppServices.AXValueGetValue.argtypes = [c_void_p, c_int32, c_void_p]
AppServices.AXValueGetValue.restype = c_bool

# Constants
kCFStringEncodingUTF8 = 0x08000100
kAXErrorSuccess = 0
kAXValueTypeCGPoint = 1
kAXValueTypeCGSize = 2
kCFNumberFloat64Type = 13


class CGPoint(ctypes.Structure):
    _fields_ = [("x", c_double), ("y", c_double)]


class CGSize(ctypes.Structure):
    _fields_ = [("width", c_double), ("height", c_double)]


def cfstring_to_python(cfstring: CFStringRef) -> Optional[str]:
    """Convert CFString to Python string."""
    if not cfstring:
        return None
    buffer = ctypes.create_string_buffer(1024)
    if CF.CFStringGetCString(cfstring, buffer, 1024, kCFStringEncodingUTF8):
        return buffer.value.decode('utf-8')
    return None


def python_to_cfstring(s: str) -> CFStringRef:
    """Convert Python string to CFString."""
    return CF.CFStringCreateWithCString(None, s.encode('utf-8'), kCFStringEncodingUTF8)


def cfvalue_to_python(value: CFTypeRef) -> Any:
    """Convert a CFTypeRef to a Python value."""
    if not value:
        return None

    type_id = CF.CFGetTypeID(value)

    if type_id == CF.CFStringGetTypeID():
        return cfstring_to_python(value)

    if type_id == CF.CFBooleanGetTypeID():
        return bool(CF.CFBooleanGetValue(value))

    if type_id == CF.CFNumberGetTypeID():
        num = c_double()
        if CF.CFNumberGetValue(value, kCFNumberFloat64Type, byref(num)):
            return num.value
        return None

    # Check if it's an AXValue (position/size)
    ax_type = AppServices.AXValueGetType(value)
    if ax_type == kAXValueTypeCGPoint:
        point = CGPoint()
        if AppServices.AXValueGetValue(value, kAXValueTypeCGPoint, byref(point)):
            return {'type': 'point', 'x': point.x, 'y': point.y}

    if ax_type == kAXValueTypeCGSize:
        size = CGSize()
        if AppServices.AXValueGetValue(value, kAXValueTypeCGSize, byref(size)):
            return {'type': 'size', 'width': size.width, 'height': size.height}

    return None


def get_ax_attribute(element: AXUIElementRef, attribute: str) -> Any:
    """Get an accessibility attribute from an element."""
    attr_cf = python_to_cfstring(attribute)
    value = CFTypeRef()
    err = AppServices.AXUIElementCopyAttributeValue(element, attr_cf, byref(value))
    CF.CFRelease(attr_cf)

    if err != kAXErrorSuccess or not value:
        return None

    return value.value  # Return raw CFTypeRef for further processing


def get_ax_attribute_value(element: AXUIElementRef, attribute: str) -> Any:
    """Get an accessibility attribute and convert to Python value."""
    raw = get_ax_attribute(element, attribute)
    if raw is None:
        return None
    return cfvalue_to_python(raw)


def get_ax_children(element: AXUIElementRef) -> List[AXUIElementRef]:
    """Get children of an element."""
    children_ref = get_ax_attribute(element, "AXChildren")
    if not children_ref:
        return []

    count = CF.CFArrayGetCount(children_ref)
    children = []
    for i in range(count):
        child = CF.CFArrayGetValueAtIndex(children_ref, i)
        if child:
            children.append(child)
    return children


def get_element_info(element: AXUIElementRef) -> dict:
    """Extract relevant info from an AX element."""
    role = get_ax_attribute_value(element, "AXRole") or ""
    role_desc = get_ax_attribute_value(element, "AXRoleDescription") or ""
    title = get_ax_attribute_value(element, "AXTitle") or ""
    description = get_ax_attribute_value(element, "AXDescription") or ""
    help_text = get_ax_attribute_value(element, "AXHelp") or ""
    value = get_ax_attribute_value(element, "AXValue")
    identifier = get_ax_attribute_value(element, "AXIdentifier") or ""

    # Get position and size
    pos_raw = get_ax_attribute(element, "AXPosition")
    size_raw = get_ax_attribute(element, "AXSize")

    position = None
    if pos_raw and size_raw:
        pos = cfvalue_to_python(pos_raw)
        size = cfvalue_to_python(size_raw)
        if pos and size and pos.get('type') == 'point' and size.get('type') == 'size':
            position = {
                'x': int(pos['x']),
                'y': int(pos['y']),
                'width': int(size['width']),
                'height': int(size['height']),
                'center_x': int(pos['x'] + size['width'] / 2),
                'center_y': int(pos['y'] + size['height'] / 2)
            }

    # Determine element type from role
    element_type = "unknown"
    role_lower = role.lower() if role else ""

    if "checkbox" in role_lower:
        element_type = "toggle"
    elif "switch" in role_lower:
        element_type = "toggle"
    elif "button" in role_lower:
        # Check if it's an info button
        desc_lower = (description or "").lower()
        id_lower = (identifier or "").lower()
        if "info" in desc_lower or "info" in id_lower or role_desc == "info button":
            element_type = "info"
        else:
            element_type = "button"
    elif "radiobutton" in role_lower:
        element_type = "radio"
    elif "textfield" in role_lower or "textarea" in role_lower:
        element_type = "text_field"
    elif "slider" in role_lower:
        element_type = "slider"
    elif "link" in role_lower:
        element_type = "link"
    elif "image" in role_lower:
        element_type = "image"
    elif "statictext" in role_lower:
        element_type = "text"
    elif "group" in role_lower:
        element_type = "group"
    elif "row" in role_lower:
        element_type = "row"
    elif "cell" in role_lower:
        element_type = "cell"

    return {
        'role': role,
        'role_description': role_desc,
        'type': element_type,
        'title': title,
        'description': description,
        'help': help_text,
        'value': value,
        'identifier': identifier,
        'position': position,
        '_element': element  # Keep reference for later use
    }


def walk_element_tree(element: AXUIElementRef, depth: int = 0, max_depth: int = 15,
                      filter_types: Optional[List[str]] = None,
                      include_all: bool = False) -> List[dict]:
    """
    Recursively walk the accessibility element tree.
    Returns list of elements matching filter criteria.
    """
    if depth > max_depth:
        return []

    results = []
    info = get_element_info(element)

    # Check if this element matches our filter
    should_include = False
    if filter_types is None:
        # Include interactive elements by default
        if info['type'] in ('toggle', 'button', 'info', 'radio', 'slider', 'link', 'text_field'):
            should_include = True
        elif include_all:
            should_include = True
    else:
        if info['type'] in filter_types:
            should_include = True

    if should_include and info['position']:
        results.append(info)

    # Get and process children
    children = get_ax_children(element)
    for child in children:
        results.extend(walk_element_tree(child, depth + 1, max_depth, filter_types, include_all))

    return results


def get_app_pid(app_name: str) -> Optional[int]:
    """Get PID for an application by name."""
    result = subprocess.run(['pgrep', '-x', app_name], capture_output=True, text=True)
    if result.stdout.strip():
        return int(result.stdout.strip().split()[0])

    # Try partial match
    result = subprocess.run(['pgrep', '-i', app_name], capture_output=True, text=True)
    if result.stdout.strip():
        return int(result.stdout.strip().split()[0])

    return None


def find_elements_in_app(app_name: str, filter_types: Optional[List[str]] = None) -> List[dict]:
    """Find UI elements in an application."""
    pid = get_app_pid(app_name)
    if pid is None:
        raise ValueError(f"Application not found: {app_name}")

    app_element = AppServices.AXUIElementCreateApplication(pid)
    if not app_element:
        raise ValueError(f"Could not access application: {app_name}")

    # Get windows
    windows_ref = get_ax_attribute(app_element, "AXWindows")
    if not windows_ref:
        raise ValueError(f"No windows found for: {app_name}")

    count = CF.CFArrayGetCount(windows_ref)
    all_elements = []

    for i in range(count):
        window = CF.CFArrayGetValueAtIndex(windows_ref, i)
        if window:
            elements = walk_element_tree(window, filter_types=filter_types)
            all_elements.extend(elements)

    return all_elements


def find_element_near_text(app_name: str, text: str, element_type: str,
                           search_radius: int = 300) -> Optional[dict]:
    """
    Find a UI element of a specific type near a text label.
    """
    pid = get_app_pid(app_name)
    if pid is None:
        raise ValueError(f"Application not found: {app_name}")

    app_element = AppServices.AXUIElementCreateApplication(pid)
    if not app_element:
        raise ValueError(f"Could not access application: {app_name}")

    windows_ref = get_ax_attribute(app_element, "AXWindows")
    if not windows_ref:
        raise ValueError(f"No windows found for: {app_name}")

    count = CF.CFArrayGetCount(windows_ref)

    text_elements = []
    target_elements = []

    for i in range(count):
        window = CF.CFArrayGetValueAtIndex(windows_ref, i)
        if window:
            all_elems = walk_element_tree(window, filter_types=None, include_all=True)
            for elem in all_elems:
                # Check if element contains our search text
                elem_text = (elem.get('title', '') or elem.get('description', '') or
                            str(elem.get('value', '') or '')).lower()
                if text.lower() in elem_text and elem.get('position'):
                    text_elements.append(elem)

                if elem['type'] == element_type and elem.get('position'):
                    target_elements.append(elem)

    if not text_elements:
        return None

    # Find the target element closest to matching text, preferring same row
    best_match = None
    best_score = float('inf')

    for text_elem in text_elements:
        text_pos = text_elem['position']

        for target in target_elements:
            target_pos = target['position']

            dx = target_pos['center_x'] - text_pos['center_x']
            dy = target_pos['center_y'] - text_pos['center_y']

            # Strong preference for elements to the right on same row
            if dx > 0 and abs(dy) < 40:
                score = dx
            elif abs(dy) < 40:
                score = abs(dx) + 1000
            else:
                score = (dx ** 2 + dy ** 2) ** 0.5 + 2000

            if score < best_score and score < search_radius + 2000:
                best_score = score
                best_match = target

    return best_match


def get_window_bounds(app_name: str) -> Optional[dict]:
    """Get the bounds of the app's main window using Quartz."""
    from Quartz import CGWindowListCopyWindowInfo, kCGWindowListOptionOnScreenOnly, kCGNullWindowID

    windows = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID)
    if not windows:
        return None
    for window in windows:
        owner = window.get('kCGWindowOwnerName', '')
        if app_name.lower() in owner.lower():
            bounds = window.get('kCGWindowBounds', {})
            if bounds:
                return {
                    'x': int(bounds.get('X', 0)),
                    'y': int(bounds.get('Y', 0)),
                    'width': int(bounds.get('Width', 0)),
                    'height': int(bounds.get('Height', 0))
                }
    return None


def convert_to_window_relative(element: dict, window_bounds: dict) -> dict:
    """Convert element position to window-relative percentages."""
    if not element.get('position'):
        return element

    pos = element['position']
    rel_x = pos['center_x'] - window_bounds['x']
    rel_y = pos['center_y'] - window_bounds['y']

    pct_x = (rel_x / window_bounds['width']) * 100
    pct_y = (rel_y / window_bounds['height']) * 100

    element['position']['pct_x'] = round(pct_x, 1)
    element['position']['pct_y'] = round(pct_y, 1)

    return element


def main():
    parser = argparse.ArgumentParser(description='Find UI elements using Accessibility API')
    parser.add_argument('--app', '-a', required=True, help='Application name')
    parser.add_argument('--list', '-l', action='store_true', help='List all interactive elements')
    parser.add_argument('--type', '-t', help='Filter by element type (toggle, button, info, etc.)')
    parser.add_argument('--near', '-n', help='Find element near this text label')
    parser.add_argument('--json', '-j', action='store_true', help='Output as JSON')
    parser.add_argument('--relative', '-r', action='store_true',
                        help='Output window-relative percentages')

    args = parser.parse_args()

    try:
        window_bounds = get_window_bounds(args.app)

        if args.near and args.type:
            # Find specific element near text
            element = find_element_near_text(args.app, args.near, args.type)

            if element is None:
                print(f"NOT_FOUND: No {args.type} found near '{args.near}'", file=sys.stderr)
                sys.exit(1)

            # Remove internal reference before output
            element.pop('_element', None)

            if args.relative and window_bounds:
                element = convert_to_window_relative(element, window_bounds)

            if args.json:
                print(json.dumps(element, indent=2, default=str))
            else:
                pos = element['position']
                if args.relative and 'pct_x' in pos:
                    print(f"FOUND: {element['type']} near '{args.near}'")
                    print(f"GRID: {pos['pct_x']},{pos['pct_y']}")
                    print(f"PIXEL: {pos['center_x']},{pos['center_y']}")
                else:
                    print(f"FOUND: {element['type']} near '{args.near}'")
                    print(f"PIXEL: {pos['center_x']},{pos['center_y']}")
                if element.get('value') is not None:
                    print(f"VALUE: {element['value']}")

        elif args.list:
            # List all elements
            filter_types = [args.type] if args.type else None
            elements = find_elements_in_app(args.app, filter_types=filter_types)

            # Remove internal references
            for elem in elements:
                elem.pop('_element', None)

            if args.relative and window_bounds:
                elements = [convert_to_window_relative(e, window_bounds) for e in elements]

            if args.json:
                print(json.dumps(elements, indent=2, default=str))
            else:
                # Group by type for readability
                by_type = {}
                for elem in elements:
                    t = elem['type']
                    if t not in by_type:
                        by_type[t] = []
                    by_type[t].append(elem)

                for elem_type, elems in sorted(by_type.items()):
                    print(f"\n=== {elem_type.upper()} ({len(elems)}) ===")
                    for elem in elems:
                        pos = elem['position']
                        label = elem['title'] or elem['description'] or elem['identifier'] or '(no label)'
                        value_str = f" = {elem['value']}" if elem.get('value') is not None else ""
                        help_str = f" [{elem['help']}]" if elem.get('help') else ""
                        if pos:
                            if args.relative and 'pct_x' in pos:
                                print(f"  [{pos['pct_x']:5.1f},{pos['pct_y']:5.1f}] {label[:50]}{value_str}{help_str}")
                            else:
                                print(f"  ({pos['center_x']:4d},{pos['center_y']:4d}) {label[:50]}{value_str}{help_str}")
                        else:
                            print(f"  (no position) {label[:50]}{value_str}{help_str}")

        else:
            parser.print_help()
            sys.exit(1)

    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
