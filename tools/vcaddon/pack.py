#!/usr/bin/env python3
"""Builds a VanaCore addon package (.vcaddon) from an addon's folder, or checks one.

    pack.py <addon folder> [-o <dir>] [--title T]   writes <dir>/<name>-<version>.vcaddon (default: beside the folder)
    pack.py --check <file.vcaddon> ...     says whether VanaCore would install each, and what it would show

The folder is a VanaCore addon: <name>/<name>.lua, its `addon.name` the folder's name. Its manifest (addon.json, at the
package's root) comes from the Lua's header (addon.version, addon.author, addon.desc, addon.link); an addon.json in the
folder adds to it or overrides it (title, homepage, min_vanacore). The same rules as the launcher's publishing
(CatsAndBoats/cexi-addons .github/scripts/publish_r2.py) and VanaCore's installer (src/core/addonpkg.cpp) apply: only the
file types addons ship, 32 MB a file, 256 MB in all, 5000 files, no symlinks, names Windows can hold. The format is in
README.md beside this script.

The package is the same bytes for the same files (sorted, fixed dates), so a rebuild of an unchanged addon doesn't
differ. Python 3.8 or later, nothing else.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import zipfile

FORMAT = 1
ALLOWED_EXTENSIONS = {
    ".lua", ".json", ".xml", ".xaml", ".txt", ".md", ".csv", ".ini", ".cfg", ".yml", ".yaml", ".tbl", ".addon",
    ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".ico",
    ".ttf", ".otf",
    ".wav", ".ogg", ".mp3",
    ".html", ".htm", ".css",
}
ALLOWED_BARE_NAMES = {"license", "licence", "copying", "notice", "authors", "contributors", "changelog", "readme", "version"}
SKIPPED_NAMES = {"thumbs.db", "desktop.ini", ".ds_store", "__macosx"}
RESERVED = {"vana", "keybinds", "freecam", "mcp", "hello", "libs", "apiexplorer", "plates", "sendkey", "minparty",
            "loadscreen", "customcolors"}
DEVICES = {"con", "prn", "aux", "nul"} | {f"com{i}" for i in range(1, 10)} | {f"lpt{i}" for i in range(1, 10)}
MAX_FILE_BYTES = 32 * 1024 * 1024
MAX_ADDON_BYTES = 256 * 1024 * 1024
MAX_FILES = 5000
NAME_RE = re.compile(r"^[A-Za-z0-9_\-][A-Za-z0-9_.\-]{0,63}$")
FIXED_DATE = (2020, 1, 1, 0, 0, 0)
MANIFEST_FIELDS = ("format", "name", "version", "title", "author", "description", "homepage", "min_vanacore", "kind")


class Problem(Exception):
    pass


def lua_header(text: str) -> dict:
    """addon.<key> = '<value>' lines near the top of an addon's Lua."""
    found = {}
    for m in re.finditer(r"""^[ \t]*addon\.(name|version|author|desc|link)[ \t]*=[ \t]*(['"])(.*?)\2""", text[:65536], re.M):
        found.setdefault(m.group(1), m.group(3))
    return found


def part_problem(part: str) -> str | None:
    if not part:
        return "has an empty folder name in its path"
    if part in (".", ".."):
        return "reaches outside the addon's folder"
    if part[-1] in ". " or part[0] == " ":
        return "has a name Windows can't hold"
    if part.split(".")[0].lower() in DEVICES:
        return "is named for a Windows device"
    if any(c in part for c in '\\:*?"<>|') or any(ord(c) < 32 or ord(c) == 127 for c in part):
        return "has a character Windows can't hold in a name"
    return None


def file_problem(rel: str, size: int) -> str | None:
    """Why a file (its path inside the addon's folder, '/' between parts) can't be in a package."""
    for part in rel.split("/"):
        why = part_problem(part)
        if why:
            return why
    name = rel.split("/")[-1].lower()
    ext = os.path.splitext(name)[1]
    if not (ext in ALLOWED_EXTENSIONS or (ext == "" and name in ALLOWED_BARE_NAMES)):
        return f"isn't a kind of file addons ship ({ext or name})"
    if size > MAX_FILE_BYTES:
        return f"is {size:,} bytes, over the 32 MB a file may be"
    return None


def skipped(name: str) -> bool:
    return name.startswith(".") or name.lower() in SKIPPED_NAMES


def gather(folder: str, name: str) -> list[tuple[str, str]]:
    """The addon's files: (path in the package, path on disk), sorted. Raises Problem listing every one found."""
    problems, files, seen, total = [], [], set(), 0
    for dirpath, dirs, names in os.walk(folder):
        dirs[:] = sorted(d for d in dirs if not skipped(d))
        for file in sorted(names):
            if skipped(file):
                continue
            full = os.path.join(dirpath, file)
            rel = os.path.relpath(full, folder).replace(os.sep, "/")
            if os.path.islink(full):
                problems.append(f"{rel}: a symlink")
                continue
            size = os.path.getsize(full)
            why = file_problem(rel, size)
            if why:
                problems.append(f"{rel} {why}")
            if rel.lower() in seen:
                problems.append(f"{rel}: another file has the same name but for case, which Windows can't hold")
            seen.add(rel.lower())
            total += size
            files.append((f"{name}/{rel}", full))
    if total > MAX_ADDON_BYTES:
        problems.append(f"{total:,} bytes in all, over the 256 MB an addon may be")
    if len(files) > MAX_FILES:
        problems.append(f"{len(files)} files, over the {MAX_FILES} a package may hold")
    if problems:
        raise Problem("\n  ".join(["it can't be packed:"] + problems))
    return files


def manifest_for(folder: str, name: str, title: str | None = None) -> dict:
    main = os.path.join(folder, name + ".lua")
    if not os.path.isfile(main):
        raise Problem(f"there's no {name}/{name}.lua, the file VanaCore loads")
    with open(main, "rb") as f:
        header = lua_header(f.read(65536).decode("utf-8", "replace"))
    if header.get("name") not in (None, name):
        raise Problem(f"{name}.lua says addon.name = {header['name']!r}: it must be the folder's name, {name!r}")
    manifest = {"format": FORMAT, "name": name, "version": header.get("version", ""), "author": header.get("author", ""),
                "description": header.get("desc", ""), "homepage": header.get("link", "")}
    own = os.path.join(folder, "addon.json")
    if os.path.isfile(own):
        with open(own, encoding="utf-8") as f:
            extra = json.load(f)
        if not isinstance(extra, dict):
            raise Problem("its addon.json isn't a JSON object")
        unknown = sorted(set(extra) - set(MANIFEST_FIELDS))
        if unknown:
            raise Problem(f"its addon.json has fields a manifest hasn't: {', '.join(unknown)}")
        if extra.get("name", name) != name:
            raise Problem(f"its addon.json names it {extra['name']!r}, not the folder's {name!r}")
        manifest.update({k: v for k, v in extra.items() if v is not None})
    if title:
        manifest["title"] = title
    if not manifest["version"]:
        raise Problem(f"no version: set addon.version in {name}.lua (or \"version\" in addon.json)")
    if manifest.get("homepage") and not re.match(r"^https?://", manifest["homepage"]):
        raise Problem("the homepage (addon.link) must start with https:// or http://")
    return {k: v for k, v in manifest.items() if v not in ("", None)}


def pack(folder: str, out_dir: str | None, title: str | None = None) -> str:
    folder = os.path.abspath(folder.rstrip("/\\"))
    name = os.path.basename(folder)
    if not os.path.isdir(folder):
        raise Problem(f"{folder} isn't a folder")
    if not NAME_RE.match(name) or ".." in name:
        raise Problem(f"{name!r} isn't a name VanaCore can load (letters, digits, _ - and ., at most 64)")
    if name.lower() in RESERVED:
        raise Problem(f"{name} is one of VanaCore's own addons: a package can't replace it")
    manifest = manifest_for(folder, name, title)
    files = gather(folder, name)
    safe_version = re.sub(r"[^A-Za-z0-9._-]", "_", manifest["version"])
    target = os.path.join(out_dir or os.path.dirname(folder), f"{name}-{safe_version}.vcaddon")
    os.makedirs(os.path.dirname(target), exist_ok=True)
    temp = target + ".part"
    with zipfile.ZipFile(temp, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        def add(arcname: str, data: bytes) -> None:
            info = zipfile.ZipInfo(arcname, FIXED_DATE)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 0  # (FAT: no Unix mode bits)
            info.external_attr = 0x20  # (archive)
            z.writestr(info, data)
        add("addon.json", (json.dumps(manifest, indent=2, ensure_ascii=False) + "\n").encode("utf-8"))
        for arcname, full in files:
            with open(full, "rb") as f:
                add(arcname, f.read())
    os.replace(temp, target)
    return target


def check(path: str) -> dict:
    """What VanaCore's installer reads from a package; raises Problem when it would refuse it."""
    with zipfile.ZipFile(path) as z:
        infos = [i for i in z.infolist() if not any(p.lower() in SKIPPED_NAMES for p in i.filename.split("/"))
                 and not i.filename.split("/")[-1].startswith("._")]
        if len(infos) > MAX_FILES:
            raise Problem(f"{len(infos)} files, over the {MAX_FILES} a package may hold")
        names = {i.filename for i in infos}
        if "addon.json" in names:
            manifest = json.loads(z.read("addon.json").decode("utf-8"))
        else:
            tops = {i.filename.split("/")[0] for i in infos}
            if len(tops) != 1:
                raise Problem("no addon.json and no single addon folder")
            manifest = {"name": tops.pop()}
        name = manifest.get("name", "")
        if manifest.get("format", 1) != 1 or manifest.get("kind", "vanacore") != "vanacore":
            raise Problem("not a format-1 VanaCore addon package")
        if not NAME_RE.match(name) or ".." in name or name.lower() in RESERVED:
            raise Problem(f"{name!r} can't be a package's addon")
        total, seen = 0, set()
        for i in infos:
            n = i.filename
            if n == "addon.json":
                continue
            if i.flag_bits & 1:
                raise Problem(f"{n} is encrypted")
            if i.compress_type not in (0, 8):
                raise Problem(f"{n} is packed with method {i.compress_type}")
            if (i.create_system == 3) and ((i.external_attr >> 16) & 0o170000) == 0o120000:
                raise Problem(f"{n} is a symbolic link")
            if n.startswith("/") or (len(n) > 1 and n[1] == ":"):
                raise Problem(f"{n} is an absolute path")
            parts = n.rstrip("/").split("/")
            if parts[0] != name or (len(parts) < 2 and not n.endswith("/")):
                raise Problem(f"{n} is outside the addon's folder")
            if n.endswith("/"):
                continue
            why = file_problem("/".join(parts[1:]), i.file_size)
            if why:
                raise Problem(f"{n} {why}")
            if n.lower() in seen:
                raise Problem(f"{n} is in it twice")
            seen.add(n.lower())
            total += i.file_size
        if f"{name}/{name}.lua" not in names:
            raise Problem(f"no {name}/{name}.lua")
        if total > MAX_ADDON_BYTES:
            raise Problem("over 256 MB unpacked")
        bad = z.testzip()
        if bad:
            raise Problem(f"{bad} is damaged")
        manifest["files"], manifest["bytes"] = len(seen), total
        return manifest


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("paths", nargs="+", help="an addon folder (to pack) or, with --check, .vcaddon files")
    ap.add_argument("-o", "--out", help="where the .vcaddon goes (default: beside the addon's folder)")
    ap.add_argument("--title", help="the name the install prompt shows (default: addon.json's title, else the folder's name)")
    ap.add_argument("--check", action="store_true", help="check .vcaddon files instead of packing")
    args = ap.parse_args()
    failed = False
    for path in args.paths:
        try:
            if args.check:
                m = check(path)
                print(f"{path}: ok - {m.get('title', m['name'])} {m.get('version', '(no version)')}"
                      f" by {m.get('author', '?')}, {m['files']} files, {m['bytes']:,} bytes")
            else:
                target = pack(path, args.out, args.title)
                m = check(target)
                print(f"{target}: {m['name']} {m['version']}, {m['files']} files, {m['bytes']:,} bytes unpacked,"
                      f" {os.path.getsize(target):,} packed")
        except (Problem, zipfile.BadZipFile, json.JSONDecodeError, OSError) as e:
            print(f"{path}: {e}", file=sys.stderr)
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
