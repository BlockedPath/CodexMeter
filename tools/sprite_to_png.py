#!/usr/bin/env python3
"""Extract PNG frames from a firmware sprite header (RGB565 + alpha planar).

Usage:
  python tools/sprite_to_png.py firmware/src/sukuna_sprite.h --state idle --out ios/.../Assets.xcassets/PetSprite.imageset/
"""

from __future__ import annotations

import argparse
import math
import re
import struct
import sys
from pathlib import Path
from PIL import Image


def rgb565_to_rgb(val: int) -> tuple[int, int, int]:
    r5 = (val >> 11) & 0x1F
    g6 = (val >> 5) & 0x3F
    b5 = val & 0x1F
    r = (r5 * 255 + 15) // 31
    g = (g6 * 255 + 31) // 63
    b = (b5 * 255 + 15) // 31
    return (r, g, b)


def parse_header(path: Path) -> dict:
    """Parse a sprite C header and return structured data."""
    text = path.read_text()

    # Extract defines (match any uppercase prefix, not just PET_)
    defines = {}
    for m in re.finditer(r"#define\s+(\w+)\s+(.+)", text):
        name = m.group(1)
        value = m.group(2).strip()
        # Remove comments
        value = re.sub(r"\s*//.*$", "", value)
        try:
            defines[name] = int(value)
        except ValueError:
            defines[name] = value

    # Determine prefix — look for defines ending in _W (width)
    prefixes = [k[:-2] for k in defines if k.endswith("_W")]
    if not prefixes:
        raise SystemExit("Could not determine pet prefix from _W defines")
    prefix = prefixes[0]

    w = defines[f"{prefix}_W"]
    h = defines[f"{prefix}_H"]
    frames = defines[f"{prefix}_FRAMES"]
    state_count = defines[f"{prefix}_STATE_COUNT"]
    pixels = defines[f"{prefix}_PIXELS"]

    # Extract state labels
    state_labels = []
    label_match = re.search(
        r'static const char\* const \w+_state_label\[\w+\]\s*=\s*\{(.+?)\};',
        text,
        re.DOTALL,
    )
    if label_match:
        labels_str = label_match.group(1)
        state_labels = [
            lbl.strip().strip('"') for lbl in labels_str.split(",")
        ]

    # Extract state offsets
    offset_match = re.search(
        r"static const uint16_t (\w+_state_offset)\[",
        text,
    )
    offset_name = offset_match.group(1) if offset_match else f"{prefix.lower()}_state_offset"

    # Extract state counts
    count_match = re.search(
        r"static const uint8_t (\w+_state_count)\[",
        text,
    )
    count_name = count_match.group(1) if count_match else f"{prefix.lower()}_state_count"

    # Extract frame ms
    ms_match = re.search(
        r"static const uint16_t (\w+_frame_ms)\[",
        text,
    )
    ms_name = ms_match.group(1) if ms_match else f"{prefix.lower()}_frame_ms"

    # Parse C arrays using regex
    def parse_uint16_array(name: str) -> list[int]:
        pattern = rf"static const uint16_t {re.escape(name)}\[\w+\]\s*=\s*\{{(.+?)\}};"
        m = re.search(pattern, text, re.DOTALL)
        if not m:
            raise SystemExit(f"Could not find array: {name}")
        return [int(x.strip(), 0) for x in m.group(1).split(",") if x.strip()]

    def parse_uint8_array(name: str) -> list[int]:
        pattern = rf"static const uint8_t {re.escape(name)}\[\w+\]\s*=\s*\{{(.+?)\}};"
        m = re.search(pattern, text, re.DOTALL)
        if not m:
            raise SystemExit(f"Could not find array: {name}")
        return [int(x.strip(), 0) for x in m.group(1).split(",") if x.strip()]

    state_offsets = parse_uint16_array(offset_name)
    state_counts = parse_uint8_array(count_name)
    frame_ms = parse_uint16_array(ms_name)

    # Extract RGB565 frame data (PROGMEM 2D array)
    rgb565_match = re.search(
        rf"static const uint16_t (\w+_rgb565)\[\w+\]\[",
        text,
    )
    if not rgb565_match:
        raise SystemExit("Could not find RGB565 array")
    rgb565_name = rgb565_match.group(1)

    # Extract alpha frame data
    alpha_match = re.search(
        rf"static const uint8_t (\w+_alpha)\[\w+\]\[",
        text,
    )
    if not alpha_match:
        raise SystemExit("Could not find alpha array")
    alpha_name = alpha_match.group(1)

    # Parse 2D arrays - find the opening braces and parse frame by frame
    def parse_2d_uint16_array(name: str, num_frames: int, num_pixels: int) -> list[list[int]]:
        # Find the array start (dimensions may use macros like PET_SUKUNA_FRAMES)
        pattern = rf"static const uint16_t {re.escape(name)}\[\w+\]\[\w+\]\s*PROGMEM\s*=\s*\{{"
        m = re.search(pattern, text)
        if not m:
            # Try without PROGMEM
            pattern = rf"static const uint16_t {re.escape(name)}\[\w+\]\[\w+\]\s*=\s*\{{"
            m = re.search(pattern, text)
        if not m:
            raise SystemExit(f"Could not find 2D array start: {name}")

        # Extract the content between outer braces
        pos = m.end() - 1  # at the opening {
        depth = 0
        start = pos
        while pos < len(text):
            if text[pos] == "{":
                depth += 1
            elif text[pos] == "}":
                depth -= 1
                if depth == 0:
                    content = text[start + 1 : pos]
                    break
            pos += 1
        else:
            raise SystemExit(f"Unmatched braces in {name}")

        # Now split into frames (each frame is within {})
        frames_data = []
        frame_depth = 0
        frame_start = -1
        for i, ch in enumerate(content):
            if ch == "{":
                if frame_depth == 0:
                    frame_start = i + 1
                frame_depth += 1
            elif ch == "}":
                frame_depth -= 1
                if frame_depth == 0:
                    frame_content = content[frame_start:i]
                    values = [
                        int(x.strip(), 0)
                        for x in frame_content.split(",")
                        if x.strip()
                    ]
                    frames_data.append(values)

        if len(frames_data) != num_frames:
            print(
                f"Warning: expected {num_frames} frames, got {len(frames_data)}",
                file=sys.stderr,
            )
        return frames_data

    def parse_2d_uint8_array(name: str, num_frames: int, num_pixels: int) -> list[list[int]]:
        pattern = rf"static const uint8_t {re.escape(name)}\[\w+\]\[\w+\]\s*PROGMEM\s*=\s*\{{"
        m = re.search(pattern, text)
        if not m:
            pattern = rf"static const uint8_t {re.escape(name)}\[\w+\]\[\w+\]\s*=\s*\{{"
            m = re.search(pattern, text)
        if not m:
            raise SystemExit(f"Could not find 2D array start: {name}")

        pos = m.end() - 1
        depth = 0
        start = pos
        while pos < len(text):
            if text[pos] == "{":
                depth += 1
            elif text[pos] == "}":
                depth -= 1
                if depth == 0:
                    content = text[start + 1 : pos]
                    break
            pos += 1
        else:
            raise SystemExit(f"Unmatched braces in {name}")

        frames_data = []
        frame_depth = 0
        frame_start = -1
        for i, ch in enumerate(content):
            if ch == "{":
                if frame_depth == 0:
                    frame_start = i + 1
                frame_depth += 1
            elif ch == "}":
                frame_depth -= 1
                if frame_depth == 0:
                    frame_content = content[frame_start:i]
                    values = [
                        int(x.strip(), 0)
                        for x in frame_content.split(",")
                        if x.strip()
                    ]
                    frames_data.append(values)

        if len(frames_data) != num_frames:
            print(
                f"Warning: expected {num_frames} frames, got {len(frames_data)}",
                file=sys.stderr,
            )
        return frames_data

    rgb565_frames = parse_2d_uint16_array(rgb565_name, frames, pixels)
    alpha_frames = parse_2d_uint8_array(alpha_name, frames, pixels)

    return {
        "prefix": prefix,
        "name": prefix.replace("PET_", "").replace("_", " ").title(),
        "w": w,
        "h": h,
        "frames": frames,
        "state_count": state_count,
        "pixels": pixels,
        "state_labels": state_labels,
        "state_offsets": state_offsets,
        "state_counts": state_counts,
        "frame_ms": frame_ms,
        "rgb565_frames": rgb565_frames,
        "alpha_frames": alpha_frames,
    }


def frame_to_image(
    rgb565_data: list[int],
    alpha_data: list[int],
    w: int,
    h: int,
) -> Image.Image:
    """Convert a single frame's RGB565 + alpha to a PIL RGBA image."""
    img = Image.new("RGBA", (w, h))
    pixels = img.load()
    for y in range(h):
        for x in range(w):
            idx = y * w + x
            color = rgb565_data[idx]
            alpha = alpha_data[idx]
            r, g, b = rgb565_to_rgb(color)
            pixels[x, y] = (r, g, b, alpha)
    return img


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Convert firmware sprite header to PNG frames",
    )
    parser.add_argument("header", type=Path, help="Path to the sprite .h file")
    parser.add_argument(
        "--state",
        type=str,
        help="Animation state to extract (e.g., idle, waving). Default: all states",
    )
    parser.add_argument(
        "--out",
        type=Path,
        required=True,
        help="Output directory for PNG frames",
    )
    parser.add_argument(
        "--scale",
        type=int,
        default=1,
        help="Integer scale factor (default: 1, use 2 for 2x retina)",
    )
    args = parser.parse_args()

    data = parse_header(args.header)
    out = args.out
    out.mkdir(parents=True, exist_ok=True)

    # Determine which frames to export
    if args.state:
        try:
            state_idx = data["state_labels"].index(args.state)
        except ValueError:
            print(
                f"State '{args.state}' not found. Available: {data['state_labels']}",
                file=sys.stderr,
            )
            sys.exit(1)
        offset = data["state_offsets"][state_idx]
        count = data["state_counts"][state_idx]
        frame_indices = list(range(offset, offset + count))
        prefix = f"{args.state}_"
    else:
        frame_indices = list(range(data["frames"]))
        prefix = ""

    print(f"Pet: {data['name']}")
    print(f"Dimensions: {data['w']}x{data['h']}")
    print(f"State: {args.state or 'all'}")
    print(f"Frames: {len(frame_indices)}")

    for i, fi in enumerate(frame_indices):
        rgb = data["rgb565_frames"][fi]
        alpha = data["alpha_frames"][fi]
        img = frame_to_image(rgb, alpha, data["w"], data["h"])

        if args.scale > 1:
            new_w = data["w"] * args.scale
            new_h = data["h"] * args.scale
            img = img.resize((new_w, new_h), Image.NEAREST)

        fname = out / f"{prefix}frame_{i:02d}.png"
        img.save(fname)
        print(f"  Wrote {fname}")

    # Write Contents.json for Xcode asset catalog
    contents = {
        "images": [
            {
                "filename": f"{prefix}frame_{i:02d}.png",
                "idiom": "universal",
            }
            for i in range(len(frame_indices))
        ],
        "info": {
            "author": "xcode",
            "version": 1,
        },
        "properties": {
            "template-rendering-intent": "original",
        },
    }

    import json

    contents_path = out / "Contents.json"
    contents_path.write_text(json.dumps(contents, indent=2))
    print(f"  Wrote {contents_path}")


if __name__ == "__main__":
    main()
