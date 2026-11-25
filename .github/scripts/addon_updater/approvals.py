"""
The publish-time approval check: a pinned commit in addons.json goes to players only
when a person other than its author approved it in a pull request.

A pin passes when it equals what is already published (R2's record), or when:
  1. the commit on main that set this entry's "commit" to the pin was merged from a
     pull request into main,
  2. that pull request was approved by a code owner of addons.json (.github/CODEOWNERS)
     who is not its author and not a bot,
  3. that approval was given on the pull request's final head, and
  4. addons.json at that head pins this entry to the same commit.

Anything else is refused: a pin pushed straight to main, an approval given before a
later push, a pull request that pinned something else. This is what makes the pull
requests that move a pin a real gate, without asking every other change on main to
go through review.
"""

import base64
import json
import subprocess

import requests

import config
from util import AddonError, info

CODEOWNERS = ".github/CODEOWNERS"


def _git(repo_root, *args):
    result = subprocess.run(["git", *args], cwd=repo_root, capture_output=True, text=True)
    if result.returncode != 0:
        raise AddonError(f"git {args[0]} failed: {result.stderr.strip()[-200:]}")
    return result.stdout


def owners_of(codeowners_text, path="addons.json"):
    """GitHub users (not teams) that CODEOWNERS names for `path`; the last matching line wins, as on GitHub."""
    owners = []
    for line in codeowners_text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        pattern, *names = line.split()
        if pattern.lstrip("/") == path:
            owners = [n[1:].lower() for n in names if n.startswith("@") and "/" not in n]
    return owners


def pin_at(repo_root, rev, name):
    """The "commit" addons.json pins `name` to at revision `rev` ("" when absent)."""
    try:
        raw = _git(repo_root, "show", f"{rev}:addons.json")
    except AddonError:
        return ""
    return pin_in(raw, name)


def pin_in(raw_json, name):
    try:
        entries = json.loads(raw_json)
    except ValueError:
        return ""
    for entry in entries if isinstance(entries, list) else []:
        if isinstance(entry, dict) and entry.get("name") == name:
            return (entry.get("commit") or "").strip()
    return ""


def introducing_commit(repo_root, name, pin):
    """
    The commit on main's first-parent line that set `name`'s pin to `pin`: the oldest
    of the run of commits, from HEAD back, that all pin it there.
    """
    revs = _git(repo_root, "rev-list", "--first-parent", "HEAD", "--", "addons.json").split()
    if not revs or pin_at(repo_root, "HEAD", name) != pin:
        raise AddonError(f"addons.json at HEAD doesn't pin {name} to {pin[:7]}")
    found = None
    for rev in revs:
        if pin_at(repo_root, rev, name) != pin:
            break
        found = rev
    # Belt and braces: the commit's own first parent must pin something else.
    if found and pin_at(repo_root, f"{found}^", name) == pin:
        raise AddonError(f"can't tell which commit pinned {name} to {pin[:7]}")
    return found


class GitHub:
    def __init__(self, token, repository):
        self.repository = repository
        self.session = requests.Session()
        self.session.headers.update({
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "catseyexi-addon-updater",
        })
        if token:
            self.session.headers["Authorization"] = f"Bearer {token}"

    def get(self, path):
        response = self.session.get(f"{config.GITHUB_API}/repos/{self.repository}/{path}", timeout=config.HTTP_TIMEOUT)
        if response.status_code != 200:
            raise AddonError(f"GitHub {path.split('?')[0]} returned HTTP {response.status_code}")
        return response.json()

    def pages(self, path):
        out, page = [], 1
        while True:
            sep = "&" if "?" in path else "?"
            chunk = self.get(f"{path}{sep}per_page=100&page={page}")
            out += chunk
            if len(chunk) < 100:
                return out
            page += 1

    def file_at(self, path, ref):
        data = self.get(f"contents/{path}?ref={ref}")
        return base64.b64decode(data.get("content", "")).decode("utf-8-sig")


def check_pull(gh, pull, name, pin, owners):
    """None when `pull` is a valid approval of `name` at `pin`, else the reason it isn't."""
    number = pull["number"]
    if not pull.get("merged_at"):
        return f"#{number} isn't merged"
    if (pull.get("base") or {}).get("ref") != "main":
        return f"#{number} didn't merge into main"
    author = ((pull.get("user") or {}).get("login") or "").lower()
    head = (pull.get("head") or {}).get("sha") or ""
    if pin_in(gh.file_at("addons.json", head), name) != pin:
        return f"#{number}'s head doesn't pin {name} to {pin[:7]}"

    latest = {}
    for review in gh.pages(f"pulls/{number}/reviews"):
        login = ((review.get("user") or {}).get("login") or "").lower()
        if review.get("state") in ("APPROVED", "CHANGES_REQUESTED", "DISMISSED"):
            latest[login] = review
    approvers = [
        login for login, review in latest.items()
        if review.get("state") == "APPROVED"
        and review.get("commit_id") == head
        and login in owners
        and login != author
        and not login.endswith("[bot]")
    ]
    if not approvers:
        return f"#{number} has no approval of its final head by a code owner of addons.json other than its author"
    info(f"    approved in #{number} by {', '.join(approvers)}")
    return None


def check(repo_root, token, repository, name, pin):
    """Raise AddonError unless `name`'s pin `pin` came through an approved pull request."""
    try:
        owners = owners_of(open(f"{repo_root}/{CODEOWNERS}", encoding="utf-8").read())
    except OSError:
        owners = []
    if not owners:
        raise AddonError(f"{CODEOWNERS} names nobody for addons.json, so no pin can be approved")

    commit = introducing_commit(repo_root, name, pin)
    gh = GitHub(token, repository)
    reasons = []
    for pull in gh.get(f"commits/{commit}/pulls"):
        reason = check_pull(gh, gh.get(f"pulls/{pull['number']}"), name, pin, owners)
        if reason is None:
            return
        reasons.append(reason)
    why = "; ".join(reasons) or "no pull request merged it"
    raise AddonError(f"pin {pin[:7]} (set in {commit[:7]}) wasn't approved: {why}")

