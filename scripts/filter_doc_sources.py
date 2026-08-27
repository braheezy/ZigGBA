#!/usr/bin/env python3
"""Copy a Zig documentation site without build-cache entries in sources.tar."""

import shutil
import sys
import tarfile
from pathlib import Path


def is_build_cache_entry(path: str) -> bool:
    return any(part in {".zig-cache", "zig-cache"} for part in Path(path).parts)


def main() -> None:
    source_dir = Path(sys.argv[1])
    output_dir = Path(sys.argv[2])
    output_dir.mkdir(parents=True, exist_ok=True)

    for source in source_dir.iterdir():
        if source.name != "sources.tar":
            shutil.copy2(source, output_dir / source.name)

    with tarfile.open(source_dir / "sources.tar", "r") as source_tar:
        with tarfile.open(output_dir / "sources.tar", "w") as output_tar:
            for member in source_tar:
                if is_build_cache_entry(member.name):
                    continue
                file_obj = source_tar.extractfile(member) if member.isfile() else None
                output_tar.addfile(member, file_obj)


if __name__ == "__main__":
    main()
