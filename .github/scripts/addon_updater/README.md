# Addon Updater

Publishes Ashita and VanaCore addons to R2 from **pinned commits** of their GitHub
repositories, so addons can be added or updated without rebuilding the whole client
download, and nothing an addon's author pushes reaches players until a person here
approves it.

One workflow, **Addon Updater** (`addon_updater.yaml`, `main.py`):

| | |
| --- | --- |
| When | On a push to main that changes `addons.json`, or by hand |
| Upstream | Never looks: publishes the pin. Nothing checks for newer versions; a pin is moved by hand in a pull request ([Updating an addon](#updating-an-addon)) |
| Fetch | The pinned commit, by its hash, checked by git |
| Checks | File rules, lua header, ClamAV |
| Writes | R2 (files, `launcher.json`, manifests, `launcher/addons_published.json`). Never the repository |
| Secrets | R2's and Cloudflare's |

## Pins, approvals and what is checked

- `commit` in `addons.json` is the pin: a full 40-character hash. An entry without one
  is refused. Release entries also carry `tag` (a label); an `asset` entry also carries
  `asset_sha256`, the hash of the release's zip, since that zip isn't in git.
- **Fetching.** `sources.fetch_commit` asks git for exactly that commit
  (`git fetch --depth=1 <url> <sha>`; GitHub serves any reachable commit by hash),
  confirms `FETCH_HEAD` is it, and takes the files from `git archive` of it, built
  locally from objects git has already checked. The files are the ones GitHub's zipball
  has (the repo's `export-ignore` / `export-subst` applied: checked identical for every
  addon when this was built), but nothing downloaded is trusted. Downloading a zipball
  by tag name, which could move between resolving and downloading, is gone.
- **Approval.** A pin that isn't live yet (`launcher/addons_published.json` on R2) is
  published only when `approvals.py` finds that the commit on main which set it was
  merged from a pull request, approved on its final head by someone `.github/CODEOWNERS`
  names for `addons.json` who isn't the pull request's author, and that head pins the
  same commit. A pin pushed straight to main, or approved before a later push, is
  refused and the run goes red. Other pushes to main are unaffected.
- **Approving an update** is reviewing the pull request that moves the pin: the upstream
  compare from the old pin to the new one and the files changed under the addon's folder.
  Don't auto-merge them: that would remove the person this is all for.
- **The first run** of this version has no record of what is live: run Addon Updater by
  hand with `adopt`, which records the current pins as live and publishes nothing.

### Known gap: R2 to the player

All of this protects GitHub → R2. Nothing protects R2 → player: anyone with R2 write
access can replace any file, and the launcher checks files against the manifest's SHA-1
cut to 6 hex characters (`util.file_hash`, mirroring the launcher's `Utils.GetFileHash`),
which catches corruption, not tampering. The R2 keys are repository secrets of a private
repository on the Team plan, where environments can't require a reviewer, so any
workflow on main can read them. Accepted for now; closing it means signed manifests
checked by the launcher, or an Enterprise plan for reviewer-gated environments.

## Where addons are published

Each addon goes to the builds in `config.TARGETS` that take it, from one download and one virus scan:

| Build (tag/name) | Takes | Addons land in | Manifest |
| --- | --- | --- | --- |
| `main/ashita` | every addon | `builds/main/Ashita/addons/<addon>/` | `build_main_ashita.gz` |
| `vanacore/vanacore` | only addons with `"vanacore": true` | `builds/vanacore/VanaCore/addons/ashita/<addon>/` | `build_vanacore_vanacore.gz` |
| `vanacore/vanacore` | VanaCore native addons (`"native": true`), and only this build | `builds/vanacore/VanaCore/addons/vanacore/<addon>/` | `build_vanacore_vanacore.gz` |

Each build keeps its own `updated` timestamp and its own `recent_updates` /
`recent_deletes` list in `launcher.json`, and only a build whose files changed is
bumped or has its manifest rewritten.

- `main/ashita` is required: if it is missing the run stops with R2 untouched.
- `vanacore/vanacore` is optional: if its manifest or `launcher.json` entry is gone the
  run warns and carries on with `main`.
- The launcher treats `addons\ashita\` in the vanacore build as the player's once a file
  exists (`VanaCore.PlayerPaths`): the build installs it when missing and never replaces
  it, and the launcher's own Ashita mirror keeps it current. So the vanacore push seeds
  new installs; it does not overwrite anyone's copy.
- **`recent_deletes` is the exception.** The launcher deletes every path in a build's
  `recent_deletes` on every check, with no `PlayerPaths` test, and downloads it again if
  the manifest still has it. So an addon that doesn't set `"vanacore": true` is dropped
  from the vanacore manifest and taken out of its `recent_updates` and `recent_deletes`
  (`state.forget_recent`), never added to `recent_deletes`: players keep their VanaCore
  copy, which the Ashita mirror keeps current.
- **Forced deletes** (`config.FORCED_DELETES`) are the other exception: paths under the
  Ashita addons folder (`Sidekick\lib\core\afk.lua`) that every run reaching R2 puts in
  each build's `recent_deletes` (`addons\` in main, `addons\ashita\` in vanacore) before
  it writes `launcher.json`, and `forget_recent` leaves there. The Ashita mirror copies
  what the launcher downloads for Ashita but never deletes, so VanaCore's copy keeps the
  files an addon dropped; this list clears them. A path any build ships again is left out
  with a warning. It holds Sidekick 3.0.0's old `lib\` for now. To put it on R2 when no
  addon has released, run with `force` and `only: Sidekick`: launcher.json alone is written.
- Dropping an addon from the vanacore build happens on a run that reaches R2, so after
  turning `vanacore` off for an addon (or on the first run with this rule) **run once with
  `force`**.
- An addon is skipped when its release commit matches `addons.json`, so the **first run
  after adding a target needs `force`** to backfill addons that have not released since.
  It only uploads files the build does not already have.

## Required secrets

| Secret | Value |
| --- | --- |
| `R2_S3_ENDPOINT` | `https://<account id>.r2.cloudflarestorage.com` |
| `R2_ACCESS_KEY_ID` | R2 access key |
| `R2_SECRET_ACCESS_KEY` | R2 secret key |
| `R2_BUCKET` | the bucket's name |
| `CLOUDFLARE_ZONE_ID` | *optional* — CDN purge for `launcher.json` and the manifest |
| `CLOUDFLARE_API_TOKEN` | *optional* — as above |

`GITHUB_TOKEN` is supplied automatically. The job needs `contents: write` to push the
updated `addons.json` back.

Without the two Cloudflare secrets the purge step logs a line and does nothing.
That is survivable: `launcher.json` and the manifest are already fetched with random
cache-busters, and build files are busted by `builds[main/ashita].updated`.

## Adding an addon

Append an entry to [`addons.json`](../../../addons.json) in a pull request, pinned to the
commit to publish. A code owner other than you approves; merging it publishes.

```json
{
    "name": "Sidekick",
    "github": "https://github.com/seekey13/Sidekick",
    "tag": "3.1.4",
    "install": "Sidekick",
    "lua": "Sidekick.lua",
    "commit": "<the full 40-character hash of the commit tag 3.1.4 points at>"
}
```

- `install` is the folder created under `addons\`. It **must** match `lua` without the
  extension — the launcher discovers addons as `addons/<Folder>/<Folder>.lua`, so a
  mismatch means the addon never appears in the client.
- Add `"vanacore": true` to publish it to the vanacore build as well (only Yuna's
  addons do). Without it VanaCore gets the addon from the launcher's Ashita mirror.
- `commit` must be the full hash: Addon Updater refuses an unpinned entry or a short one.
  `tag` is a label for a release entry (an `asset` entry's release must be at the pinned
  commit).

### Updating an addon

Nothing checks upstream for new versions. To update an addon, open a pull request that
changes only its entry:

- `commit`: the new full hash (for a release, the commit its tag points at; for a
  `branch` entry, the latest commit on that branch that touched `path`), and `tag` for a
  release.
- An `asset` entry also needs `asset_sha256`: the SHA-256 of the release's zip.
- Review `https://github.com/<owner>/<repo>/compare/<old pin>...<new pin>` before
  approving.

### A VanaCore native addon

An addon written to VanaCore's own addon API (`vana.*`) runs from `addons\vanacore\` and
can't run on Ashita. Mark it `"native": true`: it goes only to the vanacore build, into
`addons/vanacore/<addon>/`, whatever `vanacore` says, and whatever either build held of it
under its Ashita addons folder is dropped from the manifest (players keep that copy).
CatsAndBoats/VanaCore's `.github/scripts/push_build.py` `EXTERNAL` must name its folder, or the next VanaCore release
would remove it from R2 as a file the package doesn't have, and the vcdev build
(VanaCore's test build, which copies `EXTERNAL` from vanacore at each release) wouldn't get it.

### An addon that updates itself in game

Some addons fetch their own releases (yunagearopt since 1.1.85: open `/ygo`, press UPDATE).
A player who updates that way is newer than the build until its new pin is merged and
published, and the launcher would put the build's older files back on every
check. Mark the addon `"self_update": true`:

- Its `launcher.json` entry carries `su`, the version this run published (from the lua's
  `addon.version`). `v` stays null.
- The launcher (`Cloudflare.IsSelfUpdatedAddonFile`) reads the installed copy's
  `addon.version` from `<install>\<install>.lua` and, when it's newer than `su`, leaves every
  file of the addon alone, `recent_deletes` included. The same version or an older one, or
  no lua, is updated as any other addon, so a player who never updates in game still gets
  each release we publish, and a broken copy at our version is still repaired.
- It covers `addons\<addon>\` in `main/ashita` and `addons\vanacore\<addon>\` in
  `vanacore/vanacore` (its `addons\ashita\` is the player's already).
- Turning it on (or off) for an addon whose pin is already live: **run once with `force`
  and `only: <addon>`**, which writes `launcher.json` alone. Launchers older than the
  `su` rule ignore it and behave as before.
- There's no detecting it: when an addon starts updating itself (a GitHub releases URL and
  file writes in its lua), add the flag by hand.

### From a release asset (the author's own build)

Some repos are the addon's source, not the folder players install: the release carries
a zip the author builds. Name it with `asset`, a glob over the release's uploads that must
match exactly one `.zip`; the source zipball is then left alone:

```json
{
    "name": "Demo",
    "github": "https://github.com/acme/Demo",
    "asset": "Demo-*.zip",
    "tag": "v1.0",
    "asset_sha256": "<the SHA-256 of the release's zip>",
    "install": "Demo",
    "lua": "Demo.lua",
    "commit": "<the full hash of the commit tag v1.0 points at>"
}
```

- The zip is unpacked and vetted like a zipball: the folder holding `lua` is the addon
  root, and that lua must carry the `addon.*` header.
- `asset` can't go with `branch` (no release to take it from) or `path` (the asset is the
  addon's folder already).
- yunagearopt needed this for 1.1.53, when its repo held the source (`native/build.py`
  put its VanaCore loader at the zip's root and the repo's `yunagearopt.lua` beside it as
  `core.lua`); since 1.1.54 the repo is laid out as the zip, so it takes the zipball.

### From a branch (repo without releases)

Some repos never publish a release, only commit the addon's files. Name the branch, and
the folder the addon lives in with `path` (relative to the repo root):

```json
{
    "name": "Goldilox",
    "github": "https://github.com/ChadBrowick/Goldilox-Vanacore",
    "branch": "main",
    "path": "Goldilox-v3.6/Goldilox",
    "install": "Goldilox",
    "lua": "Goldilox.lua",
    "vanacore": true,
    "commit": "<the full hash of a commit on main that touched the path>"
}
```

- A commit on `branch` that touched `path` stands in for a release: pin a newer one to
  update. A commit elsewhere in the repo is not a new release.
- Everything else (vetting, the virus scan, the diff, `vanacore`) is as for a release.
  The run summary shows it as `main@<sha>`, linked to the folder at that commit.
- `path` is optional, but it is what picks the right copy in a repo that keeps one
  folder per version: without it two `Goldilox.lua` at the same depth are ambiguous
  and the addon fails. **When the author starts a new folder** (`Goldilox-v3.7/...`),
  update `path`; if the old folder is deleted first the addon fails, saying so.
- `path` works on a release addon too, to pick its folder inside the release.

## Inputs

| Input | Effect |
| --- | --- |
| `dry_run` | Fetch, vet and scan, print what would happen, upload nothing |
| `force` | Re-publish even when the pin is already live (still uploads only changed files) |
| `only` | Comma-separated addon names, e.g. `Sidekick,HXUI` |
| `skip_clamav` | Skip the virus scan — only when the ClamAV mirrors are refusing to update |
| `adopt` | First run only: record the current pins as live, publish nothing |

## Run summary

Every run writes a summary to its page in Actions (and to the end of the log), even
when it fails or stops early:

- **New releases**: each addon that released, its version before → after, and what
  was published (files added / changed / removed).
- **Failed**: each addon that was quarantined, and why.
- **All addons**: the version players have of every addon after the run, its commit,
  the latest release on GitHub, and whether it is up to date.

Versions come from each addon's `addon.version` at the published commit, looked up
through the GitHub API (one tree listing and one blob per addon), so up-to-date addons
report their version without downloading anything. A lookup that fails shows `?` and
never fails the run. The code is in `summary.py`.

## What a run does

Strictly two phases. Nothing remote is written until phase one has fully succeeded.

**Phase one — gather (no remote writes)**

1. Read `launcher/addons_published.json` from R2: what is live.
2. Refuse an entry whose `commit` isn't a full hash.
3. Skip the addon if its pin is already live.
4. Run the approval check (above) on the new pin.
5. Fetch the pinned commit by hash, confirm it, and unpack `git archive` of it,
   rejecting absolute paths, `..` traversal, backslash paths and symlinks. (An `asset`
   entry: the release `tag` must be at the pin, and the zip must hash to `asset_sha256`.)
6. Locate the entry-point lua (under `path`, when set) and treat its parent as the
   addon root, so `Addon-v2.32/Addon.lua` stages as `addons/Addon/Addon.lua`.
7. Drop dotfiles and repo furniture; check everything else against the extension
   allow-list and the size limits.
8. Vet the lua's `addon.name` / `author` / `version` / `desc` header. No header, no publish.
9. Stage to `.addon-staging/` and run ClamAV over the whole tree.

**Phase two — publish**

10. Read `launcher.json` and every target's manifest (`build_main_ashita.gz`,
   `build_vanacore_vanacore.gz`) **through S3**, not the public URL, so a stale CDN copy
   can never be written back over the manager's work.
11. Hash every staged file and diff against each manifest. Only genuine changes upload.
12. Upload in this order, which matters:
    - addon files — the bytes must exist before anything points at them
    - `launcher.json` — carries each changed build's new `updated` cache-buster
    - the build manifests that changed — what actually tells the launcher to go and fetch
13. Write `launcher/addons_published.json` last, so a failed run simply repeats itself
    next time. `addons.json` is never written: it is the reviewed input.

## When nothing has changed, nothing is written

The run is a strict no-op unless something genuinely changed. There are three
separate "nothing changed" cases and none of them writes to R2:

| Situation | What happens |
| --- | --- |
| Every pin already live | Stops at step 3. Nothing downloaded, nothing written. |
| Pin moved, but no published byte changed | Reads remote state to diff, then stops. No upload, no `launcher.json`, no `.gz`, `build.updated` untouched; only the published record moves. |
| `force` on a live pin | Same as above. |
| Only the addon's metadata changed | Republishes `launcher.json` alone. The manifest is not re-uploaded and `build.updated` is **not** bumped. |

This matters more than it looks. `build.updated` is the `?v=` cache-buster on every
file in the build, so bumping it when no file changed would push roughly 3,500 objects
out of the CDN edge at once for no benefit.

A pin that moves without changing any published file is normal — a commit that only
touches `.github/` or a dotfile we filter out. The new pin is still recorded as live in
`launcher/addons_published.json`, so the next run is a cheap skip.

## Things that are load-bearing

**`recent_updates` is not optional.** The launcher only re-hashes files whose extension
is in a small core set (`.dll`, `.exe`, `.sys`, …) plus whatever `recent_updates` names.
`.lua` is not in that set. Without this list an existing install never notices an addon
changed, and players silently stay on the old version. See
`cexi-launcher-v2.App/Source/Cloudflare.cs`, `files_to_verify`.

**`builds[main/ashita].updated` is a cache-buster.** Every build file is fetched as
`{folder}/{file}?v={build.updated}`. Not bumping it means the edge can keep serving the
old bytes.

**The hash must stay SHA1-truncated-to-6.** It mirrors `Utils.GetFileHash` in both the
manager and the launcher. Changing it invalidates every entry in the manifest and forces
every player into a full re-download.

**`launcher.json` formatting is byte-significant in practice.** Newtonsoft writes 2-space
indent, CRLF, no BOM, no trailing newline. The encoder reproduces that exactly — verified
by round-tripping the live file — so diffs stay limited to what actually changed.

## Deliberate behaviours

- **Removed files are manifest-only.** When a release drops a file it is removed from the
  manifest and listed in `recent_deletes` (which the launcher acts on regardless of the
  `enable_file_deletion` setting), but the object is left on R2.
- **Descriptions are preserved.** `d` is only written from `addon.desc` when the entry is
  new or its description is blank, because descriptions are usually hand-written in the
  manager. Same rule the manager itself uses.
- **`v` is always `null`**, so the launcher reads the version from the lua on disk and it
  is always accurate without republishing `launcher.json`.
- **`recent_updates` is never shrunk below the length we found it.** The manager caps it at
  300; applying that cap on a daily schedule would erode entries before every client had
  acted on them.
- **A bad addon is quarantined, not fatal.** It is skipped, its `commit` is left alone so it
  retries next run, the other addons still publish, and the job exits non-zero so the
  failure is visible.

## Adding a new file type

Extensions are an allow-list in `config.py`, not a deny-list. If a legitimate addon ships
something new the run fails with the exact extension and path; add it to
`ALLOWED_EXTENSIONS` deliberately. Executables are excluded and should stay that way.
