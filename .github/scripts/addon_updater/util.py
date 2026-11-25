"""Small shared helpers: hashing, logging, path normalisation."""

import hashlib
import sys

import config

# Manifest keys and launcher.json file lists use Windows separators.
SEP = "\\"


# ---------------------------------------------------------------------------
# Logging
#
# Plain stdout with a level prefix. GitHub Actions renders ::error:: / ::warning::
# as annotations, so failures show up on the run summary instead of being buried
# in the log.
# ---------------------------------------------------------------------------


def info(message):
    print(message, flush=True)


def step(message):
    print(f"\n=== {message} ===", flush=True)


def warn(message):
    print(f"::warning::{message}", flush=True)


def error(message):
    print(f"::error::{message}", flush=True)


def group(title):
    print(f"::group::{title}", flush=True)


def endgroup():
    print("::endgroup::", flush=True)


def fatal(message):
    error(message)
    sys.exit(1)


class AddonError(Exception):
    """A problem with one addon. Quarantines that addon, does not abort the run."""


# ---------------------------------------------------------------------------
# Hashing
# ---------------------------------------------------------------------------


def file_hash(data, length=config.HASH_LENGTH):
    """
    Hash file bytes exactly the way the launcher and manager do.

    Mirrors Utils.GetFileHash(string filePath, int length = 6):
        SHA1 over the raw bytes, lowercase hex, truncated to `length` chars.

    Verified against the live build_main_ashita manifest: all 49 published
    Sidekick files reproduce their existing hashes byte for byte.
    """
    return hashlib.sha1(data).hexdigest()[:length]


# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------


def to_manifest_path(*parts):
    """Join into a backslash-separated manifest key, e.g. addons\\Sidekick\\x.lua."""
    joined = SEP.join(p.strip("/").strip(SEP) for p in parts if p)
    return joined.replace("/", SEP)


def to_r2_key(target, manifest_path):
    """Convert a manifest key into an R2 object key under the target's build folder."""
    return f"{target.folder}/{manifest_path.replace(SEP, '/')}".lstrip("/")


def addon_prefix(target, install_name, addons_dir=None):
    """
    The manifest key prefix owned by one addon, including its trailing separator:
    under the target's Ashita addons folder, or `addons_dir` (one of target.addon_dirs).
    """
    return to_manifest_path(addons_dir or target.addons_dir, install_name) + SEP


def human_bytes(count):
    value = float(count)
    for unit in ("B", "KB", "MB", "GB"):
        if value < 1024 or unit == "GB":
            return f"{value:.1f}{unit}" if unit != "B" else f"{int(value)}B"
        value /= 1024
    return f"{value:.1f}GB"
