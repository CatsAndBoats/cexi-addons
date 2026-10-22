#!/usr/bin/env python3
"""Publishes the VanaCore addons in addons/vanacore/ to the VanaCore build on R2, for .github/workflows/publish-r2.yaml.

    publish_r2.py                       every addon, to the vanacore build
    publish_r2.py --only a,b            only these addons (their folder names)
    publish_r2.py --tags vanacore,x     the builds named vanacore in launcher.json with these tags (default: vanacore)
    publish_r2.py --dry-run             list what would change and write nothing
    publish_r2.py --check               check the addons' files only, without R2

Each addon's folder lands in the build's addons\\vanacore\\<addon>\\, the way CatsAndBoats/launcher publishes the VanaCore
build (.github/scripts/push_build.py) and the Ashita addons in its addons.json (.github/scripts/addon_updater):

  1. checks every file: a type addons ship, a size limit, a name R2 can serve, and <addon>.lua naming the addon
  2. reads launcher.json and each build's state (launcher/build_<tag>_<name>.gz) through S3, never the CDN's copy
  3. diffs each addon against the state (SHA1, first 6 hex: the launcher's Utils.GetFileHash)
  4. uploads new and changed files to <build folder>/addons/vanacore/<addon>/..., each verified on R2
  5. reads launcher.json and the state again and applies the same changes to them, so whatever another writer
     (the Manager, the launcher's workflows) put there while the files went up is kept
  6. uploads launcher.json (recent_updates, recent_deletes, the build's updated), then the state, then purges both from
     Cloudflare's cache: a launcher that sees the new state must already have the build's new ?v= cache-buster

Only these addons' folders are touched: the rest of the build, VanaCore's own addons included, is left as it is. A file
taken out of an addon is dropped from the state and listed in recent_deletes, so the launcher deletes it from players'
installs; its object stays on R2. A whole addon folder taken out of this repository is not removed from the build.
Standard library only.
"""
import argparse
import concurrent.futures as cf
import datetime
import gzip
import hashlib
import hmac
import http.client
import json
import mimetypes
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SOURCE = os.path.join(ROOT, "addons", "vanacore")

# The builds published to: launcher.json's builds with this name and one of the tags (--tags), and where the addons
# go in them. VanaCore loads addons\vanacore\<addon>\<addon>.lua.
BUILD_NAME = "vanacore"
DEFAULT_TAGS = "vanacore"
BUILD_ADDONS = "addons\\vanacore\\"

KEY_LAUNCHER = "launcher/launcher.json"
KEY_STATE = "launcher/build_{tag}_{name}.gz"
PUBLIC_ORIGIN = "https://launcher.catseyexi.com"

# The Manager caps recent_updates at 300. A list already longer than that (others' entries) is never shortened.
MAX_RECENT = 300

# The addon updater's allow-list (config.py): what an addon may ship. Nothing executable.
ALLOWED_EXTENSIONS = {
    ".lua", ".json", ".xml", ".xaml", ".txt", ".md", ".csv", ".ini", ".cfg", ".yml", ".yaml", ".tbl", ".addon",
    ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".ico",
    ".ttf", ".otf",
    ".wav", ".ogg", ".mp3",
    ".html", ".htm", ".css",
}
ALLOWED_BARE_NAMES = {"license", "licence", "copying", "notice", "authors", "contributors", "changelog", "readme", "version"}
# Left out without failing (dotfiles are too)
SKIPPED_NAMES = {"thumbs.db", "desktop.ini", ".ds_store", "__macosx"}
MAX_FILE_BYTES = 32 * 1024 * 1024
MAX_ADDON_BYTES = 256 * 1024 * 1024
# R2 can't serve # or ? in a key, and the build's paths use \ as the separator
UNSAFE_CHARS = ("#", "?", "\\")

UPLOAD_WORKERS = 8
UPLOAD_RETRIES = 3
VERIFY_RETRIES = 3

EMPTY_SHA = hashlib.sha256(b"").hexdigest()

mimetypes.add_type("text/plain", ".lua")
mimetypes.add_type("font/ttf", ".ttf")
mimetypes.add_type("font/otf", ".otf")


def log(msg=""):
    print(msg, flush=True)


class Stop(Exception):
    """Ends the run with a message and nothing more written."""


# ---- The addons in this repository

class Addon:
    def __init__(self, name, folder):
        self.name = name
        self.folder = folder
        self.files = {}     # path in the addon, with backslashes: full path
        self.hashes = {}    # path in the addon: hash


def hash_file(path):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()[:6]


def lua_addon_name(path):
    with open(path, "rb") as f:
        head = f.read(64 * 1024).decode("utf-8", "replace")
    m = re.search(r"^\s*addon\.name\s*=\s*['\"]([^'\"]+)['\"]", head, re.M)
    return m.group(1) if m else None


def check(addon):
    """Fills in the addon's files; returns the problems that stop it being published."""
    problems = []
    total = 0
    if any(c in addon.name for c in UNSAFE_CHARS):
        problems.append(f"{addon.name}: the folder name has one of {' '.join(UNSAFE_CHARS)}")

    for dirpath, dirs, files in os.walk(addon.folder):
        dirs[:] = sorted(d for d in dirs if not d.startswith(".") and d.lower() not in SKIPPED_NAMES)
        for name in sorted(files):
            if name.startswith(".") or name.lower() in SKIPPED_NAMES:
                continue
            full = os.path.join(dirpath, name)
            parts = os.path.relpath(full, addon.folder).split(os.sep)
            rel = "\\".join(parts)
            where = f"{addon.name}\\{rel}"
            if os.path.islink(full):
                problems.append(f"{where}: a symlink")
                continue
            if any(c in part for part in parts for c in UNSAFE_CHARS):
                problems.append(f"{where}: the name has one of {' '.join(UNSAFE_CHARS)}")
            ext = os.path.splitext(name)[1].lower()
            if ext not in ALLOWED_EXTENSIONS and not (ext == "" and name.lower() in ALLOWED_BARE_NAMES):
                problems.append(f"{where}: {ext or 'no extension'} isn't a type addons ship (ALLOWED_EXTENSIONS)")
            size = os.path.getsize(full)
            total += size
            if size > MAX_FILE_BYTES:
                problems.append(f"{where}: {size:,} bytes, over the {MAX_FILE_BYTES:,} limit")
            if rel.lower() in (r.lower() for r in addon.files):
                problems.append(f"{where}: another file has the same name but for case, which Windows can't hold")
            addon.files[rel] = full

    if not addon.files:
        problems.append(f"{addon.name}: no files")
    if total > MAX_ADDON_BYTES:
        problems.append(f"{addon.name}: {total:,} bytes, over the {MAX_ADDON_BYTES:,} limit")

    # VanaCore loads addons\vanacore\<folder>\<folder>.lua, and the name is where players' settings are kept
    entry = addon.files.get(addon.name + ".lua")
    if entry is None:
        problems.append(f"{addon.name}: no {addon.name}.lua, the file VanaCore loads")
    else:
        named = lua_addon_name(entry)
        if named != addon.name:
            problems.append(f"{addon.name}\\{addon.name}.lua: addon.name is {named!r}, not the folder's name")
    return problems


def gather(source, only):
    """The addons to publish, checked and hashed. Stops listing every problem found."""
    names = sorted(n for n in os.listdir(source) if os.path.isdir(os.path.join(source, n)) and not n.startswith("."))
    if only:
        unknown = [n for n in only if n not in names]
        if unknown:
            raise Stop(f"no addon folder {', '.join(unknown)} in addons/vanacore (there are: {', '.join(names)})")
        names = [n for n in names if n in only]
    if not names:
        raise Stop("no addons in addons/vanacore")

    addons, problems = [], []
    for name in names:
        addon = Addon(name, os.path.join(source, name))
        problems += check(addon)
        addons.append(addon)
    if problems:
        raise Stop("nothing published, the addons have problems:\n  " + "\n  ".join(problems))

    for addon in addons:
        addon.hashes = {rel: hash_file(full) for rel, full in addon.files.items()}
    return addons


# ---- JSON, written the way Newtonsoft's Formatting.Indented does (2 spaces, CRLF, no BOM, no trailing newline)

def dumps(obj):
    return json.dumps(obj, indent=2, ensure_ascii=False).replace("\n", "\r\n")


def loads(raw):
    return json.loads(raw.decode("utf-8-sig"))


# ---- A build's state: "path\with\backslashes=hash" lines joined by \n, gzipped (the Manager's format)

def parse_state(raw):
    state = {}
    if raw:
        for line in gzip.decompress(raw).decode("utf-8").split("\n"):
            line = line.strip("\r")
            if line:
                k, sep, v = line.partition("=")
                if sep:
                    state[k.replace("/", "\\")] = v
    return state


def make_state(state):
    text = "\n".join(f"{k.replace('/', chr(92))}={v}" for k, v in state.items())
    return gzip.compress(text.encode("utf-8"), compresslevel=9, mtime=0)


def replace_folder(state, prefix, want):
    """Makes the state's entries under prefix exactly `want` ({path: hash}); returns (new, changed, removed).

    Paths match case-insensitively, as in the launcher and the Manager, and keep their place in the state. A file
    renamed by case alone is a remove and an add: R2's keys are case-sensitive, so the state must carry the new case.
    """
    low = prefix.lower()
    have = {k.lower(): k for k in state if k.lower().startswith(low)}
    new, changed, removed = [], [], []
    for path, value in want.items():
        old = have.pop(path.lower(), None)
        if old is None:
            state[path] = value
            new.append(path)
        elif old != path:
            del state[old]
            state[path] = value
            removed.append(old)
            new.append(path)
        elif state[old] != value:
            state[old] = value
            changed.append(old)
    for old in have.values():
        del state[old]
        removed.append(old)
    return new, changed, removed


# ---- launcher.json's lists

def merge_recent(paths, add):
    """paths plus add, each once (case-insensitively, a re-listed one moved to the end), the oldest trimmed past
    MAX_RECENT; a list that was already longer is kept at its length, so others' entries aren't cut."""
    limit = max(MAX_RECENT, len(paths))
    low = {p.lower() for p in add}
    merged = [p for p in paths if p.lower() not in low] + list(add)
    return merged[-limit:]


def find_build(launcher, tag):
    for b in launcher.get("builds") or []:
        if b.get("tag") == tag and b.get("name") == BUILD_NAME:
            return b
    return None


class Change:
    """What one addon changes in one build."""

    def __init__(self, addon, new, changed, removed):
        self.addon = addon
        self.new, self.changed, self.removed = new, changed, removed

    @property
    def empty(self):
        return not (self.new or self.changed or self.removed)


def apply(state, launcher, tag, addons, now):
    """Puts the addons into one build's state and launcher.json, in place. Returns its [Change], one per addon;
    launcher.json is only touched when a file moved."""
    build = find_build(launcher, tag)
    key = f"{tag}_{BUILD_NAME}"
    changes = []
    for addon in addons:
        prefix = BUILD_ADDONS + addon.name + "\\"
        want = {prefix + rel: h for rel, h in sorted(addon.hashes.items(), key=lambda kv: kv[0].lower())}
        changes.append(Change(addon, *replace_folder(state, prefix, want)))

    touched = [p for c in changes for p in c.new + c.changed]
    touched_low = {p.lower() for p in touched}
    # A path back in the build comes out of recent_deletes, or the launcher would delete it and fetch it again on
    # every check; and a file renamed by case alone isn't listed, as Windows would delete the new one with it
    removed = [p for c in changes for p in c.removed if p.lower() not in touched_low]
    if not (touched or removed):
        return changes

    updates = launcher.setdefault("recent_updates", {})
    deletes = launcher.setdefault("recent_deletes", {})
    if touched:
        # Load-bearing: the launcher only re-hashes .dll/.exe-type files and what recent_updates names, so without
        # it an existing install never notices a .lua changed
        updates[key] = merge_recent(updates.get(key, []), touched)
    kept = [p for p in deletes.get(key, []) if p.lower() not in touched_low]
    if removed or len(kept) != len(deletes.get(key, [])):
        deletes[key] = merge_recent(kept, removed)
    if not deletes.get(key):
        deletes.pop(key, None)
    # Every file in the build is fetched as <folder>/<file>?v=<updated>: this is what gets players past the CDN's copy
    build["updated"] = float(now)
    return changes


# ---- R2 (S3 API, SigV4, path-style; the same PutObject the Manager sends with payload signing off)

class Transient(Exception):
    pass


class R2:
    def __init__(self, cfg):
        self.host = urllib.parse.urlparse(cfg["r2_api"]).netloc
        self.bucket = cfg["r2_bucket"]
        self.access = cfg["r2_access_key"]
        self.secret = cfg["r2_secret_key"]

    def _request(self, method, key, body=None, length=0, content_type=None):
        payload = "UNSIGNED-PAYLOAD" if method == "PUT" else EMPTY_SHA
        amz = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        day = amz[:8]
        path = "/" + self.bucket + "/" + urllib.parse.quote(key, safe="/-_.~")
        headers = {"host": self.host, "x-amz-content-sha256": payload, "x-amz-date": amz}
        signed = ";".join(sorted(headers))
        canonical = "\n".join([
            method, path, "",
            "".join(f"{k}:{headers[k]}\n" for k in sorted(headers)),
            signed, payload,
        ])
        scope = f"{day}/auto/s3/aws4_request"
        to_sign = "\n".join(["AWS4-HMAC-SHA256", amz, scope, hashlib.sha256(canonical.encode()).hexdigest()])
        k = ("AWS4" + self.secret).encode()
        for part in (day, "auto", "s3", "aws4_request"):
            k = hmac.new(k, part.encode(), hashlib.sha256).digest()
        signature = hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()
        headers["authorization"] = (
            f"AWS4-HMAC-SHA256 Credential={self.access}/{scope}, SignedHeaders={signed}, Signature={signature}")
        if method == "PUT":
            headers["content-length"] = str(length)
            headers["content-type"] = content_type or "application/octet-stream"

        conn = http.client.HTTPSConnection(self.host, timeout=300)
        conn.blocksize = 1 << 20
        try:
            conn.request(method, path, body=body, headers=headers)
            resp = conn.getresponse()
            return resp.status, resp.read()
        except (OSError, http.client.HTTPException) as e:
            raise Transient(str(e))
        finally:
            conn.close()

    @staticmethod
    def _check(status, data, what):
        if status in (408, 429) or status >= 500:
            raise Transient(f"{what}: HTTP {status}")
        if status >= 300:
            raise RuntimeError(f"{what}: HTTP {status} {data[:300].decode('utf-8', 'replace')}")

    def _retry(self, fn, what):
        for attempt in range(1, UPLOAD_RETRIES + 1):
            try:
                return fn()
            except Transient as e:
                if attempt == UPLOAD_RETRIES:
                    raise RuntimeError(f"{what} failed after {attempt} attempts: {e}")
                time.sleep(0.25 * 2 ** (attempt - 1))

    def get(self, key):
        """The object's bytes, or None when it isn't there."""
        def go():
            status, data = self._request("GET", key)
            if status == 404:
                return None
            self._check(status, data, f"GET {key}")
            return data
        return self._retry(go, f"GET {key}")

    def exists(self, key):
        status, _ = self._request("HEAD", key)
        return status == 200

    def put(self, key, data=None, path=None, content_type=None):
        """Uploads bytes or a file, then checks it's on R2 (the Manager's Upload + VerifyObjectExists)."""
        ctype = content_type or mimetypes.guess_type(key)[0]
        length = os.path.getsize(path) if path is not None else len(data)

        def go():
            if path is not None:
                with open(path, "rb") as f:
                    status, body = self._request("PUT", key, body=f, length=length, content_type=ctype)
            else:
                status, body = self._request("PUT", key, body=data, length=length, content_type=ctype)
            self._check(status, body, f"PUT {key}")
        self._retry(go, f"PUT {key}")

        for attempt in range(1, VERIFY_RETRIES + 1):
            if self.exists(key):
                return
            time.sleep(0.25 * attempt)
        raise RuntimeError(f"upload verification failed for {key}")


def config_from_env():
    env = {"r2_api": "R2_S3_ENDPOINT", "r2_access_key": "R2_ACCESS_KEY_ID",
           "r2_secret_key": "R2_SECRET_ACCESS_KEY", "r2_bucket": "R2_BUCKET"}
    cfg = {k: os.environ.get(v, "").strip() for k, v in env.items()}
    missing = [env[k] for k, v in cfg.items() if not v]
    if missing:
        raise Stop("missing in the environment: " + ", ".join(missing) + " (the repository's Actions secrets)")
    cfg["cloudflare_zone_id"] = os.environ.get("CLOUDFLARE_ZONE_ID", "").strip()
    cfg["cloudflare_api_token"] = os.environ.get("CLOUDFLARE_API_TOKEN", "").strip()
    return cfg


def purge(cfg, keys):
    """Purges launcher.json and the states from Cloudflare's cache (fetched without a ?v=). True when done."""
    zone, token = cfg.get("cloudflare_zone_id"), cfg.get("cloudflare_api_token")
    if not (zone and token):
        log("  ! cache NOT purged: CLOUDFLARE_ZONE_ID / CLOUDFLARE_API_TOKEN missing")
        return False
    urls = [f"{PUBLIC_ORIGIN}/{k}" for k in keys]
    req = urllib.request.Request(
        f"https://api.cloudflare.com/client/v4/zones/{zone}/purge_cache",
        data=json.dumps({"files": urls}, separators=(",", ":")).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json",
                 "User-Agent": "CatsEyeXI-AddonPublish/1.0"},
        method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
    except Exception as e:
        log(f"  ! cache NOT purged: {e}")
        return False
    try:
        ok = json.loads(body).get("success") is True
    except ValueError:
        ok = False
    if not ok:
        log(f"  ! cache NOT purged: {body[:300]}")
        return False
    for url in urls:
        log(f"  cache purged: {url}")
    return True


# ---- The run

def read_remote(r2, tags):
    """launcher.json, and {tag: (build, state)} for each tag. Stops if any build or state is missing."""
    raw = r2.get(KEY_LAUNCHER)
    if raw is None:
        raise Stop(f"{KEY_LAUNCHER} isn't on R2")
    launcher = loads(raw)
    if not launcher.get("builds"):
        raise Stop("launcher.json has no builds: refusing to write it back")
    builds = {}
    for tag in tags:
        build = find_build(launcher, tag)
        if build is None:
            names = ", ".join(f"{b.get('tag')}/{b.get('name')}" for b in launcher["builds"])
            raise Stop(f"launcher.json has no build {tag}/{BUILD_NAME} (builds: {names})")
        raw = r2.get(KEY_STATE.format(tag=tag, name=BUILD_NAME))
        if raw is None:
            raise Stop(f"{KEY_STATE.format(tag=tag, name=BUILD_NAME)} isn't on R2")
        builds[tag] = (build, parse_state(raw))
    return launcher, builds


def r2_key(build, path):
    return build["folder"].replace("\\", "/").rstrip("/") + "/" + path.replace("\\", "/")


def plan_uploads(builds, plans):
    """{R2 key: local file} for every new and changed file."""
    uploads = {}
    for tag, changes in plans.items():
        build = builds[tag][0]
        for c in changes:
            for path in c.new + c.changed:
                rel = path[len(BUILD_ADDONS) + len(c.addon.name) + 1:]
                uploads[r2_key(build, path)] = c.addon.files[rel]
    return uploads


def upload(r2, uploads):
    log(f"Uploading {len(uploads)} file(s)...")
    failures, done = [], 0
    with cf.ThreadPoolExecutor(max_workers=UPLOAD_WORKERS) as pool:
        futures = {pool.submit(r2.put, key, path=path): key for key, path in sorted(uploads.items())}
        for fut in cf.as_completed(futures):
            try:
                fut.result()
                done += 1
                log(f"  [{done}/{len(uploads)}] {futures[fut]}")
            except Exception as e:
                failures.append(f"{futures[fut]}: {e}")
    if failures:
        raise Stop("uploads failed, launcher.json and the build state left as they were:\n  " + "\n  ".join(failures))


def report(plans, dry_run, summary):
    for tag, changes in plans.items():
        for c in changes:
            log(f"{tag}/{BUILD_NAME}  {c.addon.name}: {len(c.new)} new, {len(c.changed)} changed, "
                f"{len(c.removed)} removed")
            for label, files in (("new", c.new), ("changed", c.changed), ("removed", c.removed)):
                for f in files:
                    log(f"  {label:8} {f}")
    if summary:
        lines = ["### " + ("Dry run: nothing was written" if dry_run else "Published to R2"), "",
                 "| Build | Addon | New | Changed | Removed |", "| --- | --- | ---: | ---: | ---: |"]
        for tag, changes in plans.items():
            lines += [f"| {tag}/{BUILD_NAME} | {c.addon.name} | {len(c.new)} | {len(c.changed)} | {len(c.removed)} |"
                      for c in changes]
        with open(summary, "a", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")


def publish(r2, cfg, addons, tags, dry_run=False, summary=None, now=None):
    """Steps 2 to 6. Returns the exit code."""
    launcher, builds = read_remote(r2, tags)
    now = int(time.time()) if now is None else now
    plans = {tag: apply(state, launcher, tag, addons, now) for tag, (_, state) in builds.items()}
    report(plans, dry_run, summary)
    if all(c.empty for changes in plans.values() for c in changes):
        log("Nothing to publish: R2 already has these files.")
        return 0
    if dry_run:
        log("Dry run: nothing written.")
        return 0

    uploads = plan_uploads(builds, plans)
    if uploads:
        upload(r2, uploads)

    # Again from R2, so what landed while the files went up is kept, and the same changes on top
    launcher, builds = read_remote(r2, tags)
    plans = {tag: apply(state, launcher, tag, addons, now) for tag, (_, state) in builds.items()}
    late = {k: v for k, v in plan_uploads(builds, plans).items() if k not in uploads}
    if late:
        upload(r2, late)
    changed = [tag for tag, changes in plans.items() if not all(c.empty for c in changes)]
    if not changed:
        log("Nothing left to publish: R2 had these files by the time they were up.")
        return 0

    log("Uploading launcher.json...")
    r2.put(KEY_LAUNCHER, data=dumps(launcher).encode("utf-8"), content_type="application/json")
    keys = [KEY_LAUNCHER]
    for tag in changed:
        key = KEY_STATE.format(tag=tag, name=BUILD_NAME)
        log(f"Uploading {key}...")
        r2.put(key, data=make_state(builds[tag][1]), content_type="application/gzip")
        keys.append(key)
    purged = purge(cfg, keys)

    log(f"Published to {', '.join(f'{t}/{BUILD_NAME}' for t in changed)}.")
    if not purged:
        # Survivable, as for the addon updater: the launcher fetches both with a random cache-buster
        log("::warning::Cloudflare's cache was not purged (see above): launchers may read the old launcher.json / "
            "build state until it expires. Purge them from the Manager (Cloudflare tab) if it matters.")
    return 0


def split(value):
    return [v.strip() for v in (value or "").split(",") if v.strip()]


def main(argv=None):
    ap = argparse.ArgumentParser(description="Publish addons/vanacore to the VanaCore build on R2.")
    ap.add_argument("--only", default="", help="comma-separated addon folder names (default: every addon)")
    ap.add_argument("--tags", default=DEFAULT_TAGS, help=f"comma-separated build tags (default: {DEFAULT_TAGS})")
    ap.add_argument("--dry-run", action="store_true", help="list what would change and write nothing")
    ap.add_argument("--check", action="store_true", help="check the addons' files only, without R2")
    args = ap.parse_args(argv)

    try:
        addons = gather(SOURCE, split(args.only))
        log(f"{len(addons)} addon(s): " + ", ".join(f"{a.name} ({len(a.files)} files)" for a in addons))
        if args.check:
            return 0
        tags = split(args.tags)
        if not tags:
            raise Stop("no build tags")
        cfg = config_from_env()
        return publish(R2(cfg), cfg, addons, tags, args.dry_run, os.environ.get("GITHUB_STEP_SUMMARY"))
    except Stop as e:
        log(f"publish_r2: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
