#!/usr/bin/env python3
"""Zips the staged source tree, always marking UTF-8 names.

macOS `zip` writes UTF-8 bytes but leaves EFS bit 0x800 clear, so the Chinese
directory name ("…源码与Xcode工程") decodes as CP437 anywhere else and the
archive extracts into a garbage-named folder. Python's zipfile sets the flag
whenever a name is non-ASCII, which is what every other unzipper expects.

Nothing here re-encodes content: entries are stored as-is, deflated, in sorted
order so two runs over the same tree produce the same layout.
"""
import os
import sys
import zipfile

UTF8_FLAG = 0x800


def main():
    if len(sys.argv) != 3:
        print("usage: zip-tree.py <source-root> <output.zip>", file=sys.stderr)
        return 2
    root, output = sys.argv[1], sys.argv[2]

    # Collect entries first so the archive is deterministic.
    entries = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(dirnames):
            entries.append(os.path.join(dirpath, name))
        for name in sorted(filenames):
            entries.append(os.path.join(dirpath, name))
    entries.sort()

    if os.path.exists(output):
        os.remove(output)

    written = 0
    utf8_flagged = 0
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in entries:
            arcname = os.path.relpath(path, os.path.dirname(root))
            info = zipfile.ZipInfo.from_file(path, arcname)
            # Preserve Unix permissions so .command files stay executable.
            info.create_system = 3
            info.external_attr = (os.stat(path).st_mode & 0xFFFF) << 16
            if os.path.isdir(path):
                info.external_attr |= 0x10
            if any(ord(char) > 127 for char in arcname):
                # zipfile already decides this, but set it explicitly so the
                # guarantee does not depend on a library detail.
                info.flag_bits |= UTF8_FLAG
                utf8_flagged += 1
            if os.path.isdir(path):
                archive.writestr(info, b"")
            else:
                with open(path, "rb") as handle:
                    archive.writestr(info, handle.read())
            written += 1

    print(f"entries: {written}")
    print(f"utf8-flagged: {utf8_flagged}")

    # Verify: reopen and confirm every non-ASCII name round-trips, and that the
    # archive passes a full CRC test.
    with zipfile.ZipFile(output) as check:
        bad = check.testzip()
        if bad is not None:
            print(f"CRC failure in {bad}", file=sys.stderr)
            return 1
        missing_flag = [
            name for name in check.namelist()
            if any(ord(char) > 127 for char in name)
            and not (check.getinfo(name).flag_bits & UTF8_FLAG)
        ]
        if missing_flag:
            print(f"{len(missing_flag)} non-ASCII names lack the UTF-8 flag", file=sys.stderr)
            return 1
    print("verify: ok (CRCs pass, every non-ASCII name is UTF-8 flagged)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
