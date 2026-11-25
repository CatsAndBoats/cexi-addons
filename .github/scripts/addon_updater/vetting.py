"""
Vetting a release before any of it is allowed near R2.

Two independent gates:
  1. The entry-point lua must declare the addon.* metadata block, so we know this
     is really an Ashita addon and not some other repo that happens to have a .lua.
  2. Every file must pass the extension allow-list and size limits.

Anything that fails raises AddonError, which quarantines that addon. The rest of
the run continues, and the process exits non-zero at the end so the failure is
visible.
"""

import posixpath

import config
import lua_meta
from util import AddonError, human_bytes, info


# ---------------------------------------------------------------------------
# Lua metadata
# ---------------------------------------------------------------------------

# Reads the standard Ashita header, e.g.
#   addon.name      = 'Sidekick'
#   addon.author    = "Seekey"
# the same way the launcher does (lua_meta.py mirrors LuaMeta.cs), so commented-out
# lines are ignored and `addon.version = ver` is followed back to `local ver = '1.0'`.
def _metadata(code, field):
    return lua_meta.get(code, "addon." + field).strip()


def read_lua_metadata(lua_bytes, addon_name):
    """
    Parse and validate the addon.* header. Returns a dict of the fields found.

    Raises AddonError when a required field is missing or blank, which is the main
    guard against publishing a repo that isn't actually an Ashita addon.
    """
    head = lua_bytes[: config.LUA_METADATA_SCAN_BYTES].decode("utf-8", errors="replace")

    found = {}
    missing = []
    for field in config.REQUIRED_LUA_FIELDS:
        value = _metadata(head, field)
        if not value:
            missing.append(field)
        found[field] = value

    if missing:
        raise AddonError(
            f"Entry-point lua is missing required metadata: "
            f"{', '.join('addon.' + m for m in missing)}"
        )

    for field in config.OPTIONAL_LUA_FIELDS:
        found[field] = _metadata(head, field)

    # The launcher keys addons off the folder name, and shows addon.name as the
    # label. A mismatch is legal but confusing, so surface it.
    if found["name"].lower() != addon_name.lower():
        info(
            f"    note: addon.name is {found['name']!r} but the install folder is "
            f"{addon_name!r}; the launcher will key this as a_{addon_name.lower()}"
        )

    return found


# ---------------------------------------------------------------------------
# File safety
# ---------------------------------------------------------------------------


def should_exclude(relative_path):
    """
    True for repo furniture we drop silently rather than treating as an error.

    Confirmed correct against the live manifest: Sidekick's published file set is
    its release contents minus .gitignore, exactly what this drops.
    """
    parts = relative_path.split("/")

    for part in parts:
        lowered = part.lower()
        if lowered in config.EXCLUDED_NAMES:
            return True
        if config.DROP_DOTFILES and part.startswith("."):
            return True

    return False


def check_file_allowed(relative_path, data):
    """
    Raise AddonError unless this file is safe to publish.

    Deliberately an allow-list. A deny-list of executable extensions is a losing
    game; if a new file type shows up we would rather fail the run and add it to
    config.ALLOWED_EXTENSIONS deliberately than ship it by default.
    """
    name = posixpath.basename(relative_path)
    extension = posixpath.splitext(name)[1].lower()

    if extension:
        if extension not in config.ALLOWED_EXTENSIONS:
            raise AddonError(
                f"Blocked file type {extension!r} at {relative_path!r}. "
                f"Add it to ALLOWED_EXTENSIONS in config.py if it is genuinely safe."
            )
    else:
        if name.lower() not in config.ALLOWED_EXTENSIONLESS_NAMES:
            raise AddonError(
                f"Blocked extensionless file {relative_path!r}. "
                f"Add its name to ALLOWED_EXTENSIONLESS_NAMES in config.py if it is expected."
            )

    if len(data) > config.MAX_FILE_BYTES:
        raise AddonError(
            f"{relative_path!r} is {human_bytes(len(data))}, over the "
            f"{human_bytes(config.MAX_FILE_BYTES)} per-file limit"
        )

    # The manager blocks these too: they break the ?v= cache-buster on the
    # download URL and produce files players can never fetch.
    for char in config.URL_UNSAFE_CHARS:
        if char in relative_path:
            raise AddonError(f"URL-unsafe character {char!r} in path {relative_path!r}")

    # Windows reserved device names, which cannot be written to disk at all.
    stem = posixpath.splitext(name)[0].upper()
    if stem in {
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    }:
        raise AddonError(f"Reserved Windows filename in path {relative_path!r}")


def filter_and_check(files, addon_name):
    """
    Apply exclusions, then vet everything that survives.

    Returns {relative_path: bytes} ready to stage.
    """
    kept, dropped = {}, []

    for relative_path, data in sorted(files.items()):
        if should_exclude(relative_path):
            dropped.append(relative_path)
            continue
        check_file_allowed(relative_path, data)
        kept[relative_path] = data

    if not kept:
        raise AddonError("Release contains no publishable files after filtering")

    if len(kept) > config.MAX_ADDON_FILES:
        raise AddonError(
            f"{len(kept)} files exceeds the {config.MAX_ADDON_FILES} per-addon limit"
        )

    total = sum(len(d) for d in kept.values())
    if total > config.MAX_ADDON_BYTES:
        raise AddonError(
            f"Addon totals {human_bytes(total)}, over the "
            f"{human_bytes(config.MAX_ADDON_BYTES)} limit"
        )

    if dropped:
        info(f"    excluded {len(dropped)} repo file(s): {', '.join(dropped[:8])}"
             + (f" (+{len(dropped) - 8} more)" if len(dropped) > 8 else ""))

    info(f"    {len(kept)} file(s), {human_bytes(total)}")
    return kept
