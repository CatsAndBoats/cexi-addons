#!/usr/bin/env python3
"""
CatsEyeXI addon updater.

Publishes each addons.json entry's pinned commit ("commit") to R2, so addons can be
updated without rebuilding the whole client download. This is INSTALL: it never asks
what is newest upstream (a new pin is set by hand in a pull request).

A pin is published only when it is already live (R2's record of published commits)
or a code owner other than its author approved it in a pull request merged into
main (approvals.py). Its files are fetched by git at exactly that commit and
checked to be that commit (sources.fetch_commit); an "asset" entry's zip must match
its pinned asset_sha256.

The run is strictly two-phase. Phase one gathers, vets, scans and stages
everything locally and touches nothing remote. Phase two uploads. If anything at
all goes wrong during phase one, the run aborts having written nothing, which is
the point: a broken addon should never reach players.

Upload order within phase two is deliberate:
    1. addon files      - the bytes must exist before anything points at them
    2. launcher.json    - carries the new build.updated cache-buster
    3. build manifest   - what actually tells the launcher to go fetch them
    4. published record - written last, so a failed run re-does itself next time

addons.json is never written: it is the reviewed input, not a log.

Usage:
    python main.py [--dry-run] [--force] [--only NAME[,NAME...]] [--skip-clamav]
    python main.py --adopt   # record the current pins as published; publishes nothing
"""

import argparse
import json
import re
import os
import posixpath
import shutil
import sys
from collections import OrderedDict
from pathlib import Path

import approvals
import config
import r2 as r2_module
import scanner
import sources
import state
import summary
import vetting
from util import (
    SEP,
    AddonError,
    addon_prefix,
    endgroup,
    error,
    file_hash,
    group,
    human_bytes,
    info,
    step,
    to_manifest_path,
    to_r2_key,
    warn,
)

REPO_ROOT = Path(__file__).resolve().parents[3]
ADDONS_JSON = REPO_ROOT / "addons.json"
STAGING = REPO_ROOT / ".addon-staging"


# ---------------------------------------------------------------------------
# Phase one: gather, vet, stage
# ---------------------------------------------------------------------------


def entry_lua_key(files, lua_filename):
    """
    The entry-point lua among the addon's files: the one at the addon root, which
    is the shallowest, since the files are relative to the folder that lua was
    found in. A same-named lua deeper in the tree is not it, whatever order the
    zip lists them in (yunagearopt 1.1.53: native/yunagearopt.lua, a loader with
    no addon.* header, came first and was vetted in place of the real one).
    """
    same_name = [p for p in files if posixpath.basename(p).lower() == lua_filename.lower()]
    if not same_name:
        raise AddonError(f"{lua_filename} was filtered out; cannot vet the addon")
    return min(same_name, key=lambda p: p.count("/"))


class StagedAddon:
    def __init__(self, entry, tag, sha, files, metadata, row):
        self.entry = entry
        self.row = row              # summary.AddonRow
        self.name = entry["name"]
        self.install = entry.get("install") or entry["name"]
        self.tag = tag
        self.sha = sha
        self.files = files          # {relative posix path: bytes}
        self.metadata = metadata    # parsed addon.* header


def gather(entries, rows, token, force, only, published, approve):
    """
    Fetch, check and vet every addon whose pinned commit isn't published yet.

    Returns (staged, failures). A failure quarantines one addon; the others still
    publish, and main() exits non-zero so the run is visibly red. Each addon's
    outcome is also recorded on its summary row.
    """
    staged, failures = [], []

    for entry, row in zip(entries, rows):
        name = entry.get("name")
        if not name:
            failures.append(("<unnamed>", "addons.json entry has no 'name'"))
            row.status, row.reason = summary.FAILED, "addons.json entry has no 'name'"
            continue

        if only and name.lower() not in only:
            continue

        info(f"\n  {name}")

        try:
            staged_addon = _gather_one(entry, token, force, row, published, approve)
        except AddonError as exc:
            error(f"  {name}: {exc}")
            failures.append((name, str(exc)))
            row.status, row.reason = summary.FAILED, str(exc)
            continue
        except Exception as exc:  # noqa: BLE001 - one addon must not kill the run
            error(f"  {name}: unexpected error: {exc}")
            failures.append((name, f"unexpected error: {exc}"))
            row.status, row.reason = summary.FAILED, f"unexpected error: {exc}"
            continue

        if staged_addon is not None:
            staged.append(staged_addon)

    return staged, failures


def _gather_one(entry, token, force, row, published, approve):
    name = entry["name"]
    lua_filename = entry.get("lua") or f"{name}.lua"
    install = entry.get("install") or name

    # The launcher discovers addons as addons/<Folder>/<Folder>.lua, so these two
    # have to agree or the addon will not appear in the client at all.
    if posixpath.splitext(lua_filename)[0].lower() != install.lower():
        raise AddonError(
            f"'lua' ({lua_filename}) and 'install' ({install}) disagree; the launcher "
            f"requires addons/{install}/{install}.lua"
        )

    if not entry.get("github"):
        raise AddonError("addons.json entry has no 'github' repo URL")

    owner, repo = sources.parse_repo(entry["github"])
    branch = (entry.get("branch") or "").strip()
    path = (entry.get("path") or "").strip().strip("/")
    asset = (entry.get("asset") or "").strip()

    if asset and branch:
        raise AddonError("'asset' names a release's upload, so it can't go with 'branch' (a repo without releases)")
    if asset and path:
        raise AddonError("'asset' and 'path' can't go together: a release asset is the addon's folder already")

    pin = (entry.get("commit") or "").strip().lower()
    if not sources.is_sha(pin):
        raise AddonError(
            "no pinned commit: 'commit' must be a full 40-character commit hash, set by an approved pull request"
        )

    tag = (entry.get("tag") or "").strip() or (f"{branch}@{pin[:7]}" if branch else pin[:7])
    row.tag, row.sha = tag, pin
    live = published.get(name, "")
    row.known_sha = live  # the summary's "before": what is live, not what is pinned

    if pin == live and not force:
        info(f"    up to date at {tag} ({pin[:7]})")
        row.status = summary.UP_TO_DATE
        return None

    if pin == live:
        info(f"    forced re-publish of {tag} ({pin[:7]})")
    else:
        approve(entry, pin)
        info(f"    new pin {tag} ({pin[:7]}), was {live[:7] or 'none'}")

    if asset:
        # The author's own build of the addon folder, uploaded to the release, for a
        # repo that is the addon's source rather than the folder players install
        # (yunagearopt: native/build.py puts the VanaCore loader at the root and the
        # repo's yunagearopt.lua beside it as core.lua). Not in git, so it is pinned by
        # its own hash: the release named "tag" must be at the pinned commit, and the
        # zip must hash to asset_sha256.
        want = (entry.get("asset_sha256") or "").strip().lower()
        if not entry.get("tag") or not re.match(r"^[0-9a-f]{64}$", want):
            raise AddonError("an 'asset' entry needs its release 'tag' and the zip's 'asset_sha256' pinned")
        _, tag_sha, assets = sources.resolve_release(token, owner, repo, entry["tag"])
        if tag_sha != pin:
            raise AddonError(f"release {entry['tag']} is at {tag_sha[:7]}, not the pinned {pin[:7]}; publishing nothing")
        chosen = sources.pick_release_asset(assets, asset)
        info(f"    release asset: {chosen['name']} ({human_bytes(chosen.get('size') or 0)})")
        zip_bytes = sources.download_release_asset(token, chosen)
        got = sources.sha256(zip_bytes)
        if got != want:
            raise AddonError(f"{chosen['name']} hashes to {got[:12]}, not the pinned {want[:12]}; publishing nothing")
        root, raw_files = sources.extract_release(zip_bytes, lua_filename, path)
    else:
        root, raw_files = sources.fetch_commit(token, owner, repo, pin, lua_filename, path)
    info(f"    addon root: {root or '<archive root>'}")

    files = vetting.filter_and_check(raw_files, install)

    lua_key = entry_lua_key(files, lua_filename)
    metadata = vetting.read_lua_metadata(files[lua_key], install)
    info(
        f"    verified: {metadata['name']} v{metadata['version']} by {metadata['author']}"
    )

    row.status, row.version = summary.STAGED, metadata["version"]
    return StagedAddon(entry, tag, pin, files, metadata, row)


def write_staging(staged):
    """
    Write everything to disk under .addon-staging so ClamAV has a real tree to scan.

    Layout mirrors the primary build's folder: builds/main/Ashita/addons/<Addon>/...
    The same files go to every target, so one tree covers what gets scanned.
    """
    if STAGING.exists():
        shutil.rmtree(STAGING)

    primary = config.TARGETS[0]
    count = 0
    for addon in staged:
        base = STAGING / primary.folder / primary.addons_dir.replace("\\", "/") / addon.install
        for relative, data in addon.files.items():
            target = base / relative

            # Belt and braces: the archive entries were already checked, but this is
            # the moment we actually write to disk, so confirm containment here too.
            resolved = target.resolve()
            if not str(resolved).startswith(str(base.resolve())):
                raise RuntimeError(f"Refusing to write outside the staging root: {relative!r}")

            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            count += 1

    info(f"    staged {count} file(s) under {STAGING}")
    return count


# ---------------------------------------------------------------------------
# Phase two: diff against remote, then publish
# ---------------------------------------------------------------------------


class Plan:
    def __init__(self):
        self.uploads = OrderedDict()   # r2 key -> bytes
        self.added = []                # manifest paths
        self.changed = []
        self.removed = []
        self.purged = []               # entries of addons the build no longer takes: not in recent_deletes

    @property
    def touched(self):
        return self.added + self.changed

    @property
    def published(self):
        """Files players should fetch or drop: what moves recent_* and build.updated."""
        return bool(self.added or self.changed or self.removed)

    @property
    def empty(self):
        return not (self.published or self.purged)


def unwanted_prefixes(entries, target, only):
    """
    Manifest prefixes the target should hold nothing under: every addons folder of
    the build for an addons.json entry it doesn't take (Target.opt_in), and for one
    it takes, the folders it doesn't go in (a VanaCore native addon's old copy in
    addons\\ashita, say).
    """
    prefixes = []
    for entry in entries:
        if not entry.get("name") or (only and entry["name"].lower() not in only):
            continue
        install = entry.get("install") or entry["name"]
        goes_in = target.addons_dir_for(entry) if target.wants(entry) else None
        prefixes += [addon_prefix(target, install, folder) for folder in target.addon_dirs if folder != goes_in]
    return prefixes


def build_plan(staged, manifest, target, unwanted):
    """
    Diff the staged addons against one build's live manifest and decide what to upload.

    Only files whose hash actually changed are uploaded, so a forced re-publish of
    an unchanged release costs nothing. Addons the build doesn't take are left out,
    and whatever it already has of them (the `unwanted` prefixes) is dropped from
    the manifest as purged, not removed.
    """
    plan = Plan()

    for prefix in unwanted:
        _, _, purged = state.replace_addon_entries(manifest, prefix, OrderedDict())
        if purged:
            plan.purged += purged
            info(f"    {target.label}  {prefix.rstrip(SEP)}: -{len(purged)} dropped (the build no longer takes it)")

    for addon in staged:
        if not target.wants(addon.entry):
            continue
        folder = target.addons_dir_for(addon.entry)
        prefix = addon_prefix(target, addon.install, folder)
        new_entries = OrderedDict()

        for relative in sorted(addon.files):
            manifest_path = to_manifest_path(folder, addon.install, relative)
            new_entries[manifest_path] = file_hash(addon.files[relative])

        added, changed, removed = state.replace_addon_entries(manifest, prefix, new_entries)

        for manifest_path in added + changed:
            relative = manifest_path[len(prefix):].replace("\\", "/")
            plan.uploads[to_r2_key(target, manifest_path)] = addon.files[relative]

        plan.added += added
        plan.changed += changed
        plan.removed += removed

        # The run summary shows one set of counts per addon: the busiest build's.
        counts = (len(added), len(changed), len(removed))
        addon.row.files = tuple(max(a, b) for a, b in zip(addon.row.files or (0, 0, 0), counts))

        info(
            f"    {target.label}  {addon.install}: +{len(added)} new, ~{len(changed)} changed, "
            f"-{len(removed)} removed"
        )

    return plan


# ---------------------------------------------------------------------------
# addons.json
# ---------------------------------------------------------------------------


def load_addons_json():
    if not ADDONS_JSON.exists():
        raise SystemExit(f"addons.json not found at {ADDONS_JSON}")

    raw = ADDONS_JSON.read_text(encoding="utf-8-sig")
    entries = json.loads(raw, object_pairs_hook=OrderedDict)

    if not isinstance(entries, list):
        raise SystemExit("addons.json must be a JSON array")

    seen = set()
    for entry in entries:
        install = (entry.get("install") or entry.get("name", "")).lower()
        if install in seen:
            raise SystemExit(f"Duplicate addon install folder in addons.json: {install!r}")
        seen.add(install)

    return entries


def read_published(r2):
    """
    {addons.json name: commit} of what is live, from R2 (config.KEY_PUBLISHED), or None
    when there is no record yet (run once with --adopt).
    """
    raw = r2.get(config.KEY_PUBLISHED)
    if raw is None:
        return None
    data = json.loads(raw.decode("utf-8") if isinstance(raw, bytes) else raw)
    if not isinstance(data, dict) or not all(isinstance(v, str) for v in data.values()):
        raise SystemExit(f"{config.KEY_PUBLISHED} isn't a {{name: commit}} object; refusing to go on")
    return data


def write_published(r2, published, staged):
    """The record of what is live, with this run's pins in it. Written last."""
    record = OrderedDict(sorted(published.items()))
    for addon in staged:
        record[addon.name] = addon.sha
    info(f"  published record ({len(record)} addon(s))")
    r2.put(config.KEY_PUBLISHED, (json.dumps(record, indent=2) + "\n").encode("utf-8"), "application/json")


def approver(token):
    """The publish-time approval check, bound to this checkout and repository."""
    repository = os.environ.get("GITHUB_REPOSITORY", "CatsAndBoats/cexi-addons")
    return lambda entry, pin: approvals.check(str(REPO_ROOT), token, repository, entry["name"], pin)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def parse_args():
    parser = argparse.ArgumentParser(description="Publish Ashita addons from GitHub releases to R2")
    parser.add_argument("--dry-run", action="store_true", help="do everything except upload and commit")
    parser.add_argument("--force", action="store_true", help="re-publish even when the commit matches")
    parser.add_argument("--only", default="", help="comma-separated addon names to process")
    parser.add_argument("--skip-clamav", action="store_true", help="skip the virus scan")
    parser.add_argument(
        "--adopt", action="store_true",
        help="record addons.json's current pins as published, without publishing (first run only)",
    )
    return parser.parse_args()


def require_env(name):
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"Missing required environment variable: {name}")
    return value


def main():
    args = parse_args()
    only = {n.strip().lower() for n in args.only.split(",") if n.strip()}

    token = os.environ.get("GITHUB_TOKEN", "").strip()
    if not token:
        warn("GITHUB_TOKEN is not set; GitHub API requests will be rate limited")

    entries = load_addons_json()
    info(f"Loaded {len(entries)} addon(s) from addons.json")
    if args.dry_run:
        info("DRY RUN: nothing will be uploaded")

    # Written on every way out, so a failed or aborted run still says what it saw.
    report = summary.Report(entries, args.dry_run, args.force, only)
    try:
        return run(args, token, only, entries, report)
    except BaseException as exc:
        # Our own SystemExit messages are safe to show; anything else may carry
        # details from R2 or the network, so the summary only names it.
        message = exc.code if isinstance(exc, SystemExit) else None
        if not report.stopped:
            report.stopped = (
                message if isinstance(message, str) and message
                else f"unexpected {type(exc).__name__}; see the log"
            )
        raise
    finally:
        summary.publish(report, token)


def run(args, token, only, entries, report):
    r2 = r2_module.R2(
        endpoint=require_env("R2_S3_ENDPOINT"),
        access_key=require_env("R2_ACCESS_KEY_ID"),
        secret_key=require_env("R2_SECRET_ACCESS_KEY"),
        bucket=require_env("R2_BUCKET"),
        dry_run=args.dry_run,
    )

    published = read_published(r2)
    if args.adopt:
        pins = OrderedDict((e["name"], e["commit"].strip().lower()) for e in entries if sources.is_sha(e.get("commit")))
        step("Adopting the current pins as published")
        for name, pin in pins.items():
            info(f"  {name}: {pin[:7]}")
        r2.put(config.KEY_PUBLISHED, (json.dumps(pins, indent=2) + "\n").encode("utf-8"), "application/json")
        report.stopped = "adopted the current pins as published; nothing was published"
        return 0
    if published is None:
        raise SystemExit(
            f"{config.KEY_PUBLISHED} isn't in R2: run once with --adopt to record what is live now"
        )

    # -- phase one -----------------------------------------------------------

    step("1/6  Fetching pinned commits")
    staged, failures = gather(entries, report.rows, token, args.force, only, published, approver(token))

    # The common case: every pin is already live. Stop here.
    if not staged:
        step("No updates")
        info("  Every pinned commit is already published.")
        info("  Nothing downloaded, nothing uploaded.")
        if failures:
            _report_failures(failures)
            return 1
        return 0

    step("2/6  Staging files")
    write_staging(staged)

    step("3/6  Virus scan")
    if args.skip_clamav:
        warn("ClamAV scan skipped by request")
    elif not scanner.scan(STAGING, required=True):
        error("Aborting before any upload.")
        report.stopped = "the virus scan failed, so nothing was uploaded"
        return 1

    # -- remote state --------------------------------------------------------

    step("4/6  Reading remote state")
    # Read through S3 rather than the public URL: the CDN could hand us a stale
    # copy, and writing that back would clobber whatever the manager did last.
    raw_launcher = r2.get(config.KEY_LAUNCHER_JSON)
    if raw_launcher is None:
        raise SystemExit(f"{config.KEY_LAUNCHER_JSON} not found in R2")

    launcher = state.parse_launcher(raw_launcher)
    info(f"    launcher.json: {len(launcher.get('addons', {}))} addon entries")

    # Guard against writing back a launcher.json we failed to understand.
    if not launcher.get("builds"):
        raise SystemExit("launcher.json has no builds array; refusing to write it back")

    # Every target's manifest is read before anything is written, so a missing one
    # stops a required target's run with R2 untouched. An optional target that is
    # not there (the beta was retired, say) is skipped with a warning instead of
    # holding up the others.
    targets, manifests = [], {}
    for target in config.TARGETS:
        raw_manifest = r2.get(target.manifest_key)
        missing = None
        if raw_manifest is None:
            missing = f"Build manifest {target.manifest_key} not found in R2"
        elif state.find_build(launcher, target) is None:
            missing = f"launcher.json has no build {target.label}"

        if missing:
            if not target.optional:
                raise SystemExit(missing)
            warn(f"{missing}; skipping {target.label}")
            continue

        manifests[target.key] = state.parse_manifest(raw_manifest)
        targets.append(target)
        info(f"    {target.label}: {len(manifests[target.key])} manifest entries")

    step("5/6  Planning changes")
    unwanted = {t.key: unwanted_prefixes(entries, t, only) for t in targets}
    plans = OrderedDict((t.key, build_plan(staged, manifests[t.key], t, unwanted[t.key])) for t in targets)

    # After the plans, so a file this run publishes again isn't forced out (state.forced_deletes)
    forced = state.forced_deletes(targets, manifests, config.FORCED_DELETES)

    launcher_dirty = False
    for target in targets:
        launcher_dirty = state.forget_recent(launcher, target, unwanted[target.key], forced[target.key]) or launcher_dirty

    # config.FORCED_DELETES go in every target's recent_deletes before launcher.json is written
    launcher_dirty = state.record_forced_deletes(launcher, forced) or launcher_dirty

    for addon in staged:
        _, touched = state.upsert_addon_entry(
            launcher, addon.install, addon.metadata, addon.entry["github"],
            self_update=config.is_self_updating(addon.entry),
        )
        launcher_dirty = launcher_dirty or touched

        if any(addon.row.files):
            addon.row.planned = summary.PUBLISHED
        else:
            addon.row.planned = summary.METADATA_ONLY if touched else summary.UNCHANGED

    files_changed = any(not plan.empty for plan in plans.values())

    # Nothing changed anywhere: leave every remote file exactly as it is.
    #
    # A release can move without changing a single published byte -- a retag, a
    # CI-only or docs-only commit that we filter out, or a --force re-run. Writing
    # in that case would be actively harmful: bumping build.updated changes the ?v=
    # cache-buster on every file in the build, so ~3,500 objects would miss the edge
    # at once for no benefit at all.
    if not files_changed and not launcher_dirty:
        step("No updates")
        info("  Pins moved but no published file or metadata changed.")
        info("  launcher.json and the build manifest are untouched.")
        write_published(r2, published, staged)
        report.published()
        if failures:
            _report_failures(failures)
            return 1
        return 0

    # recent_updates, recent_deletes and build.updated only mean anything when files
    # actually moved, and only for the build they moved in: a build that did not
    # change keeps its timestamp so it is not cache-busted. On a metadata-only change
    # we deliberately leave every timestamp alone.
    for target in targets:
        plan = plans[target.key]
        if not plan.published:
            continue
        state.record_recent_updates(launcher, target, plan.touched)
        state.record_recent_deletes(launcher, target, plan.removed)
        state.touch_build_timestamp(launcher, target)

    if not files_changed:
        info("    no file changes; leaving build.updated and recent_updates untouched")

    uploads = OrderedDict()
    for plan in plans.values():
        uploads.update(plan.uploads)
    removed_total = sum(len(plan.removed) for plan in plans.values())
    purged_total = sum(len(plan.purged) for plan in plans.values())

    info(
        f"\n  {len(uploads)} file(s) to upload, "
        f"{removed_total} manifest entry/entries to drop, "
        f"{purged_total} of addons a build no longer takes (players keep their copies)"
    )

    # -- phase two -----------------------------------------------------------

    step("6/6  Publishing")

    if uploads:
        info(f"  addon files ({len(uploads)})")
        r2.put_many(uploads)
    else:
        info("  addon files: nothing to upload")

    # launcher.json before the manifest. A client that sees the new manifest but an
    # old launcher.json would request new files with a stale ?v= cache-buster; the
    # reverse ordering is harmless, because a new launcher.json with an old manifest
    # simply means there is nothing new to fetch yet.
    info("  launcher.json")
    r2.put(config.KEY_LAUNCHER_JSON, state.serialise_launcher(launcher), "application/json")

    purge_keys = [config.KEY_LAUNCHER_JSON]

    for target in targets:
        if plans[target.key].empty:
            info(f"  build manifest {target.label}: unchanged, not re-uploaded")
            continue
        info(f"  build manifest {target.label}")
        r2.put(
            target.manifest_key,
            state.serialise_manifest(manifests[target.key]),
            "application/gzip",
        )
        purge_keys.append(target.manifest_key)

    info("  cache")
    r2_module.purge_cache(purge_keys, dry_run=args.dry_run)

    if removed_total:
        # Per the chosen policy the objects stay on R2; dropping them from the
        # manifest and listing them in recent_deletes is what removes them from
        # players' installs.
        info(f"  {removed_total} orphaned object(s) left on R2 (manifest-only removal)")

    write_published(r2, published, staged)
    report.published()

    step("Done")
    for addon in staged:
        info(f"  {addon.name} -> {addon.tag} ({addon.sha[:7]})")

    if failures:
        _report_failures(failures)
        return 1
    return 0


def _report_failures(failures):
    group(f"{len(failures)} addon(s) failed")
    for name, reason in failures:
        error(f"{name}: {reason}")
    endgroup()
    error(f"{len(failures)} addon(s) failed and were not published.")


if __name__ == "__main__":
    sys.exit(main())
