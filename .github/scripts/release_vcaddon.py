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


VERSION_MARK = "<!-- vcaddon version: "


def latest_version(latest_tag: str) -> str | None:
    """The version <name>-latest holds (from the mark in its notes), or None when there's no such release."""
    r = gh("release", "view", latest_tag, "--json", "body", "--jq", ".body", check=False)
    if r.returncode != 0:
        return None
    start = r.stdout.find(VERSION_MARK)
    if start < 0:
        return ""
    start += len(VERSION_MARK)
    return r.stdout[start:r.stdout.find(" -->", start)].strip()


def update_latest(repo: str, target: str, latest_tag: str, had: str | None, path: str, manifest: dict,
                  title: str) -> None:
    """<name>-latest: one release per addon whose asset is always <name>.vcaddon, the newest version, so its address
    never changes (the README links it). Made the first time, then its asset replaced and its tag moved."""
    name = manifest["name"]
    fixed = os.path.join(os.path.dirname(path), f"{name}.vcaddon")
    shutil.copyfile(path, fixed)
    url = f"https://github.com/{repo}/releases/download/{latest_tag}/{name}.vcaddon"
    body = (f"{VERSION_MARK}{manifest['version']} -->\n"
            f"Always the newest {manifest.get('title', name)}, now {manifest['version']}, at an address that doesn't "
            f"change:\n\n{url}\n\nA web page can link it as:\n\n```\nvanacore://install/{url}\n```\n\n"
            f"Every version has its own release too ({name}-v<version>).\n")
    latest_title = f"{title} (latest)"
    try:
        if had is None:
            create = ["release", "create", latest_tag, fixed, "--title", latest_title, "--notes-file", "-",
                      "--latest=false"]
            if target:
                create += ["--target", target]
            gh(*create, stdin=body)
        else:
            gh("release", "upload", latest_tag, fixed, "--clobber")
            gh("release", "edit", latest_tag, "--title", latest_title, "--notes-file", "-", stdin=body)
            if target:
                gh("api", "-X", "PATCH", f"repos/{repo}/git/refs/tags/{latest_tag}", "-f", f"sha={target}",
                   "-F", "force=true")
    finally:
        os.remove(fixed)


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
                version = manifest["version"]
                tag, latest_tag = f"{name}-v{version}", f"{name}-latest"
                exists = release_exists(tag)
                latest = latest_version(latest_tag)
                do_version = not exists or args.force
                do_latest = latest != version or args.force
                if not do_version and not do_latest:
                    print(f"{name}: {tag} is released already and {latest_tag} is {version}, passed over")
                    continue
                path = pack.pack(folder, work)
                info = pack.check(path)
                asset = os.path.basename(path)
                what = f"{asset} ({info['files']} files, {os.path.getsize(path):,} bytes)"
                if args.dry_run:
                    if do_version:
                        print(f"{name}: would {'replace the package on' if exists else 'release'} {tag}: {what}")
                    if do_latest:
                        print(f"{name}: would {'make' if latest is None else 'update'} {latest_tag} ({latest or 'none'} -> {version})")
                    os.remove(path)
                    continue
                title = f"{manifest.get('title', name)} {version}"
                if do_version and exists:
                    gh("release", "upload", tag, path, "--clobber")
                    print(f"{name}: {tag}'s package replaced: {what}")
                elif do_version:
                    create = ["release", "create", tag, path, "--title", title, "--notes-file", "-", "--latest=false"]
                    if target:
                        create += ["--target", target]
                    gh(*create, stdin=notes(manifest, repo, tag, asset, last_change(folder)))
                    print(f"{name}: released {tag}: {what}")
                if do_latest:
                    update_latest(repo, target, latest_tag, latest, path, manifest, title)
                    print(f"{name}: {latest_tag} is {version}")
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
