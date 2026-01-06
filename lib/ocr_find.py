#!/usr/bin/env python3
"""
OCR-based text finding using macOS Vision framework.
Application-agnostic - works with any app's UI.
Includes dark mode preprocessing for improved accuracy.
"""

import sys
import json
import re
import argparse
import tempfile
from pathlib import Path

import Quartz
from Foundation import NSURL
import objc
from PIL import Image, ImageOps, ImageStat

# Load the Vision framework
objc.loadBundle('Vision', globals(),
                bundle_path='/System/Library/Frameworks/Vision.framework')


# ============================================================================
# IMAGE PREPROCESSING FOR DARK MODE
# ============================================================================

def get_image_brightness(image_path):
    """
    Calculate average brightness of an image.
    Returns value 0-255 where lower = darker.
    """
    img = Image.open(image_path).convert('L')  # Convert to grayscale
    stat = ImageStat.Stat(img)
    return stat.mean[0]


def is_dark_mode_image(image_path, threshold=100):
    """
    Detect if image appears to be dark mode (dark background).
    threshold: brightness below this is considered dark (0-255)
    """
    brightness = get_image_brightness(image_path)
    return brightness < threshold


def preprocess_image_file(image_path, force_invert=False, auto_invert=True, scale_factor=1):
    """
    Preprocess image file for better OCR accuracy.
    Returns path to preprocessed image (may be same as input or temp file).

    Args:
        image_path: Path to the image file
        force_invert: Always invert regardless of brightness
        auto_invert: Automatically invert if dark mode detected
        scale_factor: Scale image by this factor (default 1, use 2 for small text)

    Returns:
        Path to preprocessed image
    """
    should_invert = force_invert or (auto_invert and is_dark_mode_image(image_path))
    should_scale = scale_factor > 1

    if not should_invert and not should_scale:
        return image_path

    # Load the image
    img = Image.open(image_path)

    # Convert to RGB if necessary (handles RGBA, etc.)
    if img.mode == 'RGBA':
        if should_invert:
            # Preserve alpha but invert RGB
            r, g, b, a = img.split()
            rgb = Image.merge('RGB', (r, g, b))
            rgb_inverted = ImageOps.invert(rgb)
            r2, g2, b2 = rgb_inverted.split()
            img = Image.merge('RGBA', (r2, g2, b2, a))
        # Convert to RGB for final output
        img = img.convert('RGB')
    elif img.mode != 'RGB':
        img = img.convert('RGB')
        if should_invert:
            img = ImageOps.invert(img)
    else:
        if should_invert:
            img = ImageOps.invert(img)

    # Scale image for better small text detection
    if should_scale:
        new_size = (int(img.width * scale_factor), int(img.height * scale_factor))
        img = img.resize(new_size, Image.LANCZOS)

    # Save to temp file as JPG (Vision OCR has issues with RGBA PNGs)
    temp_file = tempfile.NamedTemporaryFile(suffix='.jpg', delete=False)
    img.save(temp_file.name, 'JPEG', quality=95)
    return temp_file.name


def fuzzy_match(search_text, ocr_text, threshold=0.7):
    """
    Check if OCR text is a fuzzy match for search text.
    Handles common OCR errors like c→¢, s→8, missing chars, etc.

    Returns: (is_match, similarity_score)
    """
    search_lower = search_text.lower()
    ocr_lower = ocr_text.lower()

    # Word boundary match (preferred) - search text appears as complete word(s)
    # Use regex word boundaries to avoid matching "new" inside "News"
    word_pattern = r'(?:^|[\s\|\-\[\]\(\)])' + re.escape(search_lower) + r'(?:[\s\|\-\[\]\(\)\.,!?]|$)'
    if re.search(word_pattern, ocr_lower):
        return True, 1.0

    # Direct substring match - only for multi-word searches or longer terms
    # Short words (<=4 chars) should NOT match as substrings to avoid "new" in "News"
    if search_lower in ocr_lower and len(search_lower) > 4:
        return True, 0.9  # Slightly lower score than word boundary match

    # Space-normalized match - handles LLM searches like "412 comments"
    # matching OCR text "412comments" (no space in rendered UI)
    # Only for longer terms to avoid "new" matching "news"
    search_norm = re.sub(r'\s+', '', search_lower)
    ocr_norm = re.sub(r'\s+', '', ocr_lower)
    if search_norm in ocr_norm and len(search_norm) > 4:
        return True, 0.98  # High score - semantic match with whitespace difference

    # Check if OCR text is search text with 1-2 chars missing from start
    # e.g., "earch mail" matches "Search mail"
    for skip in range(1, 3):
        if skip < len(search_lower) and search_lower[skip:] == ocr_lower:
            score = len(ocr_lower) / len(search_lower)
            if score >= threshold:
                return True, score

    # Check if OCR text is search text with 1-2 chars missing from end
    for skip in range(1, 3):
        if skip < len(search_lower) and search_lower[:-skip] == ocr_lower:
            score = len(ocr_lower) / len(search_lower)
            if score >= threshold:
                return True, score

    # Check if search text is in OCR text with minor variations
    # Handle case where OCR added chars: "Searchx mail" contains "Search mail"
    if ocr_lower in search_lower:
        score = len(ocr_lower) / len(search_lower)
        if score >= threshold:
            return True, score

    # Sliding window fuzzy match - only for longer searches (>4 chars)
    # Short words like "new" would incorrectly match "news" with this approach
    search_len = len(search_lower)
    if search_len <= 4:
        return False, 0.0

    best_score = 0.0

    # Slide through OCR text looking for best match
    for start in range(max(1, len(ocr_lower) - search_len + 1)):
        end = start + search_len
        if end > len(ocr_lower):
            end = len(ocr_lower)

        substring = ocr_lower[start:end]

        # Count matching characters (allow for OCR substitutions)
        matches = 0
        for i, char in enumerate(search_lower):
            if i < len(substring):
                ocr_char = substring[i]
                # Direct match
                if char == ocr_char:
                    matches += 1
                # Common OCR substitutions
                elif (char == 'c' and ocr_char in '¢©') or \
                     (char == 's' and ocr_char in '8$5') or \
                     (char == 'i' and ocr_char in '1l!|') or \
                     (char == 'l' and ocr_char in '1i!|') or \
                     (char == 'o' and ocr_char in '0') or \
                     (char == '0' and ocr_char in 'o') or \
                     (char == 'e' and ocr_char in '€') or \
                     (char == 'a' and ocr_char in '@') or \
                     (char == 'b' and ocr_char in '6') or \
                     (char == 'g' and ocr_char in '9'):
                    matches += 0.8  # Partial credit for substitution

        score = matches / search_len
        if score > best_score:
            best_score = score

    return best_score >= threshold, best_score


def get_substring_bbox(candidate, search_text, full_text, case_sensitive=False, normalize_spaces=False):
    """
    Get the precise bounding box for a substring within detected text.

    Uses Vision's boundingBoxForRange:error: to get exact coordinates for
    the search text within the larger detected text block.

    Args:
        candidate: VNRecognizedText candidate object
        search_text: The text we're searching for
        full_text: The full detected text string
        case_sensitive: Whether to match case
        normalize_spaces: If True, try matching with spaces removed (for "412 comments" vs "412comments")

    Returns:
        VNRectangleObservation for the substring, or None if not found
    """
    from Foundation import NSRange

    search = search_text if case_sensitive else search_text.lower()
    text = full_text if case_sensitive else full_text.lower()

    # Find the search text position in full text
    idx = text.find(search)
    match_len = len(search_text)

    # If not found and normalize_spaces enabled, try space-normalized matching
    if idx == -1 and normalize_spaces:
        search_norm = re.sub(r'\s+', '', search)
        text_norm = re.sub(r'\s+', '', text)
        norm_idx = text_norm.find(search_norm)

        if norm_idx >= 0:
            # Map normalized index back to original text position
            # Count non-space chars in original until we reach norm_idx
            orig_idx = 0
            norm_count = 0
            for i, c in enumerate(text):
                if c not in ' \t\n':
                    if norm_count == norm_idx:
                        orig_idx = i
                        break
                    norm_count += 1

            # Find the length in original text that covers the normalized match
            chars_needed = len(search_norm)
            chars_found = 0
            orig_end = orig_idx
            for i in range(orig_idx, len(text)):
                if text[i] not in ' \t\n':
                    chars_found += 1
                if chars_found == chars_needed:
                    orig_end = i + 1
                    break

            idx = orig_idx
            match_len = orig_end - orig_idx

    if idx == -1:
        return None

    # Create NSRange for the substring
    text_range = NSRange(idx, match_len)

    # Get bounding box for this specific range
    # boundingBoxForRange:error: returns a VNRectangleObservation
    try:
        bbox_observation = candidate.boundingBoxForRange_error_(text_range, None)
        if bbox_observation:
            return bbox_observation
    except Exception:
        pass

    return None


def find_text_in_image(image_path, search_text, case_sensitive=False, return_all=False,
                       preprocess=True, fuzzy=True, fuzzy_threshold=0.7,
                       scale_factor=1, retry_with_scale=True):
    """
    Find text in an image using macOS Vision OCR.

    Args:
        image_path: Path to the image file
        search_text: Text to search for (partial match supported)
        case_sensitive: Whether to match case
        return_all: Return all matches instead of just the best one
        preprocess: Auto-invert dark mode images for better OCR
        fuzzy: Enable fuzzy matching for OCR errors (default True)
        fuzzy_threshold: Minimum similarity for fuzzy match (0.0-1.0, default 0.7)
        scale_factor: Scale image by this factor (default 1, use 2 for small text)
        retry_with_scale: If text not found at scale_factor=1, retry at 2x (default True)

    Returns:
        List of dicts with: text, confidence, bounds (x, y, width, height as percentages)
    """
    # For short search terms (<=4 chars), use 2x scale by default
    # These are often small UI elements (nav links, buttons) that Vision misses at 1x
    if len(search_text) <= 4 and scale_factor == 1:
        scale_factor = 2

    # Apply preprocessing for dark mode if enabled
    actual_path = str(image_path)
    if preprocess:
        actual_path = preprocess_image_file(image_path, auto_invert=True, scale_factor=scale_factor)

    # Load image
    image_url = NSURL.fileURLWithPath_(actual_path)

    # Create image source
    image_source = Quartz.CGImageSourceCreateWithURL(image_url, None)
    if not image_source:
        raise ValueError(f"Could not load image: {image_path}")

    # Get CGImage
    cg_image = Quartz.CGImageSourceCreateImageAtIndex(image_source, 0, None)
    if not cg_image:
        raise ValueError(f"Could not create image from: {image_path}")

    # Get image dimensions
    img_width = Quartz.CGImageGetWidth(cg_image)
    img_height = Quartz.CGImageGetHeight(cg_image)

    # Create Vision request handler
    request_handler = VNImageRequestHandler.alloc().initWithCGImage_options_(
        cg_image, None
    )

    # Create text recognition request
    request = VNRecognizeTextRequest.alloc().init()
    # VNRequestTextRecognitionLevelAccurate = 1, VNRequestTextRecognitionLevelFast = 0
    request.setRecognitionLevel_(1)
    request.setUsesLanguageCorrection_(True)

    # Perform OCR
    success = request_handler.performRequests_error_([request], None)
    if not success:
        raise RuntimeError("OCR failed")

    # Process results
    results = request.results()
    matches = []

    search_lower = search_text.lower() if not case_sensitive else search_text

    for observation in results:
        # Get the top candidate
        candidates = observation.topCandidates_(1)
        if not candidates:
            continue

        candidate = candidates[0]
        text = candidate.string()
        confidence = candidate.confidence()

        # Check if this text matches our search
        text_to_match = text if case_sensitive else text.lower()

        # Use fuzzy_match which handles word boundaries and substring matching
        # This avoids matching "new" inside "News"
        if fuzzy:
            is_match, match_score = fuzzy_match(search_text, text, fuzzy_threshold)
        else:
            # Non-fuzzy: exact substring match only
            is_match = search_lower in text_to_match
            match_score = 1.0 if is_match else 0.0

        if is_match:
            # Try to get precise bounding box for the search text substring
            # This is crucial for clicking on specific words within a text block
            substring_bbox = None
            if search_lower in text_to_match:
                substring_bbox = get_substring_bbox(candidate, search_text, text, case_sensitive)
            else:
                # Try space-normalized matching for bbox
                substring_bbox = get_substring_bbox(candidate, search_text, text, case_sensitive, normalize_spaces=True)

            if substring_bbox:
                # Use the precise substring bounding box
                # VNRectangleObservation has boundingBox property
                bbox = substring_bbox.boundingBox()
            else:
                # Fall back to full observation bounding box
                bbox = observation.boundingBox()

            # Convert to top-left origin percentages
            # Vision uses bottom-left origin with normalized 0-1 coordinates
            x_pct = bbox.origin.x * 100
            y_pct = (1 - bbox.origin.y - bbox.size.height) * 100  # Flip Y
            w_pct = bbox.size.width * 100
            h_pct = bbox.size.height * 100

            # Calculate center point of the (possibly substring) bounding box
            center_x_pct = x_pct + w_pct / 2
            center_y_pct = y_pct + h_pct / 2

            # Calculate pixel coordinates
            center_x_px = int(center_x_pct * img_width / 100)
            center_y_px = int(center_y_pct * img_height / 100)

            matches.append({
                'text': text,
                'search_match': search_text,
                'confidence': confidence,
                'match_score': round(match_score, 3),
                'substring_bbox': substring_bbox is not None,  # Flag if we used precise coords
                'bounds_pct': {
                    'x': round(x_pct, 2),
                    'y': round(y_pct, 2),
                    'width': round(w_pct, 2),
                    'height': round(h_pct, 2)
                },
                'center_pct': {
                    'x': round(center_x_pct, 2),
                    'y': round(center_y_pct, 2)
                },
                'center_px': {
                    'x': center_x_px,
                    'y': center_y_px
                },
                'image_size': {
                    'width': img_width,
                    'height': img_height
                }
            })

    # Sort by confidence (highest first)
    matches.sort(key=lambda m: m['confidence'], reverse=True)

    # For exact matches, prioritize those over partial matches
    exact_matches = [m for m in matches if m['text'].lower() == search_lower or
                    search_lower == m['text'].lower()]
    if exact_matches and not return_all:
        return exact_matches[:1]

    if return_all:
        # If no matches and retry enabled, try at 2x scale
        if not matches and retry_with_scale and scale_factor == 1:
            return find_text_in_image(
                image_path, search_text,
                case_sensitive=case_sensitive,
                return_all=True,
                preprocess=preprocess,
                fuzzy=fuzzy,
                fuzzy_threshold=fuzzy_threshold,
                scale_factor=2,
                retry_with_scale=False
            )
        return matches

    if matches:
        return matches[:1]

    # If no matches found and retry_with_scale enabled, try at 2x scale
    # This helps detect small text that Vision misses at 1x
    if retry_with_scale and scale_factor == 1:
        return find_text_in_image(
            image_path, search_text,
            case_sensitive=case_sensitive,
            return_all=return_all,
            preprocess=preprocess,
            fuzzy=fuzzy,
            fuzzy_threshold=fuzzy_threshold,
            scale_factor=2,
            retry_with_scale=False  # Don't retry again
        )

    return []


def get_all_text(image_path, preprocess=True):
    """Get all text found in image with their positions."""
    # Apply preprocessing for dark mode if enabled
    actual_path = str(image_path)
    if preprocess:
        actual_path = preprocess_image_file(image_path, auto_invert=True)

    image_url = NSURL.fileURLWithPath_(actual_path)
    image_source = Quartz.CGImageSourceCreateWithURL(image_url, None)
    if not image_source:
        raise ValueError(f"Could not load image: {image_path}")

    cg_image = Quartz.CGImageSourceCreateImageAtIndex(image_source, 0, None)
    if not cg_image:
        raise ValueError(f"Could not create image from: {image_path}")

    img_width = Quartz.CGImageGetWidth(cg_image)
    img_height = Quartz.CGImageGetHeight(cg_image)

    request_handler = VNImageRequestHandler.alloc().initWithCGImage_options_(
        cg_image, None
    )

    request = VNRecognizeTextRequest.alloc().init()
    # VNRequestTextRecognitionLevelAccurate = 1
    request.setRecognitionLevel_(1)
    request.setUsesLanguageCorrection_(True)

    success = request_handler.performRequests_error_([request], None)
    if not success:
        raise RuntimeError("OCR failed")

    results = []
    for observation in request.results():
        candidates = observation.topCandidates_(1)
        if not candidates:
            continue

        candidate = candidates[0]
        bbox = observation.boundingBox()

        # Convert coordinates (Vision uses bottom-left origin, we want top-left)
        x_pct = bbox.origin.x * 100
        y_pct = (1 - bbox.origin.y - bbox.size.height) * 100
        w_pct = bbox.size.width * 100
        h_pct = bbox.size.height * 100
        center_x_pct = x_pct + w_pct / 2
        center_y_pct = y_pct + h_pct / 2

        results.append({
            'text': candidate.string(),
            'confidence': round(candidate.confidence(), 3),
            'bounds_pct': {
                'x': round(x_pct, 2),
                'y': round(y_pct, 2),
                'width': round(w_pct, 2),
                'height': round(h_pct, 2)
            },
            'center_pct': {
                'x': round(center_x_pct, 2),
                'y': round(center_y_pct, 2)
            }
        })

    # Sort by Y position (top to bottom), then X (left to right)
    results.sort(key=lambda r: (r['center_pct']['y'], r['center_pct']['x']))
    return results


def find_nearest_to_anchor(image_path, search_text, anchor_text, case_sensitive=False,
                           preprocess=True, fuzzy=True, fuzzy_threshold=0.7):
    """
    Find the match of search_text that is closest to anchor_text.

    This enables one-shot clicking on repeated elements by specifying context.
    E.g., click "48 comments" near "Pure Silicon" on Hacker News.

    Args:
        image_path: Path to the image file
        search_text: Text to search for (e.g., "48 comments")
        anchor_text: Reference text to find nearest match to (e.g., "Pure Silicon")
        case_sensitive: Whether to match case
        preprocess: Auto-invert dark mode images
        fuzzy: Enable fuzzy matching
        fuzzy_threshold: Minimum similarity for fuzzy match

    Returns:
        Single match dict (closest to anchor), or None if not found
    """
    import math

    # Get all matches for search text
    search_matches = find_text_in_image(
        image_path, search_text, case_sensitive=case_sensitive,
        return_all=True, preprocess=preprocess, fuzzy=fuzzy,
        fuzzy_threshold=fuzzy_threshold
    )

    if not search_matches:
        return None

    # Get anchor position
    anchor_matches = find_text_in_image(
        image_path, anchor_text, case_sensitive=case_sensitive,
        return_all=False, preprocess=preprocess, fuzzy=fuzzy,
        fuzzy_threshold=fuzzy_threshold
    )

    if not anchor_matches:
        return None

    anchor = anchor_matches[0]
    anchor_x = anchor['center_pct']['x']
    anchor_y = anchor['center_pct']['y']

    # Find closest match to anchor
    closest = None
    min_distance = float('inf')

    for match in search_matches:
        dx = match['center_pct']['x'] - anchor_x
        dy = match['center_pct']['y'] - anchor_y
        distance = math.sqrt(dx**2 + dy**2)

        if distance < min_distance:
            min_distance = distance
            closest = match

    if closest:
        closest['distance_to_anchor'] = round(min_distance, 2)
        closest['anchor_text'] = anchor_text

    return closest


def main():
    parser = argparse.ArgumentParser(description='Find text in images using OCR')
    parser.add_argument('image', help='Path to image file')
    parser.add_argument('--find', '-f', help='Text to search for')
    parser.add_argument('--near', '-n', help='Find match closest to this anchor text (recommended)')
    parser.add_argument('--all', '-a', action='store_true',
                        help='Return all matches (not just best)')
    parser.add_argument('--list', '-l', action='store_true',
                        help='List all text found in image')
    parser.add_argument('--case-sensitive', '-c', action='store_true',
                        help='Case-sensitive search')
    parser.add_argument('--json', '-j', action='store_true',
                        help='Output as JSON')
    parser.add_argument('--instance', '-i', type=int, default=1,
                        help='Which instance to return (fallback, less reliable than --near)')
    parser.add_argument('--no-preprocess', action='store_true',
                        help='Disable dark mode preprocessing (auto-invert)')
    parser.add_argument('--no-fuzzy', action='store_true',
                        help='Disable fuzzy matching for OCR errors')
    parser.add_argument('--fuzzy-threshold', type=float, default=0.7,
                        help='Minimum similarity for fuzzy match (0.0-1.0, default 0.7)')

    args = parser.parse_args()
    preprocess = not args.no_preprocess
    fuzzy = not args.no_fuzzy

    if not Path(args.image).exists():
        print(f"ERROR: Image not found: {args.image}", file=sys.stderr)
        sys.exit(1)

    try:
        if args.list:
            # List all text
            results = get_all_text(args.image, preprocess=preprocess)
            if args.json:
                print(json.dumps(results, indent=2))
            else:
                for r in results:
                    b = r['bounds_pct']
                    print(f"[{b['x']:5.1f},{b['y']:5.1f},{b['width']:5.1f},{b['height']:4.1f}]  "
                          f"[{r['confidence']:.2f}]  {r['text']}")

        elif args.find:
            # Find specific text
            if args.near:
                # Proximity-based search: find match closest to anchor text
                # Disable fuzzy matching by default when using --near to avoid false positives
                # (e.g., "48 comments" matching "79 comments" when fuzzy is on)
                match = find_nearest_to_anchor(
                    args.image,
                    args.find,
                    args.near,
                    case_sensitive=args.case_sensitive,
                    preprocess=preprocess,
                    fuzzy=False,  # Exact matching for --near
                    fuzzy_threshold=args.fuzzy_threshold
                )

                if not match:
                    print(f"NOT_FOUND: '{args.find}' near '{args.near}'", file=sys.stderr)
                    sys.exit(1)

                if args.json:
                    print(json.dumps(match, indent=2))
                else:
                    b = match['bounds_pct']
                    print(f"FOUND: '{match['text']}' (near '{args.near}')")
                    print(f"GRID: {b['x']},{b['y']},{b['width']},{b['height']}")
                    print(f"PIXEL: {match['center_px']['x']},{match['center_px']['y']}")
                    print(f"CONFIDENCE: {match['confidence']:.3f}")
                    print(f"DISTANCE: {match.get('distance_to_anchor', 'N/A')}")
            else:
                # Standard search (with optional --instance fallback)
                matches = find_text_in_image(
                    args.image,
                    args.find,
                    case_sensitive=args.case_sensitive,
                    return_all=args.all,
                    preprocess=preprocess,
                    fuzzy=fuzzy,
                    fuzzy_threshold=args.fuzzy_threshold
                )

                if not matches:
                    print(f"NOT_FOUND: '{args.find}'", file=sys.stderr)
                    sys.exit(1)

                # Select instance
                if args.instance > len(matches):
                    print(f"ERROR: Only {len(matches)} matches found, requested instance {args.instance}",
                          file=sys.stderr)
                    sys.exit(1)

                if args.json:
                    if args.all:
                        print(json.dumps(matches, indent=2))
                    else:
                        print(json.dumps(matches[args.instance - 1], indent=2))
                else:
                    match = matches[args.instance - 1]
                    b = match['bounds_pct']
                    # Output format suitable for shell parsing
                    print(f"FOUND: '{match['text']}'")
                    print(f"GRID: {b['x']},{b['y']},{b['width']},{b['height']}")
                    print(f"PIXEL: {match['center_px']['x']},{match['center_px']['y']}")
                    print(f"CONFIDENCE: {match['confidence']:.3f}")

                    if args.all and len(matches) > 1:
                        print(f"\nAll {len(matches)} matches:")
                        for i, m in enumerate(matches, 1):
                            mb = m['bounds_pct']
                            print(f"  {i}. '{m['text']}' at [{mb['x']:.1f},{mb['y']:.1f},{mb['width']:.1f},{mb['height']:.1f}]")

        else:
            parser.print_help()
            sys.exit(1)

    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
