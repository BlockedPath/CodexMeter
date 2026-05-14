#!/usr/bin/env python3
"""Convert a Codex pet atlas into firmware-friendly firmware frame data.

The Codex pet package stores an 8x9 WebP atlas at 192x208 per cell. This tool
extracts one row and writes planar RGB565A8 C data: all RGB565 bytes for a
frame, followed by that frame's alpha bytes.
"""

from __future__ import annotations

import argparse
import binascii
import json
import os
import re
import struct
import subprocess
import tempfile
import zlib
from pathlib import Path


ATLAS_COLUMNS = 8
ATLAS_ROWS = 9
CELL_W = 192
CELL_H = 208

ROW_SPECS = {
    "idle": (0, 6),
    "running-right": (1, 8),
    "running-left": (2, 8),
    "waving": (3, 4),
    "jumping": (4, 5),
    "failed": (5, 8),
    "waiting": (6, 6),
    "running": (7, 6),
    "review": (8, 6),
}

DEFAULT_FRAME_MS = {
    "idle": [260, 260, 260, 260, 260, 360],
    "running-right": [120] * 8,
    "running-left": [120] * 8,
    "waving": [220] * 4,
    "jumping": [180] * 5,
    "failed": [180] * 8,
    "waiting": [260, 260, 260, 260, 260, 360],
    "running": [120] * 6,
    "review": [260, 260, 260, 260, 260, 360],
}


def ident(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", value.lower()).strip("_")


def rgb565(r: int, g: int, b: int) -> int:
    return ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)


def convert_to_png(source: Path) -> bytes:
    if source.suffix.lower() == ".png":
        return source.read_bytes()

    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "atlas.png"
        subprocess.run(
            ["sips", "-s", "format", "png", str(source), "--out", str(out)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return out.read_bytes()


def paeth(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def read_png_rgba(data: bytes) -> tuple[int, int, bytearray]:
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit("input did not decode to PNG")

    pos = 8
    width = height = None
    color_type = None
    bit_depth = None
    interlace = None
    compressed = bytearray()

    while pos < len(data):
        length = struct.unpack(">I", data[pos : pos + 4])[0]
        ctype = data[pos + 4 : pos + 8]
        chunk = data[pos + 8 : pos + 8 + length]
        crc = struct.unpack(">I", data[pos + 8 + length : pos + 12 + length])[0]
        actual_crc = binascii.crc32(ctype)
        actual_crc = binascii.crc32(chunk, actual_crc) & 0xFFFFFFFF
        if crc != actual_crc:
            raise SystemExit(f"PNG CRC mismatch in {ctype.decode('ascii', 'replace')}")

        if ctype == b"IHDR":
            width, height, bit_depth, color_type, _compression, _filter, interlace = struct.unpack(
                ">IIBBBBB", chunk
            )
        elif ctype == b"IDAT":
            compressed.extend(chunk)
        elif ctype == b"IEND":
            break
        pos += 12 + length

    if width is None or height is None:
        raise SystemExit("PNG missing IHDR")
    if bit_depth != 8 or color_type != 6 or interlace != 0:
        raise SystemExit("expected non-interlaced 8-bit RGBA PNG")

    raw = zlib.decompress(bytes(compressed))
    bpp = 4
    stride = width * bpp
    expected = (stride + 1) * height
    if len(raw) != expected:
        raise SystemExit(f"unexpected PNG payload length {len(raw)} != {expected}")

    out = bytearray(width * height * bpp)
    src = 0
    prev = bytearray(stride)
    for y in range(height):
        filt = raw[src]
        src += 1
        scan = bytearray(raw[src : src + stride])
        src += stride
        recon = bytearray(stride)
        for x in range(stride):
            left = recon[x - bpp] if x >= bpp else 0
            up = prev[x]
            up_left = prev[x - bpp] if x >= bpp else 0
            value = scan[x]
            if filt == 0:
                recon[x] = value
            elif filt == 1:
                recon[x] = (value + left) & 0xFF
            elif filt == 2:
                recon[x] = (value + up) & 0xFF
            elif filt == 3:
                recon[x] = (value + ((left + up) >> 1)) & 0xFF
            elif filt == 4:
                recon[x] = (value + paeth(left, up, up_left)) & 0xFF
            else:
                raise SystemExit(f"unsupported PNG filter {filt}")
        out[y * stride : (y + 1) * stride] = recon
        prev = recon

    return width, height, out


def pixel_at(rgba: bytearray, image_w: int, x: int, y: int) -> tuple[int, int, int, int]:
    idx = (y * image_w + x) * 4
    return rgba[idx], rgba[idx + 1], rgba[idx + 2], rgba[idx + 3]


def frame_bbox(rgba: bytearray, atlas_w: int, row: int, column: int) -> tuple[int, int, int, int] | None:
    source_y = row * CELL_H
    source_x = column * CELL_W
    min_x = CELL_W
    min_y = CELL_H
    max_x = -1
    max_y = -1

    for y in range(CELL_H):
        for x in range(CELL_W):
            _r, _g, _b, a = pixel_at(rgba, atlas_w, source_x + x, source_y + y)
            if a > 8:
                min_x = min(min_x, x)
                min_y = min(min_y, y)
                max_x = max(max_x, x)
                max_y = max(max_y, y)
    if max_x < min_x or max_y < min_y:
        return None
    return min_x, min_y, max_x, max_y


def frame_bytes(rgba: bytearray, atlas_w: int, row: int, column: int) -> bytes:
    color = bytearray(CELL_W * CELL_H * 2)
    alpha = bytearray(CELL_W * CELL_H)
    source_y = row * CELL_H
    source_x = column * CELL_W

    for y in range(CELL_H):
        for x in range(CELL_W):
            dst = y * CELL_W + x
            r, g, b, a = pixel_at(rgba, atlas_w, source_x + x, source_y + y)
            c = rgb565(r, g, b)
            color[dst * 2] = c & 0xFF
            color[dst * 2 + 1] = (c >> 8) & 0xFF
            alpha[dst] = a
    return bytes(color + alpha)


def atom_frame(
    rgba: bytearray,
    atlas_w: int,
    row: int,
    column: int,
    crop: tuple[int, int, int, int],
    target_w: int,
    target_h: int,
    pad: int,
) -> tuple[list[int], list[int]]:
    src_x0, src_y0, src_x1, src_y1 = crop
    crop_w = src_x1 - src_x0 + 1
    crop_h = src_y1 - src_y0 + 1
    scale = min((target_w - 2 * pad) / crop_w, (target_h - 2 * pad) / crop_h)
    out_w = max(1, int(crop_w * scale))
    out_h = max(1, int(crop_h * scale))
    x_off = (target_w - out_w) // 2
    y_off = (target_h - out_h) // 2
    source_y = row * CELL_H
    source_x = column * CELL_W
    colors = [0] * (target_w * target_h)
    alphas = [0] * (target_w * target_h)

    for y in range(out_h):
        sy = min(crop_h - 1, int(y / scale))
        for x in range(out_w):
            sx = min(crop_w - 1, int(x / scale))
            r, g, b, a = pixel_at(rgba, atlas_w, source_x + src_x0 + sx, source_y + src_y0 + sy)
            dst = (y_off + y) * target_w + x_off + x
            colors[dst] = rgb565(r, g, b)
            alphas[dst] = a
    return colors, alphas


def write_header(
    output: Path,
    symbol: str,
    display_name: str,
    state: str,
    frames: list[bytes],
    source: Path,
) -> None:
    macro = symbol.upper()
    frame_size = CELL_W * CELL_H * 3
    lines = [
        "#pragma once",
        "#include <Arduino.h>",
        "#include <stdint.h>",
        "",
        f"// Generated by tools/pet_to_lvgl.py from {source}",
        f"// Pet: {display_name}; state: {state}; format: RGB565A8.",
        f"#define {macro}_FRAME_W {CELL_W}",
        f"#define {macro}_FRAME_H {CELL_H}",
        f"#define {macro}_FRAME_COUNT {len(frames)}",
        f"#define {macro}_FRAME_PIXELS ({macro}_FRAME_W * {macro}_FRAME_H)",
        f"#define {macro}_FRAME_BYTES ({macro}_FRAME_PIXELS * 3)",
        "",
        f"static const uint16_t {symbol}_frame_ms[{macro}_FRAME_COUNT] = {{260, 260, 260, 260, 260, 360}};",
        f"static const uint8_t {symbol}_frames[{macro}_FRAME_COUNT][{macro}_FRAME_BYTES] PROGMEM = {{",
    ]

    for frame in frames:
        if len(frame) != frame_size:
            raise SystemExit(f"bad frame size {len(frame)}")
        lines.append("    {")
        for i in range(0, len(frame), 16):
            chunk = ", ".join(f"0x{b:02X}" for b in frame[i : i + 16])
            lines.append(f"        {chunk},")
        lines.append("    },")
    lines.append("};")
    lines.append("")
    output.write_text("\n".join(lines), encoding="utf-8")


def write_atom_header(
    output: Path,
    symbol: str,
    display_name: str,
    state: str,
    frames: list[tuple[list[int], list[int]]],
    width: int,
    height: int,
    source: Path,
) -> None:
    macro = symbol.upper()
    pixels = width * height
    frame_ms = DEFAULT_FRAME_MS.get(state, [180] * len(frames))
    if len(frame_ms) != len(frames):
        frame_ms = [180] * len(frames)
    frame_ms_literal = ", ".join(str(ms) for ms in frame_ms)
    lines = [
        "#pragma once",
        "#include <Arduino.h>",
        "#include <stdint.h>",
        "",
        f"// Generated by tools/pet_to_lvgl.py from {source}",
        f"// Pet: {display_name}; state: {state}; format: RGB565 + alpha.",
        f"#define {macro}_W {width}",
        f"#define {macro}_H {height}",
        f"#define {macro}_FRAMES {len(frames)}",
        f"#define {macro}_PIXELS ({macro}_W * {macro}_H)",
        "",
        f"static const uint16_t {symbol}_frame_ms[{macro}_FRAMES] = {{{frame_ms_literal}}};",
        f"static const uint16_t {symbol}_rgb565[{macro}_FRAMES][{macro}_PIXELS] PROGMEM = {{",
    ]

    for colors, _alphas in frames:
        if len(colors) != pixels:
            raise SystemExit(f"bad color frame size {len(colors)}")
        lines.append("    {")
        for i in range(0, len(colors), 12):
            chunk = ", ".join(f"0x{value:04X}" for value in colors[i : i + 12])
            lines.append(f"        {chunk},")
        lines.append("    },")
    lines.append("};")
    lines.append("")
    lines.append(f"static const uint8_t {symbol}_alpha[{macro}_FRAMES][{macro}_PIXELS] PROGMEM = {{")
    for _colors, alphas in frames:
        if len(alphas) != pixels:
            raise SystemExit(f"bad alpha frame size {len(alphas)}")
        lines.append("    {")
        for i in range(0, len(alphas), 16):
            chunk = ", ".join(f"0x{value:02X}" for value in alphas[i : i + 16])
            lines.append(f"        {chunk},")
        lines.append("    },")
    lines.append("};")
    lines.append("")
    output.write_text("\n".join(lines), encoding="utf-8")


def atom_frames_for_state(
    rgba: bytearray,
    atlas_w: int,
    state: str,
    target_w: int,
    target_h: int,
    pad: int,
) -> list[tuple[list[int], list[int]]]:
    row, count = ROW_SPECS[state]
    boxes = [frame_bbox(rgba, atlas_w, row, column) for column in range(count)]
    visible = [box for box in boxes if box is not None]
    if not visible:
        raise SystemExit(f"{state} row has no visible pixels")
    min_x = max(0, min(box[0] for box in visible) - 4)
    min_y = max(0, min(box[1] for box in visible) - 4)
    max_x = min(CELL_W - 1, max(box[2] for box in visible) + 4)
    max_y = min(CELL_H - 1, max(box[3] for box in visible) + 4)
    crop = (min_x, min_y, max_x, max_y)
    return [
        atom_frame(rgba, atlas_w, row, column, crop, target_w, target_h, pad)
        for column in range(count)
    ]


def write_atom_multi_header(
    output: Path,
    symbol: str,
    display_name: str,
    states: list[tuple[str, list[tuple[list[int], list[int]]]]],
    width: int,
    height: int,
    source: Path,
) -> None:
    macro = symbol.upper()
    pixels = width * height
    flat_frames: list[tuple[list[int], list[int]]] = []
    frame_ms: list[int] = []
    offsets: list[int] = []
    counts: list[int] = []
    labels: list[str] = []

    for state, frames in states:
        offsets.append(len(flat_frames))
        counts.append(len(frames))
        labels.append(state)
        flat_frames.extend(frames)
        state_ms = DEFAULT_FRAME_MS.get(state, [180] * len(frames))
        if len(state_ms) != len(frames):
            state_ms = [180] * len(frames)
        frame_ms.extend(state_ms)

    lines = [
        "#pragma once",
        "#include <Arduino.h>",
        "#include <stdint.h>",
        "",
        f"// Generated by tools/pet_to_lvgl.py from {source}",
        f"// Pet: {display_name}; states: {', '.join(labels)}; format: RGB565 + alpha.",
        f"#define {macro}_W {width}",
        f"#define {macro}_H {height}",
        f"#define {macro}_FRAMES {len(flat_frames)}",
        f"#define {macro}_STATE_COUNT {len(states)}",
        f"#define {macro}_PIXELS ({macro}_W * {macro}_H)",
        "",
        f"static const uint16_t {symbol}_state_offset[{macro}_STATE_COUNT] = "
        f"{{{', '.join(str(v) for v in offsets)}}};",
        f"static const uint8_t {symbol}_state_count[{macro}_STATE_COUNT] = "
        f"{{{', '.join(str(v) for v in counts)}}};",
        f"static const uint16_t {symbol}_frame_ms[{macro}_FRAMES] = "
        f"{{{', '.join(str(v) for v in frame_ms)}}};",
        f"static const char* const {symbol}_state_label[{macro}_STATE_COUNT] = {{",
    ]
    for label in labels:
        lines.append(f'    "{label}",')
    lines.extend([
        "};",
        "",
        f"static const uint16_t {symbol}_rgb565[{macro}_FRAMES][{macro}_PIXELS] PROGMEM = {{",
    ])

    for colors, _alphas in flat_frames:
        if len(colors) != pixels:
            raise SystemExit(f"bad color frame size {len(colors)}")
        lines.append("    {")
        for i in range(0, len(colors), 12):
            chunk = ", ".join(f"0x{value:04X}" for value in colors[i : i + 12])
            lines.append(f"        {chunk},")
        lines.append("    },")
    lines.append("};")
    lines.append("")
    lines.append(f"static const uint8_t {symbol}_alpha[{macro}_FRAMES][{macro}_PIXELS] PROGMEM = {{")
    for _colors, alphas in flat_frames:
        if len(alphas) != pixels:
            raise SystemExit(f"bad alpha frame size {len(alphas)}")
        lines.append("    {")
        for i in range(0, len(alphas), 16):
            chunk = ", ".join(f"0x{value:02X}" for value in alphas[i : i + 16])
            lines.append(f"        {chunk},")
        lines.append("    },")
    lines.append("};")
    lines.append("")
    output.write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pet-dir", type=Path, required=True)
    parser.add_argument("--state", choices=sorted(ROW_SPECS) + ["all"], default="idle")
    parser.add_argument("--symbol", default=None)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--format", choices=("lvgl", "atom"), default="lvgl")
    parser.add_argument("--target-w", type=int, default=96)
    parser.add_argument("--target-h", type=int, default=96)
    parser.add_argument("--pad", type=int, default=2)
    args = parser.parse_args()

    pet_json = json.loads((args.pet_dir / "pet.json").read_text(encoding="utf-8"))
    source = args.pet_dir / pet_json.get("spritesheetPath", "spritesheet.webp")
    display_name = pet_json.get("displayName") or pet_json.get("id") or args.pet_dir.name
    symbol = args.symbol or f"pet_{ident(display_name)}_{ident(args.state)}"

    png = convert_to_png(source)
    width, height, rgba = read_png_rgba(png)
    if (width, height) != (ATLAS_COLUMNS * CELL_W, ATLAS_ROWS * CELL_H):
        raise SystemExit(f"unexpected atlas size {width}x{height}")

    if args.format == "atom":
        if args.state == "all":
            states = [
                (state, atom_frames_for_state(rgba, width, state, args.target_w, args.target_h, args.pad))
                for state in ROW_SPECS
            ]
            write_atom_multi_header(args.out, symbol, display_name, states, args.target_w, args.target_h, source)
            count = sum(len(frames) for _state, frames in states)
        else:
            frames = atom_frames_for_state(rgba, width, args.state, args.target_w, args.target_h, args.pad)
            write_atom_header(
                args.out,
                symbol,
                display_name,
                args.state,
                frames,
                args.target_w,
                args.target_h,
                source,
            )
            count = len(frames)
    else:
        if args.state == "all":
            raise SystemExit("--state all is only supported with --format atom")
        row, count = ROW_SPECS[args.state]
        frames = [frame_bytes(rgba, width, row, column) for column in range(count)]
        write_header(args.out, symbol, display_name, args.state, frames, source)
    print(f"Wrote {args.out} ({display_name} {args.state}, {count} frames)")


if __name__ == "__main__":
    main()
