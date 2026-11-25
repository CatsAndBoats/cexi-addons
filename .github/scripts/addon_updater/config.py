"""
Static configuration for the addon updater.

Anything in here that is duplicated from the C# manager is marked with the file it
mirrors. Those values MUST stay in sync or the launcher will disagree with R2 about
what a file's hash is, which forces a full re-download for every player.
"""

# ---------------------------------------------------------------------------
# Build target
# ---------------------------------------------------------------------------

def is_native(entry):
    """
    A VanaCore native addon ("native": true in addons.json): written to VanaCore's own
    addon API (vana.*), so it runs from addons\\vanacore\\ and nowhere else. yunagearopt
    since 1.1.48.
    """
    return entry.get("native") is True


def is_self_updating(entry):
    """
    An addon that updates itself in game ("self_update": true in addons.json): yunagearopt
    since 1.1.85 (its ygo_update.lua fetches its own GitHub releases). Its launcher.json
    entry carries `su`, the version the builds ship, and the launcher leaves a copy whose
    addon.version is newer than that alone instead of putting the build's back over it.
    """
    return entry.get("self_update") is True


class Target:
    """
    One build in launcher.json that every addon is published into.

    tag/name/folder mirror the launcher.json entry, e.g.
        { "name": "ashita", "tag": "main", "folder": "builds\\main\\Ashita", ... }

    folder is the R2 key prefix, so forward slashes. addons_dir is where Ashita addons
    live inside the build, as a manifest path (backslashes); native_dir is where
    VanaCore native addons live, None where the build can't run them (Ashita's). A
    native addon (is_native) goes only to targets with a native_dir, whatever opt_in
    says, and never into addons_dir.

    optional targets are skipped with a warning when their manifest or launcher.json
    entry is missing, so retiring one can never block the required targets.

    opt_in names an addons.json key an addon must set to true to be published to
    this target; None takes every addon. An addon that hasn't opted in is taken out
    of the target's manifest and recent lists (state.forget_recent), never put in
    its recent_deletes: the launcher deletes those paths on every check, whoever's
    copy they are. FORCED_DELETES are the exception: files no build ships.
    """

    def __init__(self, tag, name, folder, addons_dir, optional=False, opt_in=None, native_dir=None):
        self.tag = tag
        self.name = name
        self.folder = folder
        self.addons_dir = addons_dir
        self.native_dir = native_dir
        self.optional = optional
        self.opt_in = opt_in

        # Key of this build's lists in launcher.json (recent_updates / recent_deletes).
        self.key = f"{tag}_{name}"
        # Mirrors Cloudflare.r2_filename_build in cexi-manager/Source/Cloudflare.cs
        self.manifest_key = f"launcher/build_{tag}_{name}.gz"
        self.label = f"{tag}/{name}"

    @property
    def addon_dirs(self):
        """Every folder of this build an addon can be published into."""
        return [folder for folder in (self.addons_dir, self.native_dir) if folder]

    def wants(self, entry):
        """Whether the addons.json entry is published to this target."""
        if is_native(entry):
            return self.native_dir is not None
        return self.opt_in is None or entry.get(self.opt_in) is True

    def addons_dir_for(self, entry):
        """The folder of this build the addon goes in, as a manifest path."""
        return self.native_dir if is_native(entry) else self.addons_dir


# The first target is the primary: its folder is the staging layout the virus scan walks.
#
# The vanacore build keeps Ashita's addons in addons\ashita\, and only the ones that set
# "vanacore": true in addons.json: the rest reach VanaCore through the launcher's Ashita
# mirror (VanaCore.CopyAshitaUpdates), not through this build. VanaCore native addons
# ("native": true) go in its addons\vanacore\, beside VanaCore's own (CatsAndBoats/VanaCore's push_build.py's
# DEPLOY_IGNORE keeps a VanaCore release from touching them).
TARGETS = (
    Target("main", "ashita", "builds/main/Ashita", "addons"),
    Target(
        "vanacore", "vanacore", "builds/vanacore/VanaCore", "addons\\ashita",
        optional=True, opt_in="vanacore", native_dir="addons\\vanacore",
    ),
)

# R2 object keys. Mirrors Cloudflare.r2_filename_* in cexi-manager/Source/Cloudflare.cs
KEY_LAUNCHER_JSON = "launcher/launcher.json"
# {addons.json name: commit} of what the updater has published (main.py read_published).
# Not read by the launcher.
KEY_PUBLISHED = "launcher/addons_published.json"

# Public origin, used only for cache purging.
PUBLIC_ORIGIN = "https://launcher.catseyexi.com"


# ---------------------------------------------------------------------------
# Hashing
# ---------------------------------------------------------------------------

# DO NOT CHANGE. Must match Utils.GetFileHash() in both cexi-manager and
# cexi-launcher-v2.App: SHA1 over the raw file bytes, truncated to N hex chars.
# Changing this invalidates every hash in the manifest and forces all players to
# re-download the entire build.
HASH_LENGTH = 6


# ---------------------------------------------------------------------------
# launcher.json bookkeeping
# ---------------------------------------------------------------------------

# The manager truncates recent_updates to this many entries (keeping the newest).
# See maxRecentUpdates in cexi-manager/MainReleaseWindow.xaml.cs.
MAX_RECENT_UPDATES = 300

# Same idea for recent_deletes, which has no explicit cap in the manager but will
# grow without bound if we never trim it.
MAX_RECENT_DELETES = 300

# Files every run that writes launcher.json puts in each target's recent_deletes, under
# its Ashita addons folder (addons\ in main/ashita, addons\ashita\ in vanacore/vanacore),
# whatever else the run published. For files an addon dropped that VanaCore's copy still
# has: the launcher's Ashita mirror (VanaCore.CopyAshitaUpdates) copies what it downloads
# for Ashita but never deletes, and an addon without "vanacore": true never puts what it
# removed in the vanacore build's recent_deletes (state.forget_recent). A path a build
# ships again is left out of every build (state.forced_deletes), as the launcher would
# delete and download it on every check.
#
# For now: Sidekick 3.0.0 (2026-11-04) moved everything out of lib\, and VanaCore's copies
# kept the old lib\ beside the new files. Empty it once players have had the deletes.
FORCED_DELETES = (
    r"Sidekick\lib\actions\buff.lua",
    r"Sidekick\lib\actions\follow.lua",
    r"Sidekick\lib\actions\geo.lua",
    r"Sidekick\lib\actions\heal.lua",
    r"Sidekick\lib\actions\item.lua",
    r"Sidekick\lib\actions\pet.lua",
    r"Sidekick\lib\actions\recover.lua",
    r"Sidekick\lib\actions\rest.lua",
    r"Sidekick\lib\actions\revive.lua",
    r"Sidekick\lib\actions\roll.lua",
    r"Sidekick\lib\actions\rune.lua",
    r"Sidekick\lib\actions\status_removal.lua",
    r"Sidekick\lib\core\action_core.lua",
    r"Sidekick\lib\core\afk.lua",
    r"Sidekick\lib\core\automation.lua",
    r"Sidekick\lib\core\common.lua",
    r"Sidekick\lib\core\lang.lua",
    r"Sidekick\lib\core\parse_packets.lua",
    r"Sidekick\lib\core\party_share.lua",
    r"Sidekick\lib\core\roll_strategy.lua",
    r"Sidekick\lib\core\targets.lua",
    r"Sidekick\lib\core\vanadiel.lua",
    r"Sidekick\lib\jobs\bard.lua",
    r"Sidekick\lib\jobs\beastmaster.lua",
    r"Sidekick\lib\jobs\black_mage.lua",
    r"Sidekick\lib\jobs\blue_mage.lua",
    r"Sidekick\lib\jobs\corsair.lua",
    r"Sidekick\lib\jobs\dancer.lua",
    r"Sidekick\lib\jobs\dark_knight.lua",
    r"Sidekick\lib\jobs\dragoon.lua",
    r"Sidekick\lib\jobs\geomancer.lua",
    r"Sidekick\lib\jobs\monk.lua",
    r"Sidekick\lib\jobs\ninja.lua",
    r"Sidekick\lib\jobs\paladin.lua",
    r"Sidekick\lib\jobs\puppetmaster.lua",
    r"Sidekick\lib\jobs\ranger.lua",
    r"Sidekick\lib\jobs\red_mage.lua",
    r"Sidekick\lib\jobs\rune_fencer.lua",
    r"Sidekick\lib\jobs\samurai.lua",
    r"Sidekick\lib\jobs\scholar.lua",
    r"Sidekick\lib\jobs\summoner.lua",
    r"Sidekick\lib\jobs\thief.lua",
    r"Sidekick\lib\jobs\warrior.lua",
    r"Sidekick\lib\jobs\white_mage.lua",
    r"Sidekick\lib\ui\components.lua",
    r"Sidekick\lib\ui\config.lua",
    r"Sidekick\lib\ui\panel.lua",
    r"Sidekick\lib\ui\tooltips.lua",
)

# launcher.json is written by Newtonsoft with Formatting.Indented on Windows.
# That means 2-space indent, CRLF newlines, no BOM, no trailing newline. Matching
# this exactly keeps our diffs to the lines we actually changed.
JSON_INDENT = 2
JSON_NEWLINE = "\r\n"


# ---------------------------------------------------------------------------
# Safety: what we are willing to publish
# ---------------------------------------------------------------------------

# Allow-list, not a deny-list. Anything not named here fails the addon.
# Derived from a survey of what actually exists under addons\ in the live manifest,
# minus everything executable.
ALLOWED_EXTENSIONS = frozenset(
    {
        # code / data
        ".lua",
        ".json",
        ".xml",
        ".xaml",
        ".txt",
        ".md",
        ".csv",
        ".ini",
        ".cfg",
        ".yml",
        ".yaml",
        ".tbl",
        ".addon",
        # images
        ".png",
        ".jpg",
        ".jpeg",
        ".gif",
        ".bmp",
        ".ico",
        # fonts
        ".ttf",
        ".otf",
        # audio
        ".wav",
        ".ogg",
        ".mp3",
        # docs
        ".html",
        ".htm",
        ".css",
    }
)

# Files with no extension are only allowed if their name is one of these. Keeps
# LICENSE/README-style files working without opening the door to arbitrary blobs.
ALLOWED_EXTENSIONLESS_NAMES = frozenset(
    {
        "license",
        "licence",
        "copying",
        "notice",
        "authors",
        "contributors",
        "changelog",
        "readme",
        "version",
    }
)

# Silently dropped from the release rather than failing it. These are repo
# furniture that has no business being shipped to players.
EXCLUDED_NAMES = frozenset(
    {
        "thumbs.db",
        "desktop.ini",
        ".ds_store",
        "__macosx",
    }
)

# Any path segment starting with "." is dropped (.git, .github, .gitignore,
# .vscode, .editorconfig, ...). Confirmed against Sidekick: the live R2 copy
# excludes .gitignore, so this matches what was published by hand.
DROP_DOTFILES = True

# Hard limits. Tripping one fails the addon rather than truncating.
MAX_FILE_BYTES = 32 * 1024 * 1024
MAX_ADDON_BYTES = 256 * 1024 * 1024
MAX_ADDON_FILES = 4000

# Characters that break R2 object URLs. The manager refuses to push these too.
URL_UNSAFE_CHARS = ("#", "?")


# ---------------------------------------------------------------------------
# Lua metadata vetting
# ---------------------------------------------------------------------------

# Fields that must be present in the addon's entry-point lua for it to be
# considered a valid Ashita addon.
REQUIRED_LUA_FIELDS = ("name", "author", "version", "desc")

# Present-if-possible, but not fatal. Falls back to the repo URL from addons.json.
OPTIONAL_LUA_FIELDS = ("link",)

# Only read metadata from the first chunk of the file. addon.* assignments live at
# the top of every Ashita addon, and this stops us regex-scanning megabyte files.
LUA_METADATA_SCAN_BYTES = 64 * 1024


# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

GITHUB_API = "https://api.github.com"
HTTP_TIMEOUT = 60
HTTP_RETRIES = 3
UPLOAD_CONCURRENCY = 16
UPLOAD_RETRIES = 3
VERIFY_RETRIES = 3
