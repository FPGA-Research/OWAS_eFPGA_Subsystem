#!/usr/bin/env python3
"""
scripts/filelist_to_librelane.py
Writes the files of one or more .f filelists as a LibreLane config fragment
({"VERILOG_FILES": [...]}, absolute paths, filelist order, duplicates removed). Pass it to
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
    parser.add_argument("filelists", nargs="+", help="Input .f filelist paths.")
    parser.add_argument("-o", "--output", required=True, help="Output JSON path.")
    parser.add_argument(
        "--repo-root",
        default=str(Path(__file__).resolve().parent.parent),
        help="Repository root used to resolve the filelist entries.",
    )
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    files = []
    for filelist in args.filelists:
        for f in parse_flist(Path(filelist).resolve(), repo_root):
            if repo_root / f not in files:
                files.append(repo_root / f)
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
