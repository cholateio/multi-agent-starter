import hashlib
import io
import os
import tarfile

from tests.unit._helpers import IsolatedTestCase
from cli import doctor


def make_tgz(path, member, payload: bytes):
    with tarfile.open(path, "w:gz") as tf:
        info = tarfile.TarInfo(member)
        info.size = len(payload)
        info.mode = 0o755
        tf.addfile(info, io.BytesIO(payload))
        readme = b"readme"
        i2 = tarfile.TarInfo("README.md")
        i2.size = len(readme)
        tf.addfile(i2, io.BytesIO(readme))


class TestDoctor(IsolatedTestCase):
    def setUp(self):
        super().setUp()
        os.environ["KIT_CACHE_HOME"] = str(self.tmp / "cache")
        self.dest = self.tmp / "bin"

    def test_install_tool_tar_gz_from_file_url(self):
        tgz = self.tmp / "tool.tar.gz"
        make_tgz(tgz, "faketool", b"#!/bin/sh\necho 1.0\n")
        sha = hashlib.sha256(tgz.read_bytes()).hexdigest()
        pin = doctor.ToolPin("faketool", "1.0", tgz.as_uri(), sha, "tar.gz", "faketool",
                             hashlib.sha256(b"#!/bin/sh\necho 1.0\n").hexdigest())
        out = doctor.install_tool(pin, self.dest)
        self.assertEqual(out, self.dest / "faketool")
        self.assertEqual(out.read_bytes(), b"#!/bin/sh\necho 1.0\n")
        self.assertEqual(out.stat().st_mode & 0o777, 0o755)
        self.assertFalse((self.dest / "README.md").exists())

    def test_install_tool_raw(self):
        raw = self.tmp / "rawtool"
        raw.write_bytes(b"binary")
        pin = doctor.ToolPin("rawtool", "2.0", raw.as_uri(), hashlib.sha256(b"binary").hexdigest(), "raw", None)
        self.assertEqual(doctor.install_tool(pin, self.dest).read_bytes(), b"binary")

    def test_sha_mismatch_raises_and_installs_nothing(self):
        raw = self.tmp / "rawtool"
        raw.write_bytes(b"tampered")
        pin = doctor.ToolPin("rawtool", "2.0", raw.as_uri(), "0" * 64, "raw", None)
        with self.assertRaises(doctor.PinMismatch) as cm:
            doctor.install_tool(pin, self.dest)
        self.assertIn("000000000000", str(cm.exception))
        self.assertFalse((self.dest / "rawtool").exists())
        self.assertEqual(list((self.tmp / "cache" / "downloads").glob("*")), [])

    def test_member_sha_mismatch_raises(self):
        tgz = self.tmp / "tool.tar.gz"
        make_tgz(tgz, "faketool", b"payload")
        pin = doctor.ToolPin("faketool", "1.0", tgz.as_uri(), hashlib.sha256(tgz.read_bytes()).hexdigest(),
                             "tar.gz", "faketool", "f" * 64)
        with self.assertRaises(doctor.PinMismatch):
            doctor.install_tool(pin, self.dest)
        self.assertFalse((self.dest / "faketool").exists())

    def test_versions(self):
        self.assertEqual(doctor.parse_claude_version("2.1.303 (Claude Code)"), (2, 1, 303))
        self.assertIsNone(doctor.parse_claude_version("garbage"))
        self.assertFalse(doctor.check_min_version((2, 1, 276)))
        self.assertTrue(doctor.check_min_version((2, 1, 277)))
        self.assertTrue(doctor.check_min_version((3, 0, 0)))

    def test_pins_are_real_and_pinned(self):
        g, o = doctor.TOOL_PINS["gitleaks"], doctor.TOOL_PINS["osv-scanner"]
        self.assertEqual((g.version, g.archive, g.member), ("8.30.1", "tar.gz", "gitleaks"))
        self.assertEqual((o.version, o.archive), ("2.7.0", "raw"))
        for p in (g, o):
            self.assertRegex(p.sha256, r"^[0-9a-f]{64}$")
            self.assertTrue(p.url.startswith("https://github.com/"))
