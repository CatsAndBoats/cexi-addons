"""
Fetching addons from GitHub: what is newest upstream (resolve_latest_release,
resolve_branch_commit: helpers for finding a new pin; the publish path never calls
them), and exactly one pinned commit's files (fetch_commit: what main.py publishes).

fetch_commit asks git for the commit by its hash; git checks every object's hash as
it arrives, so it is that commit or the fetch fails. The files are then `git archive`
of it, built locally from those checked objects (the same files GitHub's zipball has,
the repo's export-ignore / export-subst applied), never a downloaded zipball.
"""

import base64
import fnmatch
import hashlib
import io
import posixpath
import re
import stat
import subprocess
import tempfile
import time
import zipfile

import requests

import config
import lua_meta
from util import AddonError, info


# ---------------------------------------------------------------------------
# GitHub API
# ---------------------------------------------------------------------------


def _session(token):
    s = requests.Session()
    s.headers.update(
        {
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "catseyexi-addon-updater",
        }
    )
    if token:
        s.headers["Authorization"] = f"Bearer {token}"
    return s


def _get(session, url, allow_404=False, stream=False, headers=None):
    last = None
    for attempt in range(1, config.HTTP_RETRIES + 1):
        try:
            response = session.get(url, timeout=config.HTTP_TIMEOUT, stream=stream, headers=headers)
        except requests.RequestException as exc:
            last = exc
            time.sleep(2 * attempt)
            continue

        if response.status_code == 404 and allow_404:
            return None
        if response.status_code == 200:
            return response

        # 403 with a zero remaining budget is a rate limit, not a permission problem.
        if response.status_code in (403, 429) and response.headers.get("X-RateLimit-Remaining") == "0":
            reset = int(response.headers.get("X-RateLimit-Reset", "0"))
            wait = max(0, reset - int(time.time())) + 5
            raise AddonError(f"GitHub rate limit exhausted; resets in {wait}s")

        last = AddonError(f"GET {url} returned HTTP {response.status_code}")
        if response.status_code < 500:
            break
        time.sleep(2 * attempt)

    raise AddonError(f"GitHub request failed for {url}: {last}")


def parse_repo(github_url):
    """Pull owner/repo out of a github.com URL."""
    match = re.match(
        r"^https?://(?:www\.)?github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+?)(?:\.git)?/?$",
        github_url.strip(),
    )
    if not match:
        raise AddonError(f"Not a parseable GitHub repo URL: {github_url!r}")
    return match.group(1), match.group(2)


def resolve_latest_release(token, owner, repo):
    """
    Return (tag_name, commit_sha, assets) for the repo's latest published release,
    or None when the repo has no release. assets is the release's list of uploaded
    files as GitHub gives it (name, url, size, ...), for pick_release_asset.

    The release payload's `target_commitish` is unreliable: for Sidekick it is the
    string "main" (a branch name), not a sha. So we resolve refs/tags/<tag> instead,
    dereferencing annotated tags to the commit they point at.
    """
    session = _session(token)

    response = _get(
        session,
        f"{config.GITHUB_API}/repos/{owner}/{repo}/releases/latest",
        allow_404=True,
    )
    if response is None:
        return None

    release = response.json()
    if release.get("draft") or release.get("prerelease"):
        return None

    tag = release.get("tag_name")
    if not tag:
        return None

    sha = _resolve_tag_sha(session, owner, repo, tag)
    return tag, sha, release.get("assets") or []


def resolve_branch_commit(token, owner, repo, branch, path=""):
    """
    Return the sha of the latest commit on `branch` that touched `path` (any commit
    when path is blank), for a repo that publishes no releases.

    Scoped to the addon's folder so a commit elsewhere in the repo (the next version's
    folder going up beside it, say) is not taken for a new release of this one.
    """
    session = _session(token)

    query = f"sha={requests.utils.quote(branch, safe='')}&per_page=1"
    if path:
        query += f"&path={requests.utils.quote(path, safe='/')}"
    commits = _get(session, f"{config.GITHUB_API}/repos/{owner}/{repo}/commits?{query}").json()

    sha = commits[0].get("sha") if commits else None
    if not sha:
        raise AddonError(f"No commit on branch {branch!r} touches {path!r}" if path else f"Branch {branch!r} has no commits")
    return sha


def _resolve_tag_sha(session, owner, repo, tag):
    ref = _get(
        session,
        f"{config.GITHUB_API}/repos/{owner}/{repo}/git/ref/tags/{requests.utils.quote(tag, safe='')}",
        allow_404=True,
    )
    if ref is None:
        raise AddonError(f"Release tag {tag!r} has no matching git ref")

    obj = ref.json().get("object", {})
    sha, kind = obj.get("sha"), obj.get("type")

    # Annotated tags point at a tag object; dereference it to reach the commit.
    if kind == "tag":
        tag_obj = _get(session, f"{config.GITHUB_API}/repos/{owner}/{repo}/git/tags/{sha}")
        obj = tag_obj.json().get("object", {})
        sha = obj.get("sha")

    if not sha:
        raise AddonError(f"Could not resolve tag {tag!r} to a commit sha")
    return sha


def download_zipball(token, owner, repo, ref):
    """Download the source zipball for a tag or commit sha and return its raw bytes."""
    url = f"{config.GITHUB_API}/repos/{owner}/{repo}/zipball/{requests.utils.quote(ref, safe='')}"
    return _download(_session(token), url, "Zipball")


def pick_release_asset(assets, pattern):
    """
    The one uploaded file of a release whose name matches `pattern` (addons.json
    "asset", a glob such as yunagearopt-*.zip; case doesn't matter). It must be a zip:
    an author's own build of the addon folder, for a repo that is the addon's source
    rather than the folder players install.
    """
    names = [a.get("name") or "" for a in assets]
    matches = [a for a in assets if fnmatch.fnmatch((a.get("name") or "").lower(), pattern.lower())]

    if not matches:
        have = ", ".join(sorted(n for n in names if n)) or "none"
        raise AddonError(f"No release asset matches {pattern!r} (the release has: {have})")
    if len(matches) > 1:
        raise AddonError(
            f"Ambiguous 'asset': {pattern!r} matches {len(matches)} uploads: "
            f"{', '.join(sorted(a['name'] for a in matches))}"
        )

    chosen = matches[0]
    if not chosen["name"].lower().endswith(".zip"):
        raise AddonError(f"Release asset {chosen['name']!r} is not a .zip")
    size = chosen.get("size") or 0
    if size > config.MAX_ADDON_BYTES:
        raise AddonError(
            f"Release asset {chosen['name']!r} is {size} bytes, over the {config.MAX_ADDON_BYTES} byte limit"
        )
    return chosen


def download_release_asset(token, asset):
    """Download one release asset (from pick_release_asset) and return its raw bytes."""
    # The asset's API url serves the file itself when asked for an octet stream (a
    # redirect to GitHub's CDN, which requests follows, dropping the token on the way).
    return _download(
        _session(token),
        asset["url"],
        f"Release asset {asset.get('name', '')!r}",
        headers={"Accept": "application/octet-stream"},
    )


def _download(session, url, what, headers=None):
    """GET a file in chunks, refusing one over MAX_ADDON_BYTES before it is all read."""
    response = _get(session, url, stream=True, headers=headers)

    chunks, total = [], 0
    for chunk in response.iter_content(chunk_size=1024 * 256):
        total += len(chunk)
        if total > config.MAX_ADDON_BYTES:
            raise AddonError(
                f"{what} exceeds the {config.MAX_ADDON_BYTES} byte limit; refusing to unpack"
            )
        chunks.append(chunk)

    return b"".join(chunks)


# ---------------------------------------------------------------------------
# Archive unpacking
# ---------------------------------------------------------------------------


BACKSLASH = "\\"


def _is_unsafe_entry(name):
    """
    Reject anything that could escape the extraction root.

    The staging directory is a real directory on disk, so zip-slip is a genuine
    concern rather than a theoretical one.
    """
    if not name or name.startswith("/") or name.startswith(BACKSLASH):
        return "absolute path"
    if ":" in name.split("/")[0]:
        return "drive-qualified path"
    if BACKSLASH in name:
        return "backslash in archive path"
    if any(part == ".." for part in name.split("/")):
        return "parent-directory traversal"
    return None


def extract_release(zip_bytes, lua_filename, path=""):
    """
    Unpack the zipball and return (addon_root, {relative_path: bytes}).

    GitHub zipballs are wrapped in a single generated directory such as
    `seekey13-Sidekick-1c485f7/`, and the addon itself may sit deeper still
    (`Addon-v2.32/Addon.lua`). We locate the entry-point lua and treat its parent
    directory as the addon root, so everything is stored relative to that.

    path (addons.json "path", relative to the repo root) limits where the lua is
    looked for, so a repo holding several copies of the addon (one folder per
    version) publishes the one named.
    """
    archive = zipfile.ZipFile(io.BytesIO(zip_bytes))
    entries = [i for i in archive.infolist() if not i.is_dir()]

    for item in entries:
        reason = _is_unsafe_entry(item.filename)
        if reason:
            raise AddonError(f"Unsafe archive entry ({reason}): {item.filename!r}")

        # Symlinks are stored as regular entries whose content is the target path.
        # Publishing one would let an addon point at an arbitrary file.
        mode = item.external_attr >> 16
        if mode and stat.S_ISLNK(mode):
            raise AddonError(f"Archive contains a symlink: {item.filename!r}")

    root = _find_addon_root(entries, lua_filename, path)

    prefix = f"{root}/" if root else ""
    files = {}
    for item in entries:
        if prefix and not item.filename.startswith(prefix):
            continue
        relative = item.filename[len(prefix):]
        if not relative:
            continue
        files[relative] = archive.read(item)

    if not files:
        raise AddonError(f"No files found under the addon root {root!r}")

    return root, files


def _find_addon_root(entries, lua_filename, path=""):
    """Find the directory holding the addon's entry-point lua (under path, when given)."""
    names = [i.filename for i in entries]
    wrapper = ""
    if path and names:
        # path is relative to the repo root, which is inside the zipball's wrapper.
        wrapper = names[0].split("/")[0] + "/"
        names = [n[len(wrapper):] for n in names if n.startswith(wrapper)]

    found, also_deeper = _locate_lua(names, lua_filename, path)

    root = wrapper + posixpath.dirname(found)
    if also_deeper:
        info(f"    note: {lua_filename} also appears deeper in the tree; using root {root!r}")
    return root


def _locate_lua(paths, lua_filename, path=""):
    """
    Return (lua_path, also_deeper) for the entry-point lua among `paths`, only
    looking under the folder `path` when it is given.

    Picks the shallowest match so a vendored copy deeper in the tree cannot win.
    A tie is ambiguous and is treated as an error rather than guessed at.
    """
    target = lua_filename.lower()
    scope = f"{path}/" if path else ""
    matches = [p for p in paths if p.startswith(scope) and posixpath.basename(p).lower() == target]

    if not matches:
        where = f"under {path!r} (has the addon moved? update its 'path' in addons.json)" if path else "anywhere in the release"
        raise AddonError(f"Entry-point lua {lua_filename!r} not found {where}")

    shallowest = min(m.count("/") for m in matches)
    candidates = [m for m in matches if m.count("/") == shallowest]

    if len(candidates) > 1:
        raise AddonError(
            f"Ambiguous addon root: {lua_filename!r} appears at the same depth in "
            f"{len(candidates)} places: {', '.join(sorted(candidates))}"
        )

    return candidates[0], len(matches) > 1


# ---------------------------------------------------------------------------
# A pinned commit, fetched and checked by git
# ---------------------------------------------------------------------------


SHA_RE = re.compile(r"^[0-9a-f]{40}$")


def is_sha(value):
    return bool(SHA_RE.match(value or ""))


def _git(cwd, *args, data=False):
    result = subprocess.run(
        ["git", "-c", "advice.detachedHead=false", *args], cwd=cwd, capture_output=True, timeout=config.HTTP_TIMEOUT * 5
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip().splitlines()
        verb = next((a for a in args if not a.startswith("-") and "=" not in a), "?")
        raise AddonError(f"git {verb} failed: {detail[-1] if detail else 'exit ' + str(result.returncode)}")
    return result.stdout if data else result.stdout.decode("utf-8", errors="replace")


def archive_files(repo_dir, sha, wrapper, lua_filename, path=""):
    """
    (addon_root, {relative path: bytes}) of the commit `sha` in the local repo at
    repo_dir: `git archive` of it, unpacked by extract_release. git builds the archive
    from the objects it has already checked, applying the repo's own export-ignore /
    export-subst as GitHub's zipball does, so the files are the ones the zipball had,
    without trusting where a zipball came from.
    """
    data = _git(repo_dir, "archive", "--format=zip", f"--prefix={wrapper}/", sha, data=True)
    if len(data) > config.MAX_ADDON_BYTES:
        raise AddonError(f"The archive of {sha[:7]} exceeds the {config.MAX_ADDON_BYTES} byte limit")
    return extract_release(data, lua_filename, path)


def fetch_commit(token, owner, repo, sha, lua_filename, path=""):
    """
    The addon's files at exactly the commit `sha` of github.com/owner/repo, fetched
    by git (which checks each object's hash) and confirmed to be that commit before
    a byte is read. Anything else fails closed.
    """
    if not is_sha(sha):
        raise AddonError(f"Not a full commit hash: {sha!r}")
    with tempfile.TemporaryDirectory(prefix="addon-") as work:
        _git(work, "init", "-q")
        url = f"https://github.com/{owner}/{repo}.git"
        # As actions/checkout sends it: git over HTTPS takes the token as Basic auth.
        basic = base64.b64encode(f"x-access-token:{token}".encode()).decode()
        auth = ["-c", f"http.https://github.com/.extraheader=AUTHORIZATION: basic {basic}"] if token else []
        env_free = ["-c", "credential.helper=", "-c", "core.askPass=true"]
        _git(work, *auth, *env_free, "fetch", "-q", "--depth=1", "--no-tags", url, sha)
        fetched = _git(work, "rev-parse", "FETCH_HEAD").strip()
        if fetched != sha:
            raise AddonError(f"Asked git for {sha[:12]} and got {fetched[:12]}; publishing nothing")
        if _git(work, "cat-file", "-t", sha).strip() != "commit":
            raise AddonError(f"{sha[:12]} is not a commit")
        return archive_files(work, sha, f"{owner}-{repo}-{sha[:7]}", lua_filename, path)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def resolve_release(token, owner, repo, tag):
    """(tag, commit sha, assets) of the release named `tag`, for a pinned asset entry."""
    session = _session(token)
    response = _get(
        session,
        f"{config.GITHUB_API}/repos/{owner}/{repo}/releases/tags/{requests.utils.quote(tag, safe='')}",
        allow_404=True,
    )
    if response is None:
        raise AddonError(f"No release tagged {tag!r}")
    release = response.json()
    return tag, _resolve_tag_sha(session, owner, repo, tag), release.get("assets") or []


# ---------------------------------------------------------------------------
# Version lookup (run summary)
# ---------------------------------------------------------------------------


def fetch_lua_version(token, owner, repo, sha, lua_filename, path=""):
    """
    addon.version of the entry-point lua at a commit, or "" when it declares none.

    Used for the run summary, so an addon that is already up to date can still
    report its version: one tree listing and one blob, no zipball download.
    """
    session = _session(token)

    tree = _get(session, f"{config.GITHUB_API}/repos/{owner}/{repo}/git/trees/{sha}?recursive=1")
    blobs = {i["path"]: i["sha"] for i in tree.json().get("tree", []) if i.get("type") == "blob"}
    found, _ = _locate_lua(blobs, lua_filename, path)

    blob = _get(session, f"{config.GITHUB_API}/repos/{owner}/{repo}/git/blobs/{blobs[found]}")
    data = base64.b64decode(blob.json().get("content", ""))

    head = data[: config.LUA_METADATA_SCAN_BYTES].decode("utf-8", errors="replace")
    return lua_meta.get(head, "addon.version").strip()
