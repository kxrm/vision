#!/usr/bin/env python3
"""
Clipboard operations using NSPasteboard for macOS.

Usage:
    clipboard.py --type                    # Get clipboard content type
    clipboard.py --read-text               # Read text from clipboard
    clipboard.py --read-image <output>     # Save clipboard image to file
    clipboard.py --read-files              # List files on clipboard
    clipboard.py --copy-text <text>        # Copy text to clipboard
    clipboard.py --copy-image <path>       # Copy image to clipboard
    clipboard.py --copy-file <path>        # Copy file reference to clipboard
"""

import sys
import os
import argparse

try:
    from AppKit import NSPasteboard, NSImage, NSPasteboardTypePNG, NSPasteboardTypeTIFF
    from Foundation import NSArray, NSURL
except ImportError:
    print("ERROR: AppKit/Foundation not available. Install pyobjc.", file=sys.stderr)
    sys.exit(1)

# Pasteboard type constants
NSStringPboardType = "public.utf8-plain-text"
NSFilenamesPboardType = "NSFilenamesPboardType"
NSTIFFPboardType = "public.tiff"
NSPNGPboardType = "public.png"


def get_pasteboard():
    """Get the general pasteboard."""
    return NSPasteboard.generalPasteboard()


def get_clipboard_type():
    """
    Detect clipboard content type.
    Returns: 'text', 'image', 'files', or 'empty'
    """
    pb = get_pasteboard()
    types = pb.types()

    if not types:
        return "empty"

    types_list = list(types)

    # Check for image types first (more specific)
    image_types = [NSPNGPboardType, NSTIFFPboardType, "public.jpeg",
                   NSPasteboardTypePNG, NSPasteboardTypeTIFF]
    for img_type in image_types:
        if img_type in types_list:
            return "image"

    # Check for files
    if NSFilenamesPboardType in types_list or "public.file-url" in types_list:
        return "files"

    # Check for text
    text_types = [NSStringPboardType, "public.plain-text", "NSStringPboardType"]
    for txt_type in text_types:
        if txt_type in types_list:
            return "text"

    return "empty"


def read_text():
    """Read text from clipboard."""
    pb = get_pasteboard()
    text = pb.stringForType_(NSStringPboardType)
    if text is None:
        text = pb.stringForType_("public.plain-text")
    return text if text else ""


def read_image(output_path):
    """
    Read image from clipboard and save to file.
    Returns: True on success, False on failure
    """
    pb = get_pasteboard()

    # Try PNG first
    png_data = pb.dataForType_(NSPNGPboardType)
    if png_data:
        png_data.writeToFile_atomically_(output_path, True)
        return True

    # Try TIFF and convert
    tiff_data = pb.dataForType_(NSTIFFPboardType)
    if tiff_data:
        image = NSImage.alloc().initWithData_(tiff_data)
        if image:
            # Convert to PNG
            tiff_rep = image.TIFFRepresentation()
            if tiff_rep:
                from AppKit import NSBitmapImageRep
                bitmap = NSBitmapImageRep.imageRepWithData_(tiff_rep)
                if bitmap:
                    png_data = bitmap.representationUsingType_properties_(
                        4,  # NSBitmapImageFileTypePNG
                        None
                    )
                    if png_data:
                        png_data.writeToFile_atomically_(output_path, True)
                        return True

    return False


def read_files():
    """
    Read file paths from clipboard.
    Returns: List of file paths
    """
    pb = get_pasteboard()

    # Try NSFilenamesPboardType first
    files = pb.propertyListForType_(NSFilenamesPboardType)
    if files:
        return list(files)

    # Try file URLs
    urls = pb.propertyListForType_("public.file-url")
    if urls:
        if isinstance(urls, str):
            # Single URL
            if urls.startswith("file://"):
                return [urls[7:]]  # Strip file:// prefix
        return []

    return []


def copy_text(text):
    """Copy text to clipboard."""
    pb = get_pasteboard()
    pb.clearContents()
    pb.setString_forType_(text, NSStringPboardType)
    return True


def copy_image(path):
    """
    Copy image file to clipboard.
    Returns: True on success, False on failure
    """
    if not os.path.exists(path):
        print(f"ERROR: File not found: {path}", file=sys.stderr)
        return False

    image = NSImage.alloc().initWithContentsOfFile_(path)
    if not image:
        print(f"ERROR: Could not load image: {path}", file=sys.stderr)
        return False

    pb = get_pasteboard()
    pb.clearContents()

    # Write as TIFF (universal format that macOS can convert)
    tiff_data = image.TIFFRepresentation()
    if tiff_data:
        pb.setData_forType_(tiff_data, NSTIFFPboardType)
        return True

    return False


def copy_file(path):
    """
    Copy file reference to clipboard (for Finder paste).
    Returns: True on success, False on failure
    """
    abs_path = os.path.abspath(path)
    if not os.path.exists(abs_path):
        print(f"ERROR: Path not found: {abs_path}", file=sys.stderr)
        return False

    pb = get_pasteboard()
    pb.clearContents()

    # Use file URL for modern macOS
    url = NSURL.fileURLWithPath_(abs_path)
    pb.writeObjects_(NSArray.arrayWithObject_(url))

    return True


def copy_files(paths):
    """
    Copy multiple file references to clipboard.
    Returns: True on success, False on failure
    """
    urls = []
    for path in paths:
        abs_path = os.path.abspath(path)
        if not os.path.exists(abs_path):
            print(f"ERROR: Path not found: {abs_path}", file=sys.stderr)
            return False
        urls.append(NSURL.fileURLWithPath_(abs_path))

    if not urls:
        return False

    pb = get_pasteboard()
    pb.clearContents()
    pb.writeObjects_(NSArray.arrayWithArray_(urls))

    return True


def main():
    parser = argparse.ArgumentParser(description="Clipboard operations")
    parser.add_argument("--type", action="store_true", help="Get clipboard type")
    parser.add_argument("--read-text", action="store_true", help="Read text from clipboard")
    parser.add_argument("--read-image", metavar="OUTPUT", help="Save clipboard image to file")
    parser.add_argument("--read-files", action="store_true", help="List files on clipboard")
    parser.add_argument("--copy-text", metavar="TEXT", help="Copy text to clipboard")
    parser.add_argument("--copy-image", metavar="PATH", help="Copy image to clipboard")
    parser.add_argument("--copy-file", metavar="PATH", help="Copy file to clipboard")
    parser.add_argument("--copy-files", metavar="PATH", nargs="+", help="Copy files to clipboard")

    args = parser.parse_args()

    if args.type:
        print(get_clipboard_type())

    elif args.read_text:
        print(read_text())

    elif args.read_image:
        if read_image(args.read_image):
            print(f"Saved to: {args.read_image}")
        else:
            print("ERROR: No image on clipboard", file=sys.stderr)
            sys.exit(1)

    elif args.read_files:
        files = read_files()
        for f in files:
            print(f)

    elif args.copy_text:
        if copy_text(args.copy_text):
            print("OK")
        else:
            sys.exit(1)

    elif args.copy_image:
        if copy_image(args.copy_image):
            print("OK")
        else:
            sys.exit(1)

    elif args.copy_file:
        if copy_file(args.copy_file):
            print("OK")
        else:
            sys.exit(1)

    elif args.copy_files:
        if copy_files(args.copy_files):
            print("OK")
        else:
            sys.exit(1)

    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
