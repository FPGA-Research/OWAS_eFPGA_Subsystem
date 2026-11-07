#!/usr/bin/env python3
"""
scripts/filelist_to_librelane.py
Writes the files of a .f filelist as a LibreLane config fragment
({"VERILOG_FILES": [...]}, absolute paths, filelist order). Pass it to
librelane before the macro's config.yaml, which then needs no VERILOG_FILES.
"""
import argparse
import json
import sys
from pathlib import Path

from flatten_filelists import parse_flist


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="python3 scripts/filelist_to_librelane.py",
        description="Convert a .f filelist into a LibreLane VERILOG_FILES config fragment.",
    )
    parser.add_argument("filelist", help="Input .f filelist path.")
    parser.add_argument("-o", "--output", required=True, help="Output JSON path.")
    parser.add_argument(
        "--repo-root",
        default=str(Path(__file__).resolve().parent.parent),
        help="Repository root used to resolve the filelist entries.",
    )
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    files = [repo_root / f for f in parse_flist(Path(args.filelist).resolve(), repo_root)]
    missing = [str(f) for f in files if not f.is_file()]
    if missing:
        print("Missing files:\n  " + "\n  ".join(missing), file=sys.stderr)
        return 1

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({"VERILOG_FILES": [str(f) for f in files]}, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
