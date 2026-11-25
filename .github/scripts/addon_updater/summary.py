"""
The run summary: which addons released this run, and the version every addon is at.

Written as Markdown to $GITHUB_STEP_SUMMARY, so it shows on the run's page in
Actions, and printed to the log as well.

Building it never fails the run. A version that cannot be looked up shows as "?".
"""

import os
from urllib.parse import quote

import sources
from util import info, step, warn

# What happened to one addon this run.
NOT_CHECKED = "not_checked"   # left out by --only
NO_RELEASE = "no_release"
UP_TO_DATE = "up_to_date"
FAILED = "failed"
STAGED = "staged"             # new release vetted, but the run stopped before publishing
PUBLISHED = "published"       # files uploaded
METADATA_ONLY = "metadata"    # only its launcher.json entry changed
UNCHANGED = "unchanged"       # release moved, but no published file changed

RELEASED = (STAGED, PUBLISHED, METADATA_ONLY, UNCHANGED)


class AddonRow:
    def __init__(self, entry):
        self.name = entry.get("name") or "<unnamed>"
        self.github = (entry.get("github") or "").strip()
        self.lua = entry.get("lua") or f"{self.name}.lua"
        self.branch = (entry.get("branch") or "").strip()  # set for a repo tracked without releases
        self.path = (entry.get("path") or "").strip().strip("/")
        self.known_sha = (entry.get("commit") or "").strip()  # what is live at the start (main.py sets it from R2)
        self.status = NOT_CHECKED
        self.tag = None           # latest release, once checked
        self.sha = None
        self.version = None       # addon.version of that release, once vetted
        self.planned = None       # PUBLISHED / METADATA_ONLY / UNCHANGED, once diffed
        self.files = None         # (added, changed, removed) counts
        self.reason = None        # why it failed
        self.old_version = None   # filled in by resolve_versions
        self.live_version = None

    @property
    def forced(self):
        return self.sha is not None and self.sha == self.known_sha


class Report:
    def __init__(self, entries, dry_run=False, force=False, only=()):
        self.rows = [AddonRow(e) for e in entries]
        self.dry_run = dry_run
        self.force = force
        self.only = sorted(only)
        self.stopped = None       # why the run ended early, if it did

    def published(self):
        """The publish went through: each vetted release takes the outcome planned for it."""
        for row in self.rows:
            if row.status == STAGED and row.planned:
                row.status = row.planned

    def live_sha(self, row):
        """The commit players have once this run is over."""
        if row.status in (PUBLISHED, METADATA_ONLY, UNCHANGED) and not self.dry_run:
            return row.sha
        return row.known_sha


# ---------------------------------------------------------------------------
# Versions
# ---------------------------------------------------------------------------


def resolve_versions(report, token):
    """Look up addon.version for every live commit and every release's previous one."""
    cache = {}

    def lookup(row, sha):
        if not sha:
            return None
        if sha == row.sha and row.version:
            return row.version
        key = (row.github.lower(), sha)
        if key not in cache:
            try:
                owner, repo = sources.parse_repo(row.github)
                cache[key] = sources.fetch_lua_version(token, owner, repo, sha, row.lua, row.path) or "?"
            except Exception as exc:  # noqa: BLE001 - the summary must not fail the run
                warn(f"Summary: could not read {row.name}'s version at {sha[:7]}: {exc}")
                cache[key] = "?"
        return cache[key]

    for row in report.rows:
        row.live_version = lookup(row, report.live_sha(row))
        if row.status in RELEASED:
            row.old_version = lookup(row, row.known_sha)


# ---------------------------------------------------------------------------
# Markdown
# ---------------------------------------------------------------------------


def render(report):
    released = [r for r in report.rows if r.status in RELEASED]
    failed = [r for r in report.rows if r.status == FAILED]

    lines = ["## Addon Updater", "", _headline(report, released, failed), ""]

    notes = []
    if report.dry_run:
        notes.append("Dry run: nothing was uploaded or committed.")
    if report.force:
        notes.append("Forced: releases that were already published were re-checked.")
    if report.only:
        notes.append(f"Only: {', '.join(report.only)}.")
    if report.stopped:
        notes.append(f"**Stopped early:** {_cell(report.stopped)}")
    if notes:
        lines += [f"> {n}" for n in notes] + [""]

    if released:
        lines += [
            "### New releases",
            "",
            "| Addon | Version | Release | Result |",
            "| --- | --- | --- | --- |",
        ]
        for row in released:
            lines.append(
                f"| {_addon_link(row)} | {_version_change(row)} | {_tag_link(row)} | "
                f"{_result(report, row)} |"
            )
        lines.append("")

    if failed:
        lines += [
            "### Failed",
            "",
            "| Addon | Release | Reason |",
            "| --- | --- | --- |",
        ]
        for row in failed:
            lines.append(f"| {_addon_link(row)} | {_tag_link(row)} | {_cell(row.reason or '')} |")
        lines.append("")

    lines += [
        "### All addons",
        "",
        "| Addon | Version | Commit | Pinned | Status |",
        "| --- | --- | --- | --- | --- |",
    ]
    for row in report.rows:
        live = report.live_sha(row)
        version = _cell(row.live_version) if live else "not published"
        lines.append(
            f"| {_addon_link(row)} | {version} | {_commit_link(row, live)} | "
            f"{_tag_link(row)} | {_status(report, row)} |"
        )

    return "\n".join(lines) + "\n"


def _headline(report, released, failed):
    new = [r for r in released if not r.forced]
    if new:
        noun = "release" if len(new) == 1 else "releases"
        listed = ", ".join(f"{r.name} {r.version}" for r in new)
        text = f"**{len(new)} new {noun}:** {_cell(listed)}"
    else:
        text = "**No new releases.**"

    if failed:
        text += f" **{len(failed)} failed.**"
    return text


def _version_change(row):
    new = f"**{_cell(row.version)}**"
    if not row.known_sha:
        return f"{new} (new addon)"
    if row.old_version and row.old_version != row.version:
        return f"{_cell(row.old_version)} → {new}"
    return new


def _result(report, row):
    if row.status == STAGED:
        text = "Not published: the run stopped first"
    elif row.status == PUBLISHED:
        text = f"{'Would publish' if report.dry_run else 'Published'}: {_file_counts(row.files)}"
    elif row.status == METADATA_ONLY:
        text = "Launcher entry " + ("would be updated" if report.dry_run else "updated") + ", no file changes"
    else:
        text = "Nothing published: no file changed"

    if row.forced:
        text += " (forced re-check)"
    return text


def _status(report, row):
    if row.status == NOT_CHECKED:
        return "Not checked"
    if row.status == NO_RELEASE:
        return "No GitHub release"
    if row.status == UP_TO_DATE:
        return "Up to date"
    if row.status == FAILED:
        return "Failed"
    if row.status == STAGED:
        return "New release not published"
    if row.status == UNCHANGED:
        return "Up to date (new release, same files)"
    if not row.known_sha:
        return f"Would add {_cell(row.version)}" if report.dry_run else "Added"
    if report.dry_run:
        return f"Would update to {_cell(row.version)}"
    return "Updated"


def _file_counts(files):
    added, changed, removed = files or (0, 0, 0)
    parts = [
        f"{count} {word}"
        for count, word in ((added, "added"), (changed, "changed"), (removed, "removed"))
        if count
    ]
    return ", ".join(parts) if parts else "no file changes"


def _repo_url(row):
    url = row.github.rstrip("/")
    return url[:-4] if url.endswith(".git") else url


def _addon_link(row):
    return f"[{_cell(row.name)}]({_repo_url(row)})" if row.github else _cell(row.name)


def _tag_link(row):
    if not row.tag:
        return "—"
    if row.branch:
        # No release page to link to: the addon's folder at the commit instead.
        folder = f"/{quote(row.path, safe='/')}" if row.path else ""
        return f"[{_cell(row.tag)}]({_repo_url(row)}/tree/{row.sha}{folder})"
    return f"[{_cell(row.tag)}]({_repo_url(row)}/releases/tag/{quote(row.tag, safe='')})"


def _commit_link(row, sha):
    if not sha:
        return "—"
    return f"[`{sha[:7]}`]({_repo_url(row)}/commit/{sha})" if row.github else f"`{sha[:7]}`"


def _cell(text):
    """Keep a value inside its table cell."""
    return str(text if text is not None else "?").replace("|", "\\|").replace("\r", " ").replace("\n", " ")


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------


def publish(report, token):
    """Write the summary to the run page and the log. Never raises."""
    try:
        resolve_versions(report, token)
        text = render(report)
    except Exception as exc:  # noqa: BLE001 - the summary must not fail the run
        warn(f"Could not build the run summary: {exc}")
        return

    step("Summary")
    info(text)

    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        try:
            with open(path, "a", encoding="utf-8") as fh:
                fh.write(text)
        except OSError as exc:
            warn(f"Could not write the run summary: {exc}")
