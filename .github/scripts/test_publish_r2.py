#!/usr/bin/env python3
"""Self-check for publish_r2.py against an R2 held in memory: python .github/scripts/test_publish_r2.py

Run by the workflow before it publishes, so a broken diff or a loosened check stops the run with R2 untouched.
"""
import gzip
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import publish_r2 as p  # noqa: E402

STATE_KEY = "launcher/build_vanacore_vanacore.gz"
FOLDER = "builds/vanacore/VanaCore"

# VanaCore's own files, which a publish must leave exactly as they are
VANACORE_OWN = {
    "VanaCore.exe": "aaaaaa",
    "addons\\vanacore\\vana\\vana.lua": "bbbbbb",
    "addons\\ashita\\yunagearopt\\yunagearopt.lua": "cccccc",
}


class FakeR2:
    def __init__(self):
        self.objects = {}
        self.puts = []
        self.on_put = None

    def get(self, key):
        return self.objects.get(key)

    def put(self, key, data=None, path=None, content_type=None):
        if path is not None:
            with open(path, "rb") as f:
                data = f.read()
        self.objects[key] = data
        self.puts.append(key)
        if self.on_put:
            hook, self.on_put = self.on_put, None
            hook(self, key)

    # helpers
    def launcher(self):
        return json.loads(self.objects[p.KEY_LAUNCHER].decode("utf-8"))

    def state(self, key=STATE_KEY):
        return p.parse_state(self.objects[key])

    def set_launcher(self, launcher):
        self.objects[p.KEY_LAUNCHER] = p.dumps(launcher).encode("utf-8")

    def set_state(self, state, key=STATE_KEY):
        self.objects[key] = p.make_state(state)


def seed(r2, extra_builds=()):
    builds = [
        {"name": "ashita", "tag": "main", "folder": "builds\\main\\Ashita", "updated": 1.0},
        {"name": "vanacore", "tag": "vanacore", "folder": "builds\\vanacore\\VanaCore", "updated": 1.0},
    ] + list(extra_builds)
    r2.set_launcher({"builds": builds,
                     "recent_updates": {"vanacore_vanacore": ["VanaCore.exe"], "main_ashita": ["x.lua"]},
                     "recent_deletes": {}})
    r2.set_state(dict(VANACORE_OWN))


class Base(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.r2 = FakeR2()
        seed(self.r2)
        self.write("partyfinder-vanacore/partyfinder-vanacore.lua", "addon.name    = 'partyfinder-vanacore'\n")
        self.write("partyfinder-vanacore/images/bell.png", "png")
        self.write("partyfinder-vanacore/.gitignore", "x")
        self.write("auctionhouse-vanacore/auctionhouse-vanacore.lua", "addon.name = \"auctionhouse-vanacore\"\n")

    def tearDown(self):
        shutil.rmtree(self.root)

    def write(self, rel, text):
        full = os.path.join(self.root, *rel.split("/"))
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", newline="") as f:
            f.write(text)

    def remove(self, rel):
        os.remove(os.path.join(self.root, *rel.split("/")))

    def run_publish(self, only=(), tags=("vanacore",), dry_run=False, now=100):
        addons = p.gather(self.root, list(only))
        return p.publish(self.r2, {}, addons, list(tags), dry_run=dry_run, now=now)


class Checks(Base):
    def problems(self):
        with self.assertRaises(p.Stop) as e:
            p.gather(self.root, [])
        return str(e.exception)

    def test_executable_refused(self):
        self.write("partyfinder-vanacore/tool.exe", "MZ")
        self.assertIn(".exe isn't a type", self.problems())

    def test_hash_in_name_refused(self):
        self.write("partyfinder-vanacore/a#b.png", "x")
        self.assertIn("the name has one of", self.problems())

    def test_entry_lua_needed(self):
        self.remove("auctionhouse-vanacore/auctionhouse-vanacore.lua")
        self.write("auctionhouse-vanacore/main.lua", "addon.name = 'auctionhouse-vanacore'")
        self.assertIn("no auctionhouse-vanacore.lua", self.problems())

    def test_entry_lua_names_the_folder(self):
        self.write("auctionhouse-vanacore/auctionhouse-vanacore.lua", "addon.name = 'ah'\n")
        self.assertIn("addon.name is 'ah'", self.problems())

    def test_unknown_only(self):
        with self.assertRaises(p.Stop):
            p.gather(self.root, ["nope"])

    def test_dotfiles_skipped(self):
        addons = p.gather(self.root, ["partyfinder-vanacore"])
        self.assertEqual(sorted(addons[0].files), ["images\\bell.png", "partyfinder-vanacore.lua"])

    def test_hash_matches_launcher(self):
        # Utils.GetFileHash: SHA1 of the bytes, first 6 hex
        addons = p.gather(self.root, ["partyfinder-vanacore"])
        self.assertEqual(addons[0].hashes["images\\bell.png"], "9040a7")


class Publish(Base):
    def test_first_publish(self):
        self.assertEqual(self.run_publish(), 0)
        state = self.r2.state()
        for k, v in VANACORE_OWN.items():
            self.assertEqual(state[k], v)
        self.assertIn("addons\\vanacore\\partyfinder-vanacore\\images\\bell.png", state)
        self.assertNotIn("addons\\vanacore\\partyfinder-vanacore\\.gitignore", state)
        self.assertEqual(self.r2.objects[f"{FOLDER}/addons/vanacore/partyfinder-vanacore/images/bell.png"], b"png")
        launcher = self.r2.launcher()
        vc = launcher["recent_updates"]["vanacore_vanacore"]
        self.assertEqual(vc[0], "VanaCore.exe")
        self.assertIn("addons\\vanacore\\auctionhouse-vanacore\\auctionhouse-vanacore.lua", vc)
        self.assertEqual(launcher["builds"][1]["updated"], 100.0)
        self.assertEqual(launcher["builds"][0]["updated"], 1.0)    # other builds keep their cache-buster
        self.assertEqual(launcher["recent_updates"]["main_ashita"], ["x.lua"])
        # Files first, then launcher.json, then the state
        self.assertEqual(self.r2.puts[-2:], [p.KEY_LAUNCHER, STATE_KEY])

    def test_rerun_writes_nothing(self):
        self.run_publish()
        self.r2.puts.clear()
        self.assertEqual(self.run_publish(now=200), 0)
        self.assertEqual(self.r2.puts, [])

    def test_dry_run_writes_nothing(self):
        self.assertEqual(self.run_publish(dry_run=True), 0)
        self.assertEqual(self.r2.puts, [])

    def test_change_uploads_only_that_file(self):
        self.run_publish()
        self.r2.puts.clear()
        self.write("partyfinder-vanacore/images/bell.png", "png2")
        self.run_publish(now=200)
        self.assertEqual(self.r2.puts, [f"{FOLDER}/addons/vanacore/partyfinder-vanacore/images/bell.png",
                                        p.KEY_LAUNCHER, STATE_KEY])
        self.assertEqual(self.r2.launcher()["builds"][1]["updated"], 200.0)

    def test_removed_file_listed_then_readded(self):
        self.run_publish()
        self.remove("partyfinder-vanacore/images/bell.png")
        self.run_publish(now=200)
        path = "addons\\vanacore\\partyfinder-vanacore\\images\\bell.png"
        self.assertNotIn(path, self.r2.state())
        self.assertEqual(self.r2.launcher()["recent_deletes"]["vanacore_vanacore"], [path])
        self.write("partyfinder-vanacore/images/bell.png", "png")
        self.run_publish(now=300)
        self.assertIn(path, self.r2.state())
        self.assertNotIn("vanacore_vanacore", self.r2.launcher()["recent_deletes"])

    def test_case_rename_not_deleted(self):
        self.run_publish()
        self.remove("partyfinder-vanacore/images/bell.png")
        self.write("partyfinder-vanacore/images/Bell.png", "png")
        self.run_publish(now=200)
        state = self.r2.state()
        self.assertIn("addons\\vanacore\\partyfinder-vanacore\\images\\Bell.png", state)
        self.assertNotIn("addons\\vanacore\\partyfinder-vanacore\\images\\bell.png", state)
        self.assertNotIn("vanacore_vanacore", self.r2.launcher()["recent_deletes"])

    def test_only_touches_that_addon(self):
        self.run_publish()
        self.remove("auctionhouse-vanacore/auctionhouse-vanacore.lua")
        self.write("partyfinder-vanacore/images/bell.png", "png2")
        self.run_publish(only=["partyfinder-vanacore"], now=200)
        self.assertIn("addons\\vanacore\\auctionhouse-vanacore\\auctionhouse-vanacore.lua", self.r2.state())

    def test_other_writer_kept(self):
        # The Manager pushes while the files are going up: its state entry and launcher.json edit must survive
        def other(r2, key):
            launcher = r2.launcher()
            launcher["recent_updates"]["main_ashita"].append("y.lua")
            r2.set_launcher(launcher)
            state = r2.state()
            state["VanaCore.exe"] = "dddddd"
            r2.set_state(state)
        self.r2.on_put = other
        self.assertEqual(self.run_publish(), 0)
        self.assertEqual(self.r2.state()["VanaCore.exe"], "dddddd")
        self.assertIn("addons\\vanacore\\partyfinder-vanacore\\images\\bell.png", self.r2.state())
        self.assertEqual(self.r2.launcher()["recent_updates"]["main_ashita"], ["x.lua", "y.lua"])

    def test_missing_build_stops(self):
        with self.assertRaises(p.Stop):
            self.run_publish(tags=["vanacore-beta"])
        self.assertEqual(self.r2.puts, [])

    def test_two_tags(self):
        launcher = self.r2.launcher()
        launcher["builds"].append({"name": "vanacore", "tag": "beta", "folder": "builds\\beta\\VanaCore", "updated": 1.0})
        self.r2.set_launcher(launcher)
        self.r2.set_state({}, "launcher/build_beta_vanacore.gz")
        self.run_publish(tags=["vanacore", "beta"])
        self.assertIn("builds/beta/VanaCore/addons/vanacore/partyfinder-vanacore/images/bell.png", self.r2.objects)
        self.assertIn("addons\\vanacore\\partyfinder-vanacore\\images\\bell.png",
                      self.r2.state("launcher/build_beta_vanacore.gz"))

    def test_recent_updates_capped_without_cutting_a_long_list(self):
        launcher = self.r2.launcher()
        launcher["recent_updates"]["vanacore_vanacore"] = [f"f{i}" for i in range(p.MAX_RECENT + 10)]
        self.r2.set_launcher(launcher)
        self.run_publish()
        self.assertEqual(len(self.r2.launcher()["recent_updates"]["vanacore_vanacore"]), p.MAX_RECENT + 10)

    def test_state_format(self):
        # The Manager's: path=hash lines joined by \n, no trailing newline, gzipped
        self.run_publish()
        text = gzip.decompress(self.r2.objects[STATE_KEY]).decode("utf-8")
        self.assertFalse(text.endswith("\n"))
        self.assertNotIn("\r", text)
        self.assertTrue(text.startswith("VanaCore.exe=aaaaaa\n"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
