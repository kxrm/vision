#!/usr/bin/env python3
"""
Smart image resizing for Claude API compatibility.

Resizes images to max 1568px on longest dimension while preserving aspect ratio.
This matches Claude's internal processing limit - no quality loss at this size.

Anthropic API limits:
- Single image: up to 8000x8000 px
- 20+ images in conversation: limited to 2000x2000 px
- Claude internally downscales >1568px anyway
"""

import sys
from pathlib import Path
from PIL import Image

# Claude's internal processing limit - no quality loss at this size
MAX_DIMENSION = 1568
JPEG_QUALITY = 90


def resize_for_claude(image_path: str, max_dim: int = MAX_DIMENSION,
                      quality: int = JPEG_QUALITY) -> str:
    """
    Resize image if needed for Claude API compatibility.

    Args:
        image_path: Path to source image
        max_dim: Maximum dimension (width or height), default 1568px
        quality: JPEG quality (default 90 for text clarity)

    Returns:
        Path to the image (same path if resized in-place, or original if no resize needed)
    """
    path = Path(image_path)
    if not path.exists():
        return image_path

    img = Image.open(image_path)
    width, height = img.size

    # Skip resize if already under limit
    if max(width, height) <= max_dim:
        img.close()
        return image_path

    # Calculate new dimensions preserving aspect ratio
    if width > height:
        new_width = max_dim
        new_height = int(height * max_dim / width)
    else:
        new_height = max_dim
        new_width = int(width * max_dim / height)

    # Resize using high-quality LANCZOS resampling
    resized = img.resize((new_width, new_height), Image.LANCZOS)

    # Convert RGBA to RGB for JPEG
    if resized.mode == 'RGBA':
        background = Image.new('RGB', resized.size, (255, 255, 255))
        background.paste(resized, mask=resized.split()[3])
        resized = background
    elif resized.mode != 'RGB':
        resized = resized.convert('RGB')

    # Save in-place (all our images are in /tmp)
    output_path = str(path)
    resized.save(output_path, 'JPEG', quality=quality)
    img.close()

    return output_path


def needs_resize(image_path: str, max_dim: int = MAX_DIMENSION) -> bool:
    """Check if image exceeds the maximum dimension threshold."""
    try:
        img = Image.open(image_path)
        width, height = img.size
        img.close()
        return max(width, height) > max_dim
    except Exception:
        return False


def get_dimensions(image_path: str) -> tuple:
    """Get image dimensions as (width, height)."""
    try:
        img = Image.open(image_path)
        dims = img.size
        img.close()
        return dims
    except Exception:
        return (0, 0)


if __name__ == '__main__':
    # CLI: resize image and print path
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <image_path> [max_dimension]", file=sys.stderr)
        sys.exit(1)

    image_path = sys.argv[1]
    max_dim = int(sys.argv[2]) if len(sys.argv) > 2 else MAX_DIMENSION

    if not Path(image_path).exists():
        print(f"ERROR: File not found: {image_path}", file=sys.stderr)
        sys.exit(1)

    # Get original dimensions for reporting
    orig_w, orig_h = get_dimensions(image_path)

    result = resize_for_claude(image_path, max_dim)

    # Get new dimensions
    new_w, new_h = get_dimensions(result)

    if (orig_w, orig_h) != (new_w, new_h):
        print(f"Resized: {orig_w}x{orig_h} -> {new_w}x{new_h}", file=sys.stderr)

    print(result)
