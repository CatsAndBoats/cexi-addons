#!/usr/bin/env python3
"""
Offline checks for the addon updater's safety gates and manifest logic.

No network, no R2, no credentials. Run as a pre-flight step in the workflow so a
change that weakens a gate fails before anything is published:

    python .github/scripts/addon_updater/test_addon_updater.py
"""

import gzip
import io
import os
import sys
import zipfile
from collections import OrderedDict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import config  # noqa: E402
import lua_meta  # noqa: E402
import main as updater  # noqa: E402
import sources  # noqa: E402
import state  # noqa: E402
import summary  # noqa: E402
import util  # noqa: E402
import vetting  # noqa: E402
from util import SEP, AddonError  # noqa: E402

RESULTS = []


def check(label, condition, detail=""):
    RESULTS.append((bool(condition), label, str(detail)[:100]))


def expect_reject(label, fn):
    try:
        fn()
    except AddonError as exc:
        RESULTS.append((True, label, f"rejected: {str(exc)[:70]}"))
    except Exception as exc:  # noqa: BLE001
        RESULTS.append((False, label, f"wrong exception {type(exc).__name__}: {exc}"))
    else:
        RESULTS.append((False, label, "NOT REJECTED"))


def expect_accept(label, fn):
    try:
        fn()
        RESULTS.append((True, label, "accepted"))
    except Exception as exc:  # noqa: BLE001
        RESULTS.append((False, label, f"WRONGLY REJECTED: {exc}"))


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

ROOT = "acme-Demo-abc1234"

GOOD_LUA = (
    b"addon.name    = 'Demo'\n"
    b"addon.author  = 'Acme'\n"
    b"addon.version = '1.0.0'\n"
    b"addon.desc    = 'A demo addon'\n"
    b"addon.link    = 'https://github.com/acme/Demo'\n"
)


def make_zip(entries, symlinks=()):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as archive:
        for name, data in entries.items():
            archive.writestr(name, data)
        for name, target in symlinks:
            info = zipfile.ZipInfo(name)
            info.create_system = 3
            info.external_attr = 0o120777 << 16
            archive.writestr(info, target)
    return buf.getvalue()


def unpack_and_vet(entries, symlinks=(), lua="Demo.lua", name="Demo"):
    def run():
        _, files = sources.extract_release(make_zip(entries, symlinks), lua)
        kept = vetting.filter_and_check(files, name)
        key = updater.entry_lua_key(kept, lua)
        vetting.read_lua_metadata(kept[key], name)
        return kept

    return run


def with_extra(path, data=b"payload"):
    return unpack_and_vet({f"{ROOT}/Demo.lua": GOOD_LUA, f"{ROOT}/{path}": data})


# ---------------------------------------------------------------------------
# Safety gates
# ---------------------------------------------------------------------------


def test_safety():
    expect_accept(
        "well-formed addon",
        unpack_and_vet({f"{ROOT}/Demo.lua": GOOD_LUA, f"{ROOT}/data/icon.png": b"\x89PNG\r\n"}),
    )

    # Executables and archives must never be publishable, whatever else changes.
    for extension in (
        ".exe", ".dll", ".bat", ".cmd", ".ps1", ".sh", ".scr", ".msi", ".vbs",
        ".jar", ".com", ".cpl", ".sys", ".zip", ".7z", ".rar", ".bin", ".dat",
    ):
        expect_reject(f"blocked type {extension}", with_extra(f"payload{extension}", b"MZ\x90"))

    expect_reject("double extension .txt.exe", with_extra("readme.txt.exe", b"MZ"))
    expect_reject("executable in a subfolder", with_extra("tools/nested/run.exe", b"MZ"))
    expect_reject("unknown extensionless file", with_extra("mystery", b"data"))
    expect_accept("LICENSE has no extension but is allowed", with_extra("LICENSE", b"MIT"))

    # Archive structure attacks.
    expect_reject("zip-slip via ..", with_extra("../../evil.lua", b"x"))
    expect_reject(
        "absolute path entry",
        unpack_and_vet({f"{ROOT}/Demo.lua": GOOD_LUA, "/etc/passwd": b"x"}),
    )
    expect_reject(
        "symlink entry",
        unpack_and_vet({f"{ROOT}/Demo.lua": GOOD_LUA}, symlinks=((f"{ROOT}/link.lua", "/etc/passwd"),)),
    )

    # zipfile rewrites backslashes to "/" on read, but only when os.sep != "/" --
    # i.e. on Windows. On Linux they survive, so check the guard directly rather
    # than through the archive API, which behaves differently per platform.
    for candidate in (
        ROOT + SEP + "evil.lua",
        SEP + SEP + "server" + SEP + "share.lua",
        "C:" + SEP + "windows" + SEP + "x.lua",
        "/absolute.lua",
        "a/../../b.lua",
    ):
        check(f"unsafe path rejected: {candidate!r}", sources._is_unsafe_entry(candidate))
    for candidate in ("Demo.lua", "lib/jobs/warrior.lua", "a/b/c/d.png"):
        check(
            f"safe path accepted: {candidate!r}",
            sources._is_unsafe_entry(candidate) is None,
        )

    expect_reject("reserved windows name CON.lua", with_extra("CON.lua", b"x"))
    expect_reject("url-unsafe # in filename", with_extra("we#ird.lua", b"x"))
    expect_reject("url-unsafe ? in filename", with_extra("we?ird.lua", b"x"))

    # Lua vetting: this is what stops a repo that is not an Ashita addon.
    expect_reject(
        "lua missing addon.author",
        unpack_and_vet({f"{ROOT}/Demo.lua": b"addon.name='D'\naddon.version='1'\naddon.desc='d'\n"}),
    )
    expect_reject(
        "lua with blank metadata",
        unpack_and_vet({f"{ROOT}/Demo.lua": b"addon.name=''\naddon.author=''\naddon.version=''\naddon.desc=''\n"}),
    )
    expect_reject(
        "not an ashita addon at all",
        unpack_and_vet({f"{ROOT}/Demo.lua": b"local x = 1\nreturn x\n"}),
    )

    # Structure.
    expect_reject("entry-point lua absent", unpack_and_vet({f"{ROOT}/Other.lua": GOOD_LUA}))
    expect_reject(
        "ambiguous addon root",
        unpack_and_vet({f"{ROOT}/a/Demo.lua": GOOD_LUA, f"{ROOT}/b/Demo.lua": GOOD_LUA}),
    )
    expect_accept(
        "nested addon root (Addon-v2.32/Addon.lua)",
        unpack_and_vet({f"{ROOT}/Demo-v2.32/Demo.lua": GOOD_LUA, f"{ROOT}/Demo-v2.32/x.lua": b"-- x"}),
    )

    # yunagearopt 1.1.53: a same-named lua deeper in the tree (native/yunagearopt.lua,
    # a loader with no addon.* header) sorted before the root one ("native/..." <
    # "yunagearopt.lua"). The root one is the entry, and the one vetted, whatever
    # order the files come in. "Core/" sorts before "Demo.lua" the same way.
    loader_first = OrderedDict([
        (f"{ROOT}/Core/Demo.lua", b"-- loads the real addon; no addon.* header\n"),
        (f"{ROOT}/Demo.lua", GOOD_LUA),
    ])
    expect_accept("same-named lua deeper in the tree, sorted first", unpack_and_vet(loader_first))

    def root_lua_is_the_entry():
        _, files = sources.extract_release(make_zip(loader_first), "Demo.lua")
        kept = vetting.filter_and_check(files, "Demo")
        assert list(kept)[0] == "Core/Demo.lua", list(kept)  # the order the bug depended on
        assert updater.entry_lua_key(kept, "Demo.lua") == "Demo.lua"

    expect_accept("entry lua is the root one, not the first same-named file", root_lua_is_the_entry)
    expect_reject("entry lua filtered out", lambda: updater.entry_lua_key({"x.lua": b""}, "Demo.lua"))

    # Repo URLs.
    expect_reject("non-github repo url", lambda: sources.parse_repo("https://evil.example.com/a/b"))
    expect_reject("repo url with traversal", lambda: sources.parse_repo("https://github.com/a/b/../../c"))
    expect_accept("plain github url", lambda: sources.parse_repo("https://github.com/seekey13/Sidekick"))
    expect_accept("github url with .git", lambda: sources.parse_repo("https://github.com/seekey13/Sidekick.git"))

    # Dotfiles are dropped rather than treated as an error. Verified against the
    # live manifest: Sidekick's published set is its release minus .gitignore.
    def dotfiles_dropped():
        _, files = sources.extract_release(
            make_zip(
                {
                    f"{ROOT}/Demo.lua": GOOD_LUA,
                    f"{ROOT}/.gitignore": b"venv",
                    f"{ROOT}/.github/workflows/ci.yml": b"on: push",
                    f"{ROOT}/LICENSE": b"MIT",
                }
            ),
            "Demo.lua",
        )
        kept = vetting.filter_and_check(files, "Demo")
        assert set(kept) == {"Demo.lua", "LICENSE"}, kept

    expect_accept("dotfiles dropped, LICENSE kept", dotfiles_dropped)


# ---------------------------------------------------------------------------
# Lua metadata (mirrors LuaMeta.cs, which players' launchers use)
# ---------------------------------------------------------------------------


def test_lua_meta():
    cases = [
        ("plain", "addon.version = '1.2'", "1.2"),
        ("double quotes", 'addon.version = "1.2";', "1.2"),
        (
            "commented-out line ignored",
            "--addon.version   = '0.9';\naddon.version   = '1.0';",
            "1.0",
        ),
        (
            "block-commented line ignored",
            "--[[\naddon.version = '0.8'\n]]\naddon.version = '1.1'",
            "1.1",
        ),
        (
            "level block comment ignored",
            "--[==[ addon.version = '0.8' ]] ]==]\naddon.version = '1.1'",
            "1.1",
        ),
        ("trailing comment", "addon.version = '2.0' -- was 1.9", "2.0"),
        (
            "variable followed back",
            "local ver = '1.0.260921'\naddon.version = ver",
            "1.0.260921",
        ),
        (
            "commented-out variable value ignored",
            "--local ver = '0.1'\nlocal ver = '0.2'\naddon.version = ver",
            "0.2",
        ),
        (
            "variable chain",
            "local major = '3'\nlocal ver = major\naddon.version = ver",
            "3",
        ),
        (
            "concatenation",
            "local build = 7\naddon.version = '1.0.' .. build",
            "1.0.7",
        ),
        ("tostring", "local v = 1.5\naddon.version = tostring(v)", "1.5"),
        ("number", "addon.version = 1.0", "1.0"),
        ("long string", "addon.version = [[4.0]]", "4.0"),
        ("windower _addon", "_addon.version = '5.0'", "5.0"),
        ("not a longer name", "myaddon.version = '9'\naddon.version = '1'", "1"),
        ("comparison is not assignment", "if addon.version == '9' then end\naddon.version = '1'", "1"),
        ("-- inside a string survives", "addon.desc = 'a -- b'", "a -- b"),
        ("other quote inside a string", "addon.author = \"Bob's\"", "Bob's"),
        ("unresolvable call", "addon.version = string.format('%d', 1)", ""),
        ("only commented out", "--addon.version = '0.9'", ""),
        ("self-referencing variable", "local v = '1'\nv = v .. '.2'\naddon.version = v", "1.2"),
    ]

    for label, code, expected in cases:
        field = "addon.desc" if "desc" in code else "addon.author" if "author" in code else "addon.version"
        got = lua_meta.get(code, field)
        check(f"lua meta: {label}", got == expected, f"got {got!r}, expected {expected!r}")

    expect_accept(
        "lua vetting follows addon.version = ver",
        unpack_and_vet({
            f"{ROOT}/Demo.lua": b"--addon.version = '0.9'\nlocal ver = '1.0'\n"
            b"addon.name='Demo'\naddon.author='A'\naddon.version=ver\naddon.desc='d'\n"
        }),
    )


# ---------------------------------------------------------------------------
# Hashing
# ---------------------------------------------------------------------------


def test_hashing():
    from util import file_hash

    # Fixed vectors, so a change to the hash function is caught immediately. These
    # must never change: they define what every player already has on disk.
    check("sha1 truncation, empty input", file_hash(b"") == "da39a3", file_hash(b""))
    check("sha1 truncation, 'abc'", file_hash(b"abc") == "a9993e", file_hash(b"abc"))
    check("length argument honoured", file_hash(b"abc", 12) == "a9993e364706", file_hash(b"abc", 12))


# ---------------------------------------------------------------------------
# Manifest diffing
# ---------------------------------------------------------------------------

PREFIX = "addons" + SEP + "Demo" + SEP


def key(*parts):
    return PREFIX + SEP.join(parts)


def test_manifest():
    # A rename that only changes case must move the manifest to the new casing:
    # R2 object keys are case-sensitive, so keeping the old one would point players
    # at a key we never uploaded.
    entries = OrderedDict(
        [
            ("addons" + SEP + "Other" + SEP + "keep.lua", "aaaaaa"),
            (key("README.md"), "111111"),
        ]
    )
    added, changed, removed = state.replace_addon_entries(
        entries, PREFIX, OrderedDict([(key("Readme.md"), "111111")])
    )
    check("case rename adds the new casing", added == [key("Readme.md")], added)
    check("case rename removes the old casing", removed == [key("README.md")], removed)
    check("case rename leaves other addons alone", "addons" + SEP + "Other" + SEP + "keep.lua" in entries)

    entries = OrderedDict([(key("a.lua"), "111111"), (key("gone.lua"), "333333")])
    added, changed, removed = state.replace_addon_entries(
        entries, PREFIX, OrderedDict([(key("a.lua"), "999999"), (key("b.lua"), "444444")])
    )
    check("changed file detected", changed == [key("a.lua")], changed)
    check("added file detected", added == [key("b.lua")], added)
    check("removed file detected", removed == [key("gone.lua")], removed)
    check("changed hash written", entries[key("a.lua")] == "999999")

    entries = OrderedDict([(key("a.lua"), "111111")])
    added, changed, removed = state.replace_addon_entries(
        entries, PREFIX, OrderedDict([(key("a.lua"), "111111")])
    )
    check("identical content is a no-op", not (added or changed or removed))

    # addons\DemoExtra\ must not be swallowed by the addons\Demo\ prefix.
    entries = OrderedDict(
        [("addons" + SEP + "DemoExtra" + SEP + "x.lua", "aaaaaa"), (key("a.lua"), "111111")]
    )
    _, _, removed = state.replace_addon_entries(
        entries, PREFIX, OrderedDict([(key("a.lua"), "111111")])
    )
    check(
        "sibling addon sharing a name prefix is untouched",
        "addons" + SEP + "DemoExtra" + SEP + "x.lua" in entries and not removed,
        removed,
    )

    entries = OrderedDict([("z" + SEP + "1", "a"), (key("a.lua"), "111111"), ("y" + SEP + "2", "b")])
    state.replace_addon_entries(entries, PREFIX, OrderedDict([(key("a.lua"), "222222")]))
    check(
        "untouched entries keep their position",
        list(entries) == ["z" + SEP + "1", key("a.lua"), "y" + SEP + "2"],
        list(entries),
    )


def test_targets():
    main, vana = config.TARGETS[0], config.TARGETS[1]

    # The manifest key and launcher.json bucket names are what the launcher and the
    # manager already use for these builds; a typo here writes a stray file to R2.
    check("main manifest key", main.manifest_key == "launcher/build_main_ashita.gz", main.manifest_key)
    check("main list key", main.key == "main_ashita", main.key)
    check("vanacore manifest key", vana.manifest_key == "launcher/build_vanacore_vanacore.gz", vana.manifest_key)
    check("vanacore list key", vana.key == "vanacore_vanacore", vana.key)
    check("main is required", not main.optional)
    check("vanacore is optional", vana.optional)

    check("main addon prefix", util.addon_prefix(main, "Demo") == "addons" + SEP + "Demo" + SEP)
    check(
        "vanacore addon prefix lives in addons\\ashita",
        util.addon_prefix(vana, "Demo") == "addons" + SEP + "ashita" + SEP + "Demo" + SEP,
        util.addon_prefix(vana, "Demo"),
    )

    manifest_path = util.to_manifest_path(vana.addons_dir, "Demo", "lib/x.lua")
    check(
        "vanacore manifest path",
        manifest_path == SEP.join(["addons", "ashita", "Demo", "lib", "x.lua"]),
        manifest_path,
    )
    check(
        "vanacore object key is under its own build folder",
        util.to_r2_key(vana, manifest_path) == "builds/vanacore/VanaCore/addons/ashita/Demo/lib/x.lua",
        util.to_r2_key(vana, manifest_path),
    )
    check(
        "main object key is under its own build folder",
        util.to_r2_key(main, util.to_manifest_path(main.addons_dir, "Demo", "x.lua"))
        == "builds/main/Ashita/addons/Demo/x.lua",
    )

    # Each build keeps its own timestamp and its own lists.
    launcher = OrderedDict(
        [
            (
                "builds",
                [
                    OrderedDict([("tag", "main"), ("name", "ashita"), ("updated", 1.0)]),
                    OrderedDict([("tag", "vanacore"), ("name", "vanacore"), ("updated", 1.0)]),
                ],
            )
        ]
    )
    state.touch_build_timestamp(launcher, vana)
    check("touch bumps only the target's build", launcher["builds"][0]["updated"] == 1.0 and launcher["builds"][1]["updated"] > 1.0)

    state.record_recent_updates(launcher, vana, [SEP.join(["addons", "ashita", "Demo", "x.lua"])])
    state.record_recent_deletes(launcher, vana, [SEP.join(["addons", "ashita", "Demo", "old.lua"])])
    check("recent_updates is keyed by the target", list(launcher["recent_updates"]) == ["vanacore_vanacore"], launcher["recent_updates"])
    check("recent_deletes is keyed by the target", list(launcher["recent_deletes"]) == ["vanacore_vanacore"], launcher["recent_deletes"])

    check("find_build finds the target", state.find_build(launcher, main) is launcher["builds"][0])
    check("find_build is None for a missing build", state.find_build(OrderedDict([("builds", [])]), vana) is None)

    # The same staged file hashes the same whichever build it lands in, and a build
    # that already has the addon sees no change.
    entries = OrderedDict()
    prefix = util.addon_prefix(vana, "Demo")
    path = util.to_manifest_path(vana.addons_dir, "Demo", "a.lua")
    added, changed, removed = state.replace_addon_entries(entries, prefix, OrderedDict([(path, util.file_hash(b"x"))]))
    check("a new build gets every file as an add", added == [path] and not changed and not removed, added)
    added, changed, removed = state.replace_addon_entries(entries, prefix, OrderedDict([(path, util.file_hash(b"x"))]))
    check("a build that already has the file sees no change", not (added or changed or removed))


def test_serialisation():
    sample = OrderedDict([(key("a.lua"), "111111"), (key("b.png"), "222222")])
    blob = state.serialise_manifest(sample)
    text = gzip.decompress(blob).decode("utf-8")

    check("manifest round-trips", state.parse_manifest(blob) == sample)
    check("manifest is byte-stable across runs", state.serialise_manifest(sample) == blob)
    check("manifest has no trailing newline", not text.endswith("\n"))
    check("manifest has no CR", "\r" not in text)
    check("manifest uses backslash separators", text.startswith("addons" + SEP))

    # launcher.json must come back out exactly as Newtonsoft would write it:
    # 2-space indent, CRLF, no BOM, no trailing newline.
    data = OrderedDict([("a", 1), ("b", [1, 2]), ("c", OrderedDict([("d", None)]))])
    raw = state.serialise_launcher(data)
    check("launcher.json has no BOM", raw[:3] != b"\xef\xbb\xbf")
    check("launcher.json uses CRLF", b"\r\n" in raw)
    check("launcher.json has no bare LF", b"\n" not in raw.replace(b"\r\n", b""))
    check("launcher.json has no trailing newline", not raw.endswith(b"\n"))
    check("launcher.json round-trips", state.parse_launcher(raw) == data)


def test_self_update():
    # An addon that updates itself in game: launcher.json carries the version the builds
    # ship (su), which the launcher compares with the installed copy's addon.version.
    check("self_update flag is read", config.is_self_updating({"self_update": True}))
    check("self_update needs a real true", not config.is_self_updating({"self_update": "yes"}))
    check("no self_update by default", not config.is_self_updating({}))

    meta = {"name": "yunagearopt", "author": "Yunas", "version": "1.1.85", "desc": "Gear"}
    launcher = OrderedDict()
    key, touched = state.upsert_addon_entry(launcher, "yunagearopt", meta, "https://github.com/YunasXI/yunagearopt", self_update=True)
    entry = launcher["addons"][key]
    check("new self-updating entry gets su", touched and entry.get("su") == "1.1.85", entry)
    check("v stays null beside su", entry["v"] is None)

    bumped = dict(meta, version="1.1.88")
    _, touched = state.upsert_addon_entry(launcher, "yunagearopt", bumped, "https://github.com/YunasXI/yunagearopt", self_update=True)
    check("su follows the published version", touched and launcher["addons"][key]["su"] == "1.1.88")

    _, touched = state.upsert_addon_entry(launcher, "yunagearopt", bumped, "https://github.com/YunasXI/yunagearopt", self_update=True)
    check("same version leaves the entry untouched", not touched)

    _, touched = state.upsert_addon_entry(launcher, "yunagearopt", bumped, "https://github.com/YunasXI/yunagearopt")
    check("su is taken off when the flag goes", touched and "su" not in launcher["addons"][key])

    plain = OrderedDict()
    key, _ = state.upsert_addon_entry(plain, "Sidekick", dict(meta, name="Sidekick"), "https://github.com/seekey13/Sidekick")
    check("other addons get no su", "su" not in plain["addons"][key])


def test_recent_lists():
    # The manager caps these at 300. Applying that blindly on a daily schedule
    # would erode entries the manager left before clients had acted on them.
    existing = [f"addons{SEP}x{SEP}f{i}.lua" for i in range(366)]
    merged = state._merge_capped(existing, [f"addons{SEP}y{SEP}new.lua"], 300)
    check("cap never shrinks a longer existing list", len(merged) == 366, len(merged))
    check("new entry survives the trim", merged[-1] == f"addons{SEP}y{SEP}new.lua")

    short = [f"addons{SEP}x{SEP}f{i}.lua" for i in range(10)]
    merged = state._merge_capped(short, [f"addons{SEP}x{SEP}f3.lua"], 300)
    check(
        "re-listed path is deduped and moved to the end",
        len(merged) == 10 and merged[-1] == f"addons{SEP}x{SEP}f3.lua",
        len(merged),
    )

    merged = state._merge_capped([], [f"addons{SEP}x{SEP}a.lua", f"addons{SEP}x/b.lua"], 300)
    check("forward slashes are normalised", all(SEP in p and "/" not in p for p in merged), merged)


# ---------------------------------------------------------------------------
# Run summary
# ---------------------------------------------------------------------------


def test_summary():
    path, deeper = sources._locate_lua(["README.md", "Demo.lua", "lib/Demo.lua"], "demo.lua")
    check("version lookup picks the shallowest lua", path == "Demo.lua" and deeper, path)
    expect_reject("version lookup rejects a repo without the lua", lambda: sources._locate_lua(["x.lua"], "Demo.lua"))

    def entry(name, commit=""):
        return {"name": name, "github": f"https://github.com/acme/{name}", "lua": f"{name}.lua", "commit": commit}

    entries = [entry("Fresh", "a" * 40), entry("Bumped", "b" * 40), entry("Brand"), entry("Broken", "d" * 40), entry("Skipped", "e" * 40)]
    report = summary.Report(entries)
    fresh, bumped, brand, broken, skipped = report.rows

    fresh.status, fresh.tag, fresh.sha = summary.UP_TO_DATE, "v1.0", "a" * 40
    bumped.status, bumped.tag, bumped.sha, bumped.version = summary.STAGED, "v2.1", "f" * 40, "2.1"
    bumped.files, bumped.planned = (1, 2, 0), summary.PUBLISHED
    brand.status, brand.tag, brand.sha, brand.version = summary.STAGED, "0.3", "c" * 40, "0.3"
    brand.files, brand.planned = (0, 0, 0), summary.UNCHANGED
    broken.status, broken.tag, broken.reason = summary.FAILED, "v9", "missing addon.version | bad"

    report.published()
    check("a vetted release takes its planned outcome", bumped.status == summary.PUBLISHED, bumped.status)
    check("live commit moves to the published release", report.live_sha(bumped) == "f" * 40)
    check("live commit stays put for a failed addon", report.live_sha(broken) == "d" * 40)

    looked_up = []

    def fake_version(token, owner, repo, sha, lua, path=""):
        looked_up.append((repo, sha))
        if repo == "Skipped":
            raise AddonError("rate limited")
        return {"a": "1.0", "b": "2.0", "d": "8.5"}[sha[0]]

    real, sources.fetch_lua_version = sources.fetch_lua_version, fake_version
    real_warn, summary.warn = summary.warn, lambda *_a, **_k: None
    try:
        summary.resolve_versions(report, "token")
    finally:
        sources.fetch_lua_version, summary.warn = real, real_warn

    check("published version comes from the vetted lua", bumped.live_version == "2.1", bumped.live_version)
    check("previous version is looked up", bumped.old_version == "2.0", bumped.old_version)
    check("up-to-date version is looked up", fresh.live_version == "1.0", fresh.live_version)
    check("failed lookup shows '?'", skipped.live_version == "?", skipped.live_version)
    check("vetted versions are not fetched again", ("Bumped", "f" * 40) not in looked_up, looked_up)

    text = summary.render(report)
    check("headline lists the new releases", "**2 new releases:** Bumped 2.1, Brand 0.3 **1 failed.**" in text, text[:200])
    check("release row shows old -> new", "| 2.0 → **2.1** |" in text)
    check("release row shows file counts", "Published: 1 added, 2 changed |" in text)
    check("first release is marked new", "**0.3** (new addon)" in text)
    check("failure reason keeps its table cell", "missing addon.version \\| bad" in text)
    check("all addons lists every addon", all(f"[{r.name}](" in text.split("### All addons")[1] for r in report.rows))
    check("unpublished addon says so", "| [Brand](https://github.com/acme/Brand) | 0.3 |" in text)

    report = summary.Report([entry("Quiet", "a" * 40)], dry_run=True)
    report.rows[0].status = summary.UP_TO_DATE
    text = summary.render(report)
    check("quiet run says no new releases", "**No new releases.**" in text and "### New releases" not in text)
    check("dry run is flagged", "Dry run" in text)


# ---------------------------------------------------------------------------
# Branch source (a repo with no releases)
# ---------------------------------------------------------------------------


class FakeResponse:
    def __init__(self, payload):
        self.payload = payload

    def json(self):
        return self.payload


def test_branch_source():
    # One folder per version, an old version zipped at the root: path picks the folder.
    repo = {
        f"{ROOT}/Demo-v1.0.zip": b"PK",
        f"{ROOT}/Demo-v1.0/Demo/Demo.lua": b"-- old",
        f"{ROOT}/Demo-v1.1/Demo/Demo.lua": GOOD_LUA,
        f"{ROOT}/Demo-v1.1/Demo/lib/x.lua": b"-- x",
    }
    root, files = sources.extract_release(make_zip(repo), "Demo.lua", "Demo-v1.1/Demo")
    check("path picks the named folder", root == f"{ROOT}/Demo-v1.1/Demo", root)
    check("path takes only that folder's files", set(files) == {"Demo.lua", "lib/x.lua"}, sorted(files))
    check("path takes that folder's lua", files["Demo.lua"] == GOOD_LUA)
    expect_reject("without a path, two version folders are ambiguous", lambda: sources.extract_release(make_zip(repo), "Demo.lua"))
    expect_reject("a path that holds no lua is rejected", lambda: sources.extract_release(make_zip(repo), "Demo.lua", "Demo-v1.2/Demo"))
    expect_reject("a path is a folder, not a name prefix", lambda: sources.extract_release(make_zip(repo), "Demo.lua", "Demo-v1"))

    found, _ = sources._locate_lua(["Demo-v1.0/Demo/Demo.lua", "Demo-v1.1/Demo/Demo.lua"], "Demo.lua", "Demo-v1.1/Demo")
    check("version lookup follows the path", found == "Demo-v1.1/Demo/Demo.lua", found)

    # The commit is the latest on the branch to touch the path.
    calls = []

    def fake_get(session, url, allow_404=False, stream=False):
        calls.append(url)
        return FakeResponse([] if "Gone" in url else [{"sha": "b" * 40}])

    real_get, sources._get = sources._get, fake_get
    try:
        sha = sources.resolve_branch_commit("token", "acme", "Demo", "main", "Demo-v1.1/Demo")
        expect_reject("a path no commit touches is rejected", lambda: sources.resolve_branch_commit("token", "acme", "Demo", "main", "Gone"))
    finally:
        sources._get = real_get
    check("branch commit is the newest one", sha == "b" * 40, sha)
    check(
        "branch commit is scoped to the branch and path",
        calls[0].endswith("/repos/acme/Demo/commits?sha=main&per_page=1&path=Demo-v1.1/Demo"),
        calls[0],
    )

    # _gather_one (INSTALL): the pinned commit only, never an upstream lookup; a pin that
    # isn't live goes through the approval check; the path scopes the files.
    entry = OrderedDict([
        ("name", "Demo"), ("github", "https://github.com/acme/Demo"), ("branch", "main"),
        ("path", "/Demo-v1.1/Demo/"), ("install", "Demo"), ("lua", "Demo.lua"), ("commit", ""),
    ])
    seen = {"approved": []}

    def fake_fetch(token, owner, repo_name, sha, lua, path):
        seen["fetch"] = (owner, repo_name, sha, path)
        return sources.extract_release(make_zip(repo), lua, path)

    def no_lookup(*_args):
        raise AssertionError("INSTALL asked upstream what is newest")

    def approve(e, pin):
        seen["approved"].append(pin)

    saved = sources.fetch_commit, sources.resolve_branch_commit, sources.resolve_latest_release
    sources.fetch_commit, sources.resolve_branch_commit, sources.resolve_latest_release = fake_fetch, no_lookup, no_lookup
    try:
        expect_reject("an entry with no pin is refused", lambda: updater._gather_one(entry, "token", False, summary.AddonRow(entry), {}, approve))
        entry["commit"] = "c" * 7
        expect_reject("a short pin is refused", lambda: updater._gather_one(entry, "token", False, summary.AddonRow(entry), {}, approve))
        entry["commit"] = "c" * 40
        row = summary.AddonRow(entry)
        staged = updater._gather_one(entry, "token", False, row, {"Demo": "b" * 40}, approve)
        quiet = updater._gather_one(entry, "token", False, summary.AddonRow(entry), {"Demo": "c" * 40}, approve)

        def refuse(e, pin):
            raise AddonError("not approved")

        expect_reject("a pin the check refuses isn't fetched", lambda: updater._gather_one(entry, "token", False, summary.AddonRow(entry), {}, refuse))
    finally:
        sources.fetch_commit, sources.resolve_branch_commit, sources.resolve_latest_release = saved

    check("a new pin goes through the approval check once", seen["approved"] == ["c" * 40], seen["approved"])
    check("the pinned commit is what's fetched, path trimmed", seen["fetch"] == ("acme", "Demo", "c" * 40, "Demo-v1.1/Demo"), seen.get("fetch"))
    check("branch addon stages the path's files", staged is not None and set(staged.files) == {"Demo.lua", "lib/x.lua"})
    check("branch addon is labelled branch@sha", row.tag == "main@ccccccc" and row.sha == "c" * 40, row.tag)
    check("a pin that is already live is up to date, unchecked", quiet is None)

    row.status = summary.UP_TO_DATE
    link = summary._tag_link(row)
    check("summary links a branch addon to its folder", link == f"[main@ccccccc](https://github.com/acme/Demo/tree/{'c' * 40}/Demo-v1.1/Demo)", link)


# ---------------------------------------------------------------------------


def test_native_asset():
    # A VanaCore native addon ("native": true) runs from addons\vanacore only: the vanacore
    # build takes it there, the Ashita build not at all, and what either held of it under
    # its Ashita addons folder is dropped (not deleted from players' disks).
    main, vana = config.TARGETS[0], config.TARGETS[1]
    yuna = OrderedDict([("name", "yunagearopt"), ("install", "yunagearopt"), ("native", True)])
    seekey = OrderedDict([("name", "Sidekick"), ("install", "Sidekick"), ("vanacore", True)])

    check("native must be true, not truthy", not config.is_native(OrderedDict([("native", "yes")])))
    check("main doesn't take a native addon", not main.wants(yuna))
    check("vanacore takes a native addon without the vanacore opt-in", vana.wants(yuna))
    check("main has no native folder", main.addon_dirs == ["addons"], main.addon_dirs)
    check("vanacore has both folders", vana.addon_dirs == ["addons" + SEP + "ashita", "addons" + SEP + "vanacore"], vana.addon_dirs)
    check("a native addon goes in addons\\vanacore", vana.addons_dir_for(yuna) == "addons" + SEP + "vanacore")
    check("an Ashita addon goes in addons\\ashita", vana.addons_dir_for(seekey) == "addons" + SEP + "ashita")

    gear_ashita = util.addon_prefix(vana, "yunagearopt")
    gear_native = util.addon_prefix(vana, "yunagearopt", vana.native_dir)
    check("native prefix", gear_native == SEP.join(["addons", "vanacore", "yunagearopt"]) + SEP, gear_native)
    check(
        "vanacore purges a native addon's old Ashita copy",
        updater.unwanted_prefixes([yuna, seekey], vana, set()) == [gear_ashita, util.addon_prefix(vana, "Sidekick", vana.native_dir)],
        updater.unwanted_prefixes([yuna, seekey], vana, set()),
    )
    check(
        "main purges a native addon",
        updater.unwanted_prefixes([yuna, seekey], main, set()) == [util.addon_prefix(main, "yunagearopt")],
        updater.unwanted_prefixes([yuna, seekey], main, set()),
    )

    staged = updater.StagedAddon(yuna, "1.1.54", "abc", {"yunagearopt.lua": b"loader", "core.lua": b"core"}, {}, summary.AddonRow(yuna))
    manifest = OrderedDict([("VanaCore.exe", "aaaaaa"), (gear_ashita + "yunagearopt.lua", "111111"), (gear_ashita + "data.lua", "222222")])
    plan = updater.build_plan([staged], manifest, vana, updater.unwanted_prefixes([yuna], vana, set()))
    check("the old Ashita copy is purged, not removed", plan.purged == [gear_ashita + "yunagearopt.lua", gear_ashita + "data.lua"] and plan.removed == [], (plan.purged, plan.removed))
    check("the native files are added under addons\\vanacore", plan.added == [gear_native + "core.lua", gear_native + "yunagearopt.lua"], plan.added)
    check(
        "the native files upload under the build's addons/vanacore",
        list(plan.uploads) == ["builds/vanacore/VanaCore/addons/vanacore/yunagearopt/core.lua", "builds/vanacore/VanaCore/addons/vanacore/yunagearopt/yunagearopt.lua"],
        list(plan.uploads),
    )
    check("nothing is left under addons\\ashita", not any(k.startswith(gear_ashita) for k in manifest), list(manifest))

    plan = updater.build_plan([staged], OrderedDict([(util.addon_prefix(main, "yunagearopt") + "yunagearopt.lua", "111111")]), main, updater.unwanted_prefixes([yuna], main, set()))
    check("main drops its copy and uploads nothing", plan.purged and not plan.uploads and not plan.added, (plan.purged, list(plan.uploads)))

    # "asset": the author's built zip from the release, instead of the source zipball.
    assets = [
        {"name": "yunagearopt-1.1.54.zip", "url": "https://api.github.com/repos/YunasXI/yunagearopt/releases/assets/1", "size": 1000},
        {"name": "yunagearopt-1.1.54.tar.gz", "url": "https://api.github.com/repos/YunasXI/yunagearopt/releases/assets/2", "size": 1000},
        {"name": "Source.zip", "url": "https://api.github.com/repos/YunasXI/yunagearopt/releases/assets/3", "size": 1000},
    ]
    check("asset glob picks the one upload", sources.pick_release_asset(assets, "yunagearopt-*.zip")["name"] == "yunagearopt-1.1.54.zip")
    check("asset glob ignores case", sources.pick_release_asset(assets, "YUNAGEAROPT-*.ZIP")["name"] == "yunagearopt-1.1.54.zip")
    expect_reject("asset glob that matches nothing", lambda: sources.pick_release_asset(assets, "ygo-*.zip"))
    expect_reject("asset glob that matches two", lambda: sources.pick_release_asset(assets, "*.zip"))
    expect_reject("asset that is not a zip", lambda: sources.pick_release_asset(assets, "*.tar.gz"))
    expect_reject("asset over the size limit", lambda: sources.pick_release_asset([{"name": "big.zip", "url": "u", "size": config.MAX_ADDON_BYTES + 1}], "big.zip"))
    expect_reject("a release with no uploads", lambda: sources.pick_release_asset([], "yunagearopt-*.zip"))

    # _gather_one with an asset: the release named by "tag" must be at the pinned commit,
    # and the downloaded zip must hash to the pinned asset_sha256.
    built = {
        "yunagearopt/yunagearopt.lua": GOOD_LUA.replace(b"'Demo'", b"'yunagearopt'"),
        "yunagearopt/core.lua": b"-- the repo's yunagearopt.lua\n",
        "yunagearopt/data.lua": b"-- data\n",
    }
    built_zip = make_zip(built)
    entry = OrderedDict([
        ("name", "yunagearopt"), ("github", "https://github.com/YunasXI/yunagearopt"), ("asset", "yunagearopt-*.zip"),
        ("install", "yunagearopt"), ("lua", "yunagearopt.lua"), ("native", True), ("commit", "d" * 40),
        ("tag", "1.1.54"), ("asset_sha256", sources.sha256(built_zip)),
    ])
    seen = {}

    def fake_release(token, owner, repo_name, tag):
        seen["tag"] = tag
        return tag, ("d" * 40 if tag == "1.1.54" else "e" * 40), assets

    def fake_asset(token, chosen):
        seen["asset"] = chosen["name"]
        return built_zip

    def no_git(*_args):
        raise AssertionError("fetched the source by git")

    ok = lambda e, pin: None  # noqa: E731
    saved = sources.resolve_release, sources.download_release_asset, sources.fetch_commit
    sources.resolve_release, sources.download_release_asset, sources.fetch_commit = fake_release, fake_asset, no_git
    try:
        row = summary.AddonRow(entry)
        staged = updater._gather_one(entry, "token", False, row, {}, ok)
        tampered = OrderedDict(entry, asset_sha256="0" * 64)
        expect_reject("an asset that doesn't hash to its pin", lambda: updater._gather_one(tampered, "token", False, summary.AddonRow(tampered), {}, ok))
        moved = OrderedDict(entry, tag="1.1.55")
        expect_reject("a release tag that isn't at the pinned commit", lambda: updater._gather_one(moved, "token", False, summary.AddonRow(moved), {}, ok))
        unpinned = OrderedDict(entry, asset_sha256="")
        expect_reject("an asset entry without asset_sha256", lambda: updater._gather_one(unpinned, "token", False, summary.AddonRow(unpinned), {}, ok))
        with_branch = OrderedDict(entry, branch="main")
        expect_reject("asset with branch", lambda: updater._gather_one(with_branch, "token", False, summary.AddonRow(with_branch), {}, ok))
        with_path = OrderedDict(entry, path="native")
        expect_reject("asset with path", lambda: updater._gather_one(with_path, "token", False, summary.AddonRow(with_path), {}, ok))
    finally:
        sources.resolve_release, sources.download_release_asset, sources.fetch_commit = saved

    check("asset addon downloads the matching upload", seen.get("asset") == "yunagearopt-1.1.54.zip", seen)
    check("asset addon stages the asset's folder", staged is not None and set(staged.files) == {"yunagearopt.lua", "core.lua", "data.lua"}, staged and sorted(staged.files))
    check("asset addon is labelled by the release", row.tag == "1.1.54" and row.sha == "d" * 40, (row.tag, row.sha))
    check("asset addon's metadata is the entry lua's", staged is not None and staged.metadata["name"] == "yunagearopt", staged and staged.metadata)


def test_vanacore_opt_in():
    main, vana = config.TARGETS[0], config.TARGETS[1]
    yuna = OrderedDict([("name", "yunagearopt"), ("install", "yunagearopt"), ("vanacore", True)])
    seekey = OrderedDict([("name", "Sidekick"), ("install", "Sidekick")])

    check("main takes every addon", main.wants(yuna) and main.wants(seekey))
    check("vanacore takes an addon that opts in", vana.wants(yuna))
    check("vanacore leaves out an addon that doesn't", not vana.wants(seekey))
    check("vanacore opt-in must be true, not truthy", not vana.wants(OrderedDict([("name", "x"), ("vanacore", "no")])))

    side = util.addon_prefix(vana, "Sidekick")
    gear = util.addon_prefix(vana, "yunagearopt")
    side_native = util.addon_prefix(vana, "Sidekick", vana.native_dir)
    gear_native = util.addon_prefix(vana, "yunagearopt", vana.native_dir)
    # A left-out addon is purged from every folder of the build; an Ashita addon the build
    # takes holds nothing under addons\vanacore.
    check(
        "unwanted prefixes name the addons left out, in every folder of the build",
        updater.unwanted_prefixes([seekey, yuna], vana, set()) == [side, side_native, gear_native],
        updater.unwanted_prefixes([seekey, yuna], vana, set()),
    )
    check("unwanted prefixes follow --only", updater.unwanted_prefixes([seekey, yuna], vana, {"yunagearopt"}) == [gear_native])
    check("main has no unwanted prefixes", updater.unwanted_prefixes([seekey, yuna], main, set()) == [])

    def staged(entry, files):
        return updater.StagedAddon(entry, "v1", "abc", files, {}, summary.AddonRow(entry))

    addons = [staged(seekey, {"Sidekick.lua": b"new"}), staged(yuna, {"yunagearopt.lua": b"new"})]
    sibling = util.addon_prefix(vana, "Sidekick2") + "x.lua"
    manifest = OrderedDict(
        [
            ("VanaCore.exe", "aaaaaa"),
            (side + "Sidekick.lua", "111111"),
            (side + "lib" + SEP + "x.lua", "222222"),
            (sibling, "333333"),
            (gear + "yunagearopt.lua", "444444"),
        ]
    )
    plan = updater.build_plan(addons, manifest, vana, [side])
    check("vanacore drops what it had of a left-out addon", plan.purged == [side + "Sidekick.lua", side + "lib" + SEP + "x.lua"], plan.purged)
    check("a dropped addon is not in removed (so not recent_deletes)", plan.removed == [], plan.removed)
    check("a dropped addon is gone from the manifest", not any(k.startswith(side) for k in manifest), list(manifest))
    check("a dropped addon is not uploaded", not any("Sidekick/" in k for k in plan.uploads), list(plan.uploads))
    check("dropping leaves the rest of the build alone", "VanaCore.exe" in manifest and sibling in manifest)
    check("an opted-in addon still publishes", plan.changed == [gear + "yunagearopt.lua"], plan.changed)

    plan = updater.build_plan(addons[:1], OrderedDict([(side + "Sidekick.lua", "111111")]), vana, [side])
    check("a purge alone rewrites the manifest", not plan.empty)
    check("a purge alone moves no recent list or timestamp", plan.purged and not plan.published)

    plan = updater.build_plan(addons, OrderedDict(), main, [])
    check("main still publishes every addon", sorted(plan.added) == ["addons" + SEP + "Sidekick" + SEP + "Sidekick.lua", "addons" + SEP + "yunagearopt" + SEP + "yunagearopt.lua"], plan.added)

    launcher = OrderedDict(
        [
            ("recent_updates", OrderedDict([
                ("main_ashita", ["addons" + SEP + "Sidekick" + SEP + "Sidekick.lua"]),
                ("vanacore_vanacore", [side + "Sidekick.lua", gear + "yunagearopt.lua", sibling]),
            ])),
            ("recent_deletes", OrderedDict([("vanacore_vanacore", [side.lower().replace(SEP, "/") + "old.lua"])])),
        ]
    )
    check("forget_recent reports a change", state.forget_recent(launcher, vana, [side]))
    check("forget_recent clears recent_updates", launcher["recent_updates"]["vanacore_vanacore"] == [gear + "yunagearopt.lua", sibling], launcher["recent_updates"])
    check("forget_recent clears recent_deletes in any case or slash", launcher["recent_deletes"]["vanacore_vanacore"] == [], launcher["recent_deletes"])
    check("forget_recent leaves other builds alone", launcher["recent_updates"]["main_ashita"] == ["addons" + SEP + "Sidekick" + SEP + "Sidekick.lua"])
    check("forget_recent is a no-op the second time", not state.forget_recent(launcher, vana, [side]))
    check("forget_recent with no prefixes is a no-op", not state.forget_recent(launcher, vana, []))


def test_forced_deletes():
    main, vana = config.TARGETS[0], config.TARGETS[1]
    old = "Sidekick" + SEP + "lib" + SEP + "core" + SEP + "afk.lua"
    back = "Sidekick" + SEP + "lib" + SEP + "back.lua"
    main_old = "addons" + SEP + old
    vana_old = "addons" + SEP + "ashita" + SEP + old
    manifests = {
        main.key: OrderedDict([("addons" + SEP + "Sidekick" + SEP + "Sidekick.lua", "111111"), ("addons" + SEP + back, "222222")]),
        vana.key: OrderedDict([("VanaCore.exe", "aaaaaa")]),
    }

    check("the forced list is set", len(config.FORCED_DELETES) > 0 and all("/" not in p for p in config.FORCED_DELETES))

    forced = state.forced_deletes([main, vana], manifests, [old, back])
    check("forced deletes go under each build's Ashita addons folder", forced == {main.key: [main_old], vana.key: [vana_old]}, forced)

    manifests[vana.key]["addons" + SEP + "ashita" + SEP + old.upper()] = "333333"
    check("a path any build ships is left out of every build", state.forced_deletes([main, vana], manifests, [old]) == {main.key: [], vana.key: []})
    del manifests[vana.key]["addons" + SEP + "ashita" + SEP + old.upper()]
    check("only the targets given", list(state.forced_deletes([main], manifests, [old])) == [main.key])

    launcher = OrderedDict(
        [
            ("recent_updates", OrderedDict()),
            ("recent_deletes", OrderedDict([(main.key, ["addons/sidekick/LIB/core/afk.lua", "addons" + SEP + "x.lua"])])),
        ]
    )
    check("record_forced_deletes reports an addition", state.record_forced_deletes(launcher, forced))
    check("one already listed (any case or slash) is left as it is", launcher["recent_deletes"][main.key] == ["addons/sidekick/LIB/core/afk.lua", "addons" + SEP + "x.lua"], launcher["recent_deletes"])
    check("a build without a list gets one", launcher["recent_deletes"][vana.key] == [vana_old], launcher["recent_deletes"])
    check("record_forced_deletes is a no-op the second time", not state.record_forced_deletes(launcher, forced))

    side = util.addon_prefix(vana, "Sidekick")
    launcher["recent_deletes"][vana.key].append(side + "other.lua")
    launcher["recent_updates"][vana.key] = [vana_old]
    check("forget_recent reports what it took", state.forget_recent(launcher, vana, [side], forced[vana.key]))
    check("forget_recent keeps a forced delete", launcher["recent_deletes"][vana.key] == [vana_old], launcher["recent_deletes"])
    check("forget_recent's keep is only for recent_deletes", launcher["recent_updates"][vana.key] == [], launcher["recent_updates"])
    check("so the forced deletes stay put", not state.record_forced_deletes(launcher, forced))

    empty = OrderedDict()
    check("nothing forced, nothing written", not state.record_forced_deletes(empty, {main.key: []}) and "recent_deletes" not in empty)


# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Pinned commits: git's own files, the approval check, DETECT's pull request
# ---------------------------------------------------------------------------


def _git_repo(files, symlinks=()):
    import subprocess
    import tempfile

    work = tempfile.mkdtemp(prefix="addon-test-")
    run = lambda *a: subprocess.run(["git", *a], cwd=work, check=True, capture_output=True)  # noqa: E731
    run("init", "-q")
    for name, data in files.items():
        path = os.path.join(work, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)
    for name, target in symlinks:
        path = os.path.join(work, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        os.symlink(target, path)
    run("add", "-A")
    run("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "c")
    sha = subprocess.run(["git", "rev-parse", "HEAD"], cwd=work, capture_output=True, text=True).stdout.strip()
    return work, sha


def test_pinned_git():
    check("a full hash is a pin", sources.is_sha("a" * 40))
    check("a short or upper-case hash is not", not sources.is_sha("a" * 7) and not sources.is_sha("A" * 40))
    expect_reject("fetch_commit refuses a branch name", lambda: sources.fetch_commit("", "acme", "Demo", "main", "Demo.lua"))

    attr = b"secret.lua export-ignore\n"
    work, sha = _git_repo({
        "Demo/Demo.lua": GOOD_LUA, "Demo/lib/x.lua": b"-- x", "Demo/secret.lua": b"-- dev only",
        ".gitattributes": attr, "README.md": b"readme",
    })
    root, files = sources.archive_files(work, sha, "acme-Demo-abc1234", "Demo.lua", "Demo")
    check("archive_files finds the addon root", root == "acme-Demo-abc1234/Demo", root)
    check("archive_files takes the folder's files only", set(files) == {"Demo.lua", "lib/x.lua"}, sorted(files))
    check("the repo's export-ignore is honoured, as in its zipball", "secret.lua" not in files)
    check("bytes are the commit's", files["Demo.lua"] == GOOD_LUA)

    work, sha = _git_repo({"Demo/Demo.lua": GOOD_LUA}, symlinks=[("Demo/link.lua", "/etc/passwd")])
    expect_reject("a symlink in the addon's folder", lambda: sources.archive_files(work, sha, "w", "Demo.lua"))


class FakeGitHub:
    def __init__(self, files, reviews):
        self.files, self.reviews = files, reviews

    def file_at(self, path, ref):
        return self.files[ref]

    def pages(self, path):
        return self.reviews


def test_approvals():
    import approvals

    owners = approvals.owners_of("# x\n/addons.json @CarverXI @vekien @org/team\n*.md @someone\n")
    check("CODEOWNERS: the users named for addons.json", owners == ["carverxi", "vekien"], owners)
    check("CODEOWNERS: nobody when it isn't listed", approvals.owners_of("*.md @someone\n") == [])

    pin, head = "a" * 40, "h" * 40
    pinned = '[{"name": "Demo", "commit": "%s"}]' % pin
    other = '[{"name": "Demo", "commit": "%s"}]' % ("b" * 40)
    pull = {"number": 7, "merged_at": "2026-11-17", "base": {"ref": "main"}, "user": {"login": "github-actions[bot]"}, "head": {"sha": head}}

    def verdict(reviews, files=None, **change):
        gh = FakeGitHub(files or {head: pinned}, reviews)
        return approvals.check_pull(gh, dict(pull, **change), "Demo", pin, ["carverxi", "vekien"])

    approve = lambda who, at=head, state="APPROVED": {"user": {"login": who}, "state": state, "commit_id": at}  # noqa: E731
    check("an owner's approval of the final head passes", verdict([approve("CarverXI")]) is None)
    check("an approval of an earlier push doesn't", verdict([approve("CarverXI", at="0" * 40)]) is not None)
    check("an approval later withdrawn doesn't", verdict([approve("CarverXI"), approve("CarverXI", state="CHANGES_REQUESTED")]) is not None)
    check("a non-owner's approval doesn't", verdict([approve("loxleygames")]) is not None)
    check("the author's own approval doesn't", verdict([approve("vekien")], user={"login": "vekien"}) is not None)
    check("an unmerged pull request doesn't", verdict([approve("CarverXI")], merged_at=None) is not None)
    check("one merged elsewhere doesn't", verdict([approve("CarverXI")], base={"ref": "dev"}) is not None)
    check("one whose head pinned another commit doesn't", verdict([approve("CarverXI")], files={head: other}) is not None)

    # The commit that set the pin: the oldest of the run that pins it, from HEAD back.
    import subprocess
    import tempfile

    work = tempfile.mkdtemp(prefix="pin-test-")
    run = lambda *a: subprocess.run(["git", *a], cwd=work, check=True, capture_output=True)  # noqa: E731
    run("init", "-q")
    shas = []
    for i, body in enumerate([other, pinned, pinned.replace("]", ', {"name": "Other", "commit": ""}]')]):
        with open(os.path.join(work, "addons.json"), "w") as f:
            f.write(body)
        run("add", "-A")
        run("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", f"c{i}")
        shas.append(subprocess.run(["git", "rev-parse", "HEAD"], cwd=work, capture_output=True, text=True).stdout.strip())
    found = approvals.introducing_commit(work, "Demo", pin)
    check("the pin is traced to the commit that set it, not a later one", found == shas[1], (found, shas))
    expect_reject("a pin HEAD doesn't hold", lambda: approvals.introducing_commit(work, "Demo", "c" * 40))


def main():
    # The modules narrate what they are doing, which is useful in a real run and
    # just noise here. Quieten them so a failure is the only thing on screen.
    vetting.info = lambda *_args, **_kwargs: None
    sources.info = lambda *_args, **_kwargs: None
    state.info = lambda *_args, **_kwargs: None
    state.warn = lambda *_args, **_kwargs: None
    updater.info = lambda *_args, **_kwargs: None

    test_safety()
    test_lua_meta()
    test_hashing()
    test_manifest()
    test_targets()
    test_vanacore_opt_in()
    test_forced_deletes()
    test_native_asset()
    test_branch_source()
    test_pinned_git()
    test_approvals()
    test_serialisation()
    test_recent_lists()
    test_self_update()
    test_summary()

    passed = sum(1 for ok, _, _ in RESULTS if ok)
    failures = [r for r in RESULTS if not r[0]]

    for ok, label, detail in RESULTS:
        if not ok:
            print(f"  FAIL  {label:52} {detail}")

    print(f"\n{passed}/{len(RESULTS)} checks passed")
    if failures:
        print(f"::error::{len(failures)} addon updater self-check(s) failed")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
