#!/usr/bin/env python3
"""Extract the Gengar overlay frame sets from a Codex pet spritesheet.

The public repository intentionally does not ship the Gengar frames. Use this
script with a spritesheet or ZIP you have the rights to use.

Examples:
    python tools/extract_gengar_frames.py --zip "C:\\path\\to\\gengar.zip"
    python tools/extract_gengar_frames.py --spritesheet "C:\\path\\to\\spritesheet.webp"
"""

from __future__ import annotations

import argparse
import tempfile
import zipfile
from pathlib import Path

from PIL import Image

# The Codex pet sheet is an 8-column x 9-row grid.
COLUMNS = 8
ROWS = 9

# row index (0-based) -> columns used for each overlay state.
FRAME_SETS: dict[str, tuple[int, list[int]]] = {
    "idle": (0, list(range(6))),
    "commands": (1, list(range(8))),
    "searching": (2, list(range(8))),
    "approval": (3, list(range(4))),
    "excited": (4, list(range(5))),
    "sad": (5, [2, 3, 4, 5, 6]),
    "sleeping": (5, [1]),
    "thinking": (6, list(range(6))),
    "writing": (7, list(range(6))),
    "happy": (8, list(range(6))),
}

IMAGE_SUFFIXES = {".webp", ".png", ".jpg", ".jpeg"}


def find_spritesheet(root: Path) -> Path:
    """Return the first likely spritesheet under an extracted ZIP directory."""
    named = [
        path
        for path in root.rglob("*")
        if path.is_file()
        and path.suffix.lower() in IMAGE_SUFFIXES
        and path.stem.lower().startswith("spritesheet")
    ]
    if named:
        return sorted(named)[0]
    images = [
        path
        for path in root.rglob("*")
        if path.is_file() and path.suffix.lower() in IMAGE_SUFFIXES
    ]
    if images:
        return sorted(images)[0]
    raise SystemExit("No spritesheet image was found in the ZIP.")


def resolve_sheet(args: argparse.Namespace) -> Path:
    if args.spritesheet is not None:
        if not args.spritesheet.is_file():
            raise SystemExit(f"Spritesheet not found: {args.spritesheet}")
        return args.spritesheet

    zip_path = args.zip
    if zip_path is None:
        candidate = Path.cwd() / "gengar.zip"
        if candidate.is_file():
            zip_path = candidate
        else:
            raise SystemExit("Pass --zip or --spritesheet (or put gengar.zip in the current folder).")
    if not zip_path.is_file():
        raise SystemExit(f"ZIP not found: {zip_path}")

    temp_dir = tempfile.TemporaryDirectory(prefix="dsh-gengar-")
    args._temp_dir = temp_dir  # keep the extraction alive while the image is read
    with zipfile.ZipFile(zip_path) as archive:
        archive.extractall(temp_dir.name)
    return find_spritesheet(Path(temp_dir.name))


def main() -> None:
    repo_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--zip", type=Path, help="ZIP containing a spritesheet.")
    source.add_argument("--spritesheet", type=Path, help="Path to a spritesheet image.")
    parser.add_argument(
        "--out",
        type=Path,
        default=repo_root / "overlay" / "frames",
        help="Output root (default: overlay/frames).",
    )
    args = parser.parse_args()

    sheet_path = resolve_sheet(args)
    image = Image.open(sheet_path).convert("RGBA")
    cell_width = image.width // COLUMNS
    cell_height = image.height // ROWS
    if cell_width <= 0 or cell_height <= 0:
        raise SystemExit(f"Unsupported spritesheet size: {image.width}x{image.height}")

    for name, (row, columns) in FRAME_SETS.items():
        folder = args.out / name
        folder.mkdir(parents=True, exist_ok=True)
        for index, column in enumerate(columns):
            box = (
                column * cell_width,
                row * cell_height,
                (column + 1) * cell_width,
                (row + 1) * cell_height,
            )
            image.crop(box).save(folder / f"frame-{index:02d}.png", "PNG")
        print(f"{name}: {len(columns)} frames")

    print(f"Done: {args.out}")
    print("Use these frames only if you own the artwork or have permission to use it.")


if __name__ == "__main__":
    main()
