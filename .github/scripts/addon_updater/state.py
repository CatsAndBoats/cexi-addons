"""
The two pieces of remote state we mutate: the build manifest and launcher.json.

Both formats are dictated by code that already exists and cannot be changed
casually, so this module's job is to reproduce them byte-for-byte and touch only
the entries we own.
"""

import gzip
import json
import time
from collections import OrderedDict

import config
from util import SEP, info, to_manifest_path, warn


# ---------------------------------------------------------------------------
# build_main_ashita.gz
#
# Format, confirmed by downloading the live file:
#   - one `path\with\backslashes=abc123` line per file
#   - joined with "\n", no trailing newline, no CR anywhere
#   - gzipped
# Produced by the manager as:
#   string.Join("\n", map.Select(kvp => $"{kvp.Key.Replace("/", "\\")}={kvp.Value}"))
# ---------------------------------------------------------------------------


def parse_manifest(raw_gzip):
    """Decode the manifest into an ordered {path: hash} map."""
    if not raw_gzip:
        return OrderedDict()

    text = gzip.decompress(raw_gzip).decode("utf-8")
    entries = OrderedDict()

    for line in text.split("\n"):
        line = line.strip("\r")
        if not line:
            continue
        path, _, value = line.partition("=")
        if not _:
            continue
        entries[path.replace("/", SEP)] = value

    return entries


def serialise_manifest(entries):
    """Re-encode the manifest exactly the way the manager writes it."""
    body = "\n".join(f"{path.replace('/', SEP)}={value}" for path, value in entries.items())
    # mtime=0 so an unchanged manifest produces identical bytes run to run.
    return gzip.compress(body.encode("utf-8"), compresslevel=9, mtime=0)


def replace_addon_entries(entries, prefix, new_entries):
    """
    Swap one addon's subtree in the manifest and report what changed.

    Key lookup is case-insensitive because the launcher and manager both use
    StringComparer.OrdinalIgnoreCase for these maps. Existing keys keep their
    original position so the gz diff stays small.

    A file renamed by case alone (README.md -> Readme.md) is handled as a remove
    plus an add rather than an in-place update. The manifest has to carry the
    casing the release actually ships, because that is the casing we upload to and
    R2 object keys are case-sensitive.
    """
    lowered_prefix = prefix.lower()

    existing = {k: v for k, v in entries.items() if k.lower().startswith(lowered_prefix)}
    existing_by_lower = {k.lower(): k for k in existing}

    added, changed, removed = [], [], []
    matched_lowered = set()

    for path, value in new_entries.items():
        original_key = existing_by_lower.get(path.lower())

        if original_key is None:
            entries[path] = value
            added.append(path)
            continue

        matched_lowered.add(path.lower())

        if original_key != path:
            del entries[original_key]
            entries[path] = value
            removed.append(original_key)
            added.append(path)
        elif existing[original_key] != value:
            entries[original_key] = value
            changed.append(original_key)

    for lowered, original_key in existing_by_lower.items():
        if lowered not in matched_lowered:
            del entries[original_key]
            removed.append(original_key)

    return added, changed, removed


# ---------------------------------------------------------------------------
# launcher.json
#
# Written by Newtonsoft with Formatting.Indented on Windows: 2-space indent, CRLF,
# no BOM, no trailing newline, non-ASCII left unescaped. Verified byte-identical
# against the live file by round-tripping it through this encoder.
# ---------------------------------------------------------------------------


def parse_launcher(raw):
    return json.loads(raw.decode("utf-8-sig"), object_pairs_hook=OrderedDict)


def serialise_launcher(data):
    text = json.dumps(data, indent=config.JSON_INDENT, ensure_ascii=False)
    return text.replace("\n", config.JSON_NEWLINE).encode("utf-8")


def upsert_addon_entry(launcher, addon_name, metadata, fallback_link, self_update=False):
    """
    Create or refresh the `a_<name>` entry in launcher.json's addons map.

    Field meanings, from AddonData in cexi-manager/Source/Addons.cs:
        n  name        a  author      v  version (always null)
        d  description l  link        sd steamdeck note
        p  is plugin

    `v` stays null on purpose: the launcher then reads the version straight out of
    the lua on disk, so it is always accurate without us republishing launcher.json.

    `d` is preserved when it already has a value. Descriptions are hand-written in
    the manager and are usually better than addon.desc; the manager itself does the
    same thing (`?.d ?? GetLuaData("addon.desc", ...)`).

    `su` is only on an addon that updates itself in game (config.is_self_updating): the
    version this run publishes. The launcher leaves an installed copy whose addon.version
    is newer than it alone (Cloudflare.IsSelfUpdatedAddonFile) rather than putting the
    build's older files back. Taken off again when the addon stops being one.
    """
    addons = launcher.setdefault("addons", OrderedDict())
    key = f"a_{addon_name.lower()}"

    link = metadata.get("link") or ""
    if not link.startswith("http"):
        link = fallback_link

    existing = addons.get(key)
    if existing is None:
        addons[key] = OrderedDict(
            [
                ("n", metadata["name"] or addon_name),
                ("a", metadata["author"]),
                ("v", None),
                ("d", metadata["desc"]),
                ("l", link),
                ("sd", "-"),
                ("p", False),
            ]
        )
        if self_update:
            addons[key]["su"] = metadata["version"]
        info(f"    launcher.json: added {key}")
        return key, True

    before = json.dumps(existing, sort_keys=True)

    existing["n"] = metadata["name"] or addon_name
    existing["a"] = metadata["author"]
    existing["v"] = None
    existing["l"] = link
    existing.setdefault("sd", "-")
    existing["p"] = False
    if not (existing.get("d") or "").strip():
        existing["d"] = metadata["desc"]
    if self_update:
        existing["su"] = metadata["version"]
    else:
        existing.pop("su", None)

    after = json.dumps(existing, sort_keys=True)
    if before != after:
        info(f"    launcher.json: updated {key}")
        return key, True

    return key, False


def find_build(launcher, target):
    """The target's entry in launcher.json's builds array, or None."""
    for build in launcher.get("builds", []):
        if build.get("tag") == target.tag and build.get("name") == target.name:
            return build
    return None


def touch_build_timestamp(launcher, target):
    """
    Bump `updated` on the target's build (main/ashita, vanacore/vanacore).

    This is not cosmetic. Every build file is fetched as
    `{folder}/{file}?v={build.updated}` (cexi-launcher-v2.App/Source/Cloudflare.cs),
    so this timestamp is the cache-buster. Without bumping it, players can keep
    getting the old bytes from the edge.

    Written as a float because the manager serialises it from a C# double, and the
    live file contains `1787340890.0`.
    """
    stamp = float(int(time.time()))

    build = find_build(launcher, target)
    if build is None:
        raise RuntimeError(
            f"No build named {target.name!r} with tag {target.tag!r} in launcher.json"
        )

    build["updated"] = stamp
    info(f"    launcher.json: builds[{target.label}].updated = {stamp:.0f}")
    return stamp


def _dedupe(paths):
    """Normalise separators and drop case-insensitive duplicates, newest wins."""
    seen = set()
    result = []

    for path in paths:
        normalised = path.replace("/", SEP)
        lowered = normalised.lower()
        if lowered in seen:
            # Re-listed: move it to the end so it survives truncation.
            result = [p for p in result if p.lower() != lowered]
        seen.add(lowered)
        result.append(normalised)

    return result


def _merge_capped(existing, additions, cap):
    """
    Append new paths and trim the oldest, but never shrink a list we did not create.

    The manager truncates these lists to 300 on its own pushes. If we applied that
    cap blindly on a daily schedule we would erode entries the manager put there
    before every client had a chance to act on them, leaving those files stale on
    people's installs. So the effective limit is the larger of the cap and the list
    we found: at worst the oldest entries age out, and only once the list is already
    at its limit.
    """
    existing = _dedupe(existing)
    merged = _dedupe(existing + list(additions))
    limit = max(cap, len(existing))

    return merged[-limit:] if len(merged) > limit else merged


def record_recent_updates(launcher, target, paths):
    """
    Add changed files to recent_updates for the target's build.

    Load-bearing. The launcher only re-hashes files whose extension is in a small
    core set (.dll, .exe, .sys, ...) plus whatever recent_updates names. `.lua` is
    NOT in that set, so without this an existing install never notices an addon
    changed and players silently stay on the old version.
    """
    if not paths:
        return

    key = target.key
    bucket = launcher.setdefault("recent_updates", OrderedDict())
    before = len(bucket.get(key, []))
    bucket[key] = _merge_capped(bucket.get(key, []), paths, config.MAX_RECENT_UPDATES)
    info(f"    launcher.json: recent_updates[{key}] {before} -> {len(bucket[key])}")


def record_recent_deletes(launcher, target, paths):
    """
    Add removed files to recent_deletes for the target's build.

    The launcher deletes these regardless of the enable_file_deletion setting,
    which is currently false live. Without this, a file dropped by an upstream
    release stays on every player's disk forever.
    """
    if not paths:
        return

    key = target.key
    bucket = launcher.setdefault("recent_deletes", OrderedDict())
    before = len(bucket.get(key, []))
    bucket[key] = _merge_capped(bucket.get(key, []), paths, config.MAX_RECENT_DELETES)
    info(f"    launcher.json: recent_deletes[{key}] {before} -> {len(bucket[key])}")


def forget_recent(launcher, target, prefixes, keep=()):
    """
    Take every path under `prefixes` out of the target's recent_updates and recent_deletes.

    For addons the target no longer takes (Target.opt_in). The launcher deletes each
    recent_deletes path on every check without asking whose file it is, then
    downloads it again if the manifest still has it, so a path left there would
    wipe players' copies (and their edits) every time the launcher opened. Shrinks
    the lists on purpose, unlike _merge_capped. True if anything was taken out.

    `keep` names recent_deletes paths to leave in place though a prefix covers them:
    the target's forced deletes (forced_deletes), which no build ships.
    """
    lowered = tuple(p.replace("/", SEP).lower() for p in prefixes)
    if not lowered:
        return False

    spared = {p.replace("/", SEP).lower() for p in keep}
    changed = False
    for name in ("recent_updates", "recent_deletes"):
        bucket = launcher.get(name)
        if not bucket or target.key not in bucket:
            continue
        paths = bucket[target.key]
        kept = [
            p for p in paths
            if not p.replace("/", SEP).lower().startswith(lowered)
            or (name == "recent_deletes" and p.replace("/", SEP).lower() in spared)
        ]
        if len(kept) != len(paths):
            info(f"    launcher.json: {name}[{target.key}] {len(paths)} -> {len(kept)} (addons it no longer takes)")
            bucket[target.key] = kept
            changed = True

    return changed


def forced_deletes(targets, manifests, paths):
    """
    config.FORCED_DELETES as each target's recent_deletes paths, {target.key: [path]}:
    each path under the target's Ashita addons folder.

    A path any target's manifest still has (as this run left it) is left out of every
    target, with a warning: the launcher deletes recent_deletes paths on every check and
    downloads them again, so a file a build ships would be fetched over and over, and
    VanaCore's mirrored copy of an Ashita file lost.
    """
    shipped = set()
    for target in targets:
        listed = {k.lower() for k in manifests[target.key]}
        shipped.update(p.lower() for p in paths if to_manifest_path(target.addons_dir, p).lower() in listed)

    for path in paths:
        if path.lower() in shipped:
            warn(f"Forced delete {path} is in a build again; left out of recent_deletes")

    kept = [p for p in paths if p.lower() not in shipped]
    return OrderedDict((t.key, [to_manifest_path(t.addons_dir, p) for p in kept]) for t in targets)


def record_forced_deletes(launcher, forced):
    """
    Add each target's forced deletes (forced_deletes) to its recent_deletes where they
    are missing. True if anything was added.
    """
    changed = False
    for key, paths in forced.items():
        current = launcher.get("recent_deletes", {}).get(key, [])
        listed = {p.replace("/", SEP).lower() for p in current}
        missing = [p for p in paths if p.lower() not in listed]
        if not missing:
            continue

        bucket = launcher.setdefault("recent_deletes", OrderedDict())
        bucket[key] = _merge_capped(current, missing, config.MAX_RECENT_DELETES)
        info(f"    launcher.json: recent_deletes[{key}] {len(current)} -> {len(bucket[key])} (forced deletes)")
        changed = True

    return changed
