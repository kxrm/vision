#!/usr/bin/env python3
"""
Firefox tab list and search utility.
Reads Firefox's session file to get all open tabs.
"""

import argparse
import json
import lz4.block
import os
import re
import sys
from pathlib import Path


def find_firefox_session():
    """Find the Firefox session recovery file."""
    firefox_dir = Path.home() / "Library" / "Application Support" / "Firefox" / "Profiles"

    if not firefox_dir.exists():
        return None

    # Find all profile directories and look for session files
    for profile_dir in firefox_dir.iterdir():
        if profile_dir.is_dir():
            session_file = profile_dir / "sessionstore-backups" / "recovery.jsonlz4"
            if session_file.exists():
                return session_file

    return None


def read_session_file(session_file):
    """Read and decompress Firefox session file."""
    with open(session_file, 'rb') as f:
        magic = f.read(8)
        if magic[:8] != b'mozLz40\0':
            raise ValueError(f"Invalid Firefox session file format")

        compressed = f.read()
        decompressed = lz4.block.decompress(compressed)
        return json.loads(decompressed)


def get_tabs(session_data):
    """Extract all tabs from session data."""
    tabs = []

    for wi, window in enumerate(session_data.get('windows', [])):
        for ti, tab in enumerate(window.get('tabs', [])):
            entries = tab.get('entries', [])
            current_idx = tab.get('index', 1) - 1

            if entries and 0 <= current_idx < len(entries):
                entry = entries[current_idx]
                tabs.append({
                    'window': wi + 1,
                    'index': ti + 1,
                    'title': entry.get('title', 'Untitled'),
                    'url': entry.get('url', ''),
                    'pinned': tab.get('pinned', False)
                })

    return tabs


def search_tabs(tabs, query):
    """Search tabs by title or URL."""
    query_lower = query.lower()

    # Common aliases for popular sites
    aliases = {
        'gmail': ['mail.google', 'inbox'],
        'gcal': ['calendar.google'],
        'gdocs': ['docs.google'],
        'gsheets': ['sheets.google'],
        'gdrive': ['drive.google'],
        'hn': ['news.ycombinator', 'hacker news'],
        'hackernews': ['news.ycombinator', 'hacker news'],
        'gh': ['github.com'],
        'gl': ['gitlab.com', 'gitlab.'],
        'yt': ['youtube.com'],
        'ddg': ['duckduckgo.com'],
    }

    # Build list of search terms (original + any aliases)
    search_terms = [query_lower]
    if query_lower in aliases:
        search_terms.extend(aliases[query_lower])

    results = []
    for tab in tabs:
        title_lower = tab['title'].lower()
        url_lower = tab['url'].lower()

        # Check for match in title or URL against any search term
        for term in search_terms:
            if term in title_lower or term in url_lower:
                results.append(tab)
                break  # Don't add same tab multiple times

    return results


def main():
    parser = argparse.ArgumentParser(description='List and search Firefox tabs')
    parser.add_argument('--search', '-s', help='Search for tabs matching query')
    parser.add_argument('--pinned', '-p', action='store_true', help='Show only pinned tabs')
    parser.add_argument('--json', '-j', action='store_true', help='Output as JSON')
    parser.add_argument('--index-only', '-i', action='store_true', help='Output only tab index (for first match)')
    parser.add_argument('--limit', '-l', type=int, default=0, help='Limit number of results')

    args = parser.parse_args()

    session_file = find_firefox_session()
    if not session_file:
        print("ERROR: Could not find Firefox session file", file=sys.stderr)
        sys.exit(1)

    try:
        session_data = read_session_file(session_file)
    except Exception as e:
        print(f"ERROR: Could not read session file: {e}", file=sys.stderr)
        sys.exit(1)

    tabs = get_tabs(session_data)

    # Filter pinned tabs if requested
    if args.pinned:
        tabs = [t for t in tabs if t['pinned']]

    # Search if query provided
    if args.search:
        tabs = search_tabs(tabs, args.search)

    # Limit results
    if args.limit > 0:
        tabs = tabs[:args.limit]

    # Output index only (for scripting)
    if args.index_only:
        if tabs:
            print(tabs[0]['index'])
        else:
            sys.exit(1)
        return

    # Output as JSON
    if args.json:
        print(json.dumps(tabs, indent=2))
        return

    # Pretty print
    if not tabs:
        print("No tabs found")
        return

    for tab in tabs:
        pinned = '📌 ' if tab['pinned'] else '   '
        idx = f"{tab['index']:3d}"
        title = tab['title'][:60]
        url = tab['url'][:70]
        print(f"{pinned}{idx}. {title}")
        print(f"       {url}")


if __name__ == '__main__':
    main()
