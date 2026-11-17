#!/usr/bin/env python3
"""Releases each VanaCore addon in addons/vanacore/ as its own .vcaddon, one GitHub release per addon version.

    release_vcaddon.py [--only a,b] [--force] [--dry-run] [--work DIR]

An addon's release is tagged <name>-v<version> (its addon.version), so a version already released is passed over: push a
change without bumping addon.version and nothing is released. --force puts the package up again on a release that's
there (the same tag, its asset replaced). Each package is built with tools/vcaddon/pack.py, checked as VanaCore's
installer would, uploaded, then deleted: nothing is kept on the runner or as a workflow artifact. Needs the gh CLI
(GH_TOKEN with contents: write) and GITHUB_REPOSITORY.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ADDONS = os.path.join(ROOT, "addons", "vanacore")
sys.path.insert(0, os.path.join(ROOT, "tools", "vcaddon"))
import pack  # noqa: E402


def gh(*args: str, stdin: str | None = None, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(["gh", *args], input=stdin, text=True, capture_output=True, check=check)


def release_exists(tag: str) -> bool:
    return gh("release", "view", tag, "--json", "tagName", check=False).returncode == 0


def last_change(folder: str) -> str:
    out = subprocess.run(["git", "-C", ROOT, "log", "-1", "--format=%s", "--", folder], text=True,
                         capture_output=True, check=False).stdout.strip()
    return out


def addon_folders(only: set[str]) -> list[str]:
    names = sorted(n for n in os.listdir(ADDONS) if os.path.isfile(os.path.join(ADDONS, n, n + ".lua")))
    missing = only - set(names)
    if missing:
        raise SystemExit(f"no addon folder in addons/vanacore for: {', '.join(sorted(missing))}")
    return [n for n in names if not only or n in only]


def notes(manifest: dict, repo: str, tag: str, asset: str, change: str) -> str:
    url = f"https://github.com/{repo}/releases/download/{tag}/{asset}"
    lines = [manifest.get("description", ""), ""]
    if change:
        lines += [f"Last change: {change}", ""]
    lines += ["Install: in game, /vana > Addons > Install from file, or double-click the .vcaddon (Windows). "
              "A web page can link it as:", "", "```", f"vanacore://install/{url}", "```"]
    return "\n".join(lines).strip() + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--only", default="", help="comma-separated addon folder names (blank: every addon)")
    ap.add_argument("--force", action="store_true", help="replace the package on a version already released")
    ap.add_argument("--dry-run", action="store_true", help="say what would be released and upload nothing")
    ap.add_argument("--work", help="the folder packages are built in (default: a temporary one); emptied at the end")
    args = ap.parse_args()
    repo = os.environ.get("GITHUB_REPOSITORY", "CatsAndBoats/cexi-addons")
    target = os.environ.get("GITHUB_SHA", "")
    only = {s.strip() for s in args.only.split(",") if s.strip()}
    work = args.work or tempfile.mkdtemp(prefix="vcaddon-")
    os.makedirs(work, exist_ok=True)
    failed = []
    try:
        for name in addon_folders(only):
            folder = os.path.join(ADDONS, name)
            try:
                manifest = pack.manifest_for(folder, name)
                tag = f"{name}-v{manifest['version']}"
                exists = release_exists(tag)
                if exists and not args.force:
                    print(f"{name}: {tag} is released already, passed over")
                    continue
                path = pack.pack(folder, work)
                info = pack.check(path)
                asset = os.path.basename(path)
                what = f"{asset} ({info['files']} files, {os.path.getsize(path):,} bytes)"
                if args.dry_run:
                    print(f"{name}: would {'replace the package on' if exists else 'release'} {tag}: {what}")
                elif exists:
                    gh("release", "upload", tag, path, "--clobber")
                    print(f"{name}: {tag}'s package replaced: {what}")
                else:
                    title = f"{manifest.get('title', name)} {manifest['version']}"
                    create = ["release", "create", tag, path, "--title", title, "--notes-file", "-", "--latest=false"]
                    if target:
                        create += ["--target", target]
                    gh(*create, stdin=notes(manifest, repo, tag, asset, last_change(folder)))
                    print(f"{name}: released {tag}: {what}")
                os.remove(path)
            except (pack.Problem, OSError) as e:
                print(f"{name}: {e}", file=sys.stderr)
                failed.append(name)
            except subprocess.CalledProcessError as e:
                print(f"{name}: gh {' '.join(e.cmd[1:3])} failed: {(e.stderr or '').strip()}", file=sys.stderr)
                failed.append(name)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    if failed:
        print(f"failed: {', '.join(failed)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
