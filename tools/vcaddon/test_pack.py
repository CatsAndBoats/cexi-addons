#!/usr/bin/env python3
"""Tests for pack.py: packing an addon folder, and --check refusing what VanaCore's installer refuses.

    python3 test_pack.py

The same hostile packages were run through VanaCore's own installer (src/core/addonpkg.cpp) when it was written; this
keeps pack.py's checks in step with it.
"""

from __future__ import annotations

import json
import os
import struct
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pack  # noqa: E402

LUA = b"addon.name = 'demo'\naddon.version = '2.0'\naddon.author = 'Tester'\naddon.desc = 'A demo addon.'\n"
MANIFEST = json.dumps({"format": 1, "name": "demo", "version": "2.0", "title": "Demo"}).encode()


def make(path: str, entries: list[tuple], method: int = zipfile.ZIP_DEFLATED) -> str:
    with zipfile.ZipFile(path, "w", method) as z:
        for name, data, *mode in entries:
            info = zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0))
            info.compress_type = method
            if mode:
                info.create_system, info.external_attr = 3, mode[0] << 16
            z.writestr(info, data)
    return path


class Pack(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.root = self.dir.name

    def tearDown(self) -> None:
        self.dir.cleanup()

    def folder(self, files: dict[str, bytes]) -> str:
        top = os.path.join(self.root, "src", "demo")
        for rel, data in files.items():
            full = os.path.join(top, *rel.split("/"))
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "wb") as f:
                f.write(data)
        return top

    def test_pack_is_deterministic_and_checks(self) -> None:
        top = self.folder({"demo.lua": LUA, "img/a.png": b"\x89PNG", ".git/x": b"", "Thumbs.db": b""})
        a = pack.pack(top, os.path.join(self.root, "a"), "Demo")
        b = pack.pack(top, os.path.join(self.root, "b"), "Demo")
        with open(a, "rb") as fa, open(b, "rb") as fb:
            self.assertEqual(fa.read(), fb.read())
        m = pack.check(a)
        self.assertEqual((m["name"], m["version"], m["title"], m["files"]), ("demo", "2.0", "Demo", 2))
        with zipfile.ZipFile(a) as z:
            self.assertEqual(sorted(z.namelist()), ["addon.json", "demo/demo.lua", "demo/img/a.png"])

    def test_pack_refuses(self) -> None:
        cases = {
            "a .dll": {"demo.lua": LUA, "x.dll": b"MZ"},
            "no main file": {"other.lua": LUA},
            "addon.name not the folder": {"demo.lua": b"addon.name = 'other'\naddon.version = '1'\n"},
            "no version": {"demo.lua": b"addon.name = 'demo'\n"},
            "a device name": {"demo.lua": LUA, "con.txt": b""},
        }
        for why, files in cases.items():
            with self.subTest(why):
                with tempfile.TemporaryDirectory() as d:
                    self.root = d
                    with self.assertRaises(pack.Problem):
                        pack.pack(self.folder(files), d)

    def test_check_refuses_hostile_packages(self) -> None:
        base = [("addon.json", MANIFEST), ("demo/demo.lua", LUA)]
        cases = {
            "dot-dot": base + [("demo/../../evil.lua", b"x")],
            "absolute": base + [("/etc/evil.lua", b"x")],
            "drive": base + [("C:/evil.lua", b"x")],
            "backslash": base + [("demo\\..\\..\\evil.lua", b"x")],
            "stream": base + [("demo/x.txt:evil", b"x")],
            "other folder": base + [("vana/vana.lua", b"x")],
            "device": base + [("demo/nul.txt", b"x")],
            "dll": base + [("demo/payload.dll", b"MZ")],
            "symlink": base + [("demo/link.txt", b"/etc/passwd", 0o120777)],
            "case twin": base + [("demo/A.lua", b"1"), ("demo/a.lua", b"2")],
            "no main": [("addon.json", MANIFEST), ("demo/other.lua", LUA)],
            "reserved": [("addon.json", json.dumps({"name": "vana", "version": "1"}).encode()), ("vana/vana.lua", LUA)],
        }
        for why, entries in cases.items():
            with self.subTest(why):
                path = make(os.path.join(self.root, why + ".vcaddon"), entries)
                with self.assertRaises(pack.Problem):
                    pack.check(path)

    def test_check_refuses_a_lying_size(self) -> None:
        path = make(os.path.join(self.root, "bomb.vcaddon"),
                    [("addon.json", MANIFEST), ("demo/demo.lua", LUA), ("demo/big.txt", b"A" * 100000)])
        with open(path, "rb") as f:
            data = bytearray(f.read())
        central = data.rfind(b"PK\x01\x02")  # the last central entry: big.txt
        struct.pack_into("<I", data, central + 24, 10)  # its unpacked size: 10
        with open(path, "wb") as f:
            f.write(data)
        with self.assertRaises((pack.Problem, zipfile.BadZipFile)):
            pack.check(path)

    def test_check_takes_a_finder_zip(self) -> None:
        path = make(os.path.join(self.root, "finder.vcaddon"),
                    [("demo/", b""), ("demo/demo.lua", LUA), ("__MACOSX/demo/._demo.lua", b"x"), ("demo/.DS_Store", b"x")])
        self.assertEqual(pack.check(path)["name"], "demo")


if __name__ == "__main__":
    unittest.main()
