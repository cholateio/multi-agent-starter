import hashlib
import io
import os
import tarfile

from tests.unit._helpers import IsolatedTestCase
from cli import doctor, paths


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


class TestToolsAndPlatform(IsolatedTestCase):
    def setUp(self):
        super().setUp()
        os.environ["KIT_CACHE_HOME"] = str(self.tmp / "cache")
        self._path = os.environ.get("PATH", "")
        os.environ["PATH"] = str(self.tmp / "emptybin")

    def tearDown(self):
        os.environ["PATH"] = self._path
        super().tearDown()

    def fake_tool(self, d, name, version):
        d.mkdir(parents=True, exist_ok=True)
        (d / name).write_text(f"#!/bin/sh\necho {version}\n")
        (d / name).chmod(0o755)
        return d / name

    def test_install_refuses_unsupported_platform(self):
        """Review O1: only linux/x86_64 binaries are pinned — refuse elsewhere, never install a dead binary."""
        called = []
        orig_plat, orig_inst = doctor.platform_ok, doctor.install_tool
        doctor.platform_ok = lambda: (False, "darwin/arm64")
        doctor.install_tool = lambda *a, **k: called.append(a)
        logs = []
        try:
            ok = doctor.install_missing(self.tmp / "bin", log=logs.append)
        finally:
            doctor.platform_ok, doctor.install_tool = orig_plat, orig_inst
        self.assertFalse(ok)
        self.assertEqual(called, [])
        self.assertTrue(any("linux/x86_64" in l and "darwin/arm64" in l for l in logs), logs)

    def test_unsupported_platform_with_tools_already_present_is_fine(self):
        self.fake_tool(self.home / ".local" / "bin", "gitleaks", "8.30.1")
        self.fake_tool(self.home / ".local" / "bin", "osv-scanner", "2.7.0")
        orig = doctor.platform_ok
        doctor.platform_ok = lambda: (False, "darwin/arm64")
        try:
            self.assertTrue(doctor.install_missing(paths.tools_dir(), log=lambda m: None))
        finally:
            doctor.platform_ok = orig

    def test_tools_dir_resolver(self):
        """Review O3/F13: one resolver — config.toml tools_dir (default ~/.local/bin), then PATH."""
        self.assertEqual(paths.tools_dir(), self.home / ".local" / "bin")
        cfg = paths.config_path()
        cfg.parent.mkdir(parents=True)
        cfg.write_text('kit_root = "/x"\ntools_dir = "~/tools"\n')
        self.assertEqual(paths.tools_dir(), self.home / "tools")
        self.assertIsNone(paths.find_tool("gitleaks"))
        exe = self.fake_tool(self.home / "tools", "gitleaks", "8.30.1")
        self.assertEqual(paths.find_tool("gitleaks"), str(exe))
        self.assertEqual(doctor.tool_version("gitleaks"), "8.30.1")

    def test_set_config_value(self):
        cfg = paths.config_path()
        cfg.parent.mkdir(parents=True)
        cfg.write_text('# head\nkit_root = "/x"\n\n[audit]\nroot = "~"\n')
        paths.set_config_value("tools_dir", "/opt/t")
        self.assertIn('tools_dir = "/opt/t"', cfg.read_text())
        paths.set_config_value("tools_dir", "/opt/u")
        text = cfg.read_text()
        self.assertEqual(text.count("tools_dir"), 1)
        self.assertLess(text.index("tools_dir"), text.index("[audit]"))
        self.assertEqual(paths.load_config()["tools_dir"], "/opt/u")

    def test_find_tool_never_uses_path(self):
        """Review R3-1: the resolver never trusts the caller's PATH (a fake gitleaks there would
        turn R1 off) — only tools_dir or an absolute <tool>_path recorded by setup / doctor."""
        os.environ["PATH"] = str(self.tmp / "fakebin")
        self.fake_tool(self.tmp / "fakebin", "gitleaks", "8.30.1")
        self.assertIsNone(paths.find_tool("gitleaks"))
        self.assertIsNone(doctor.tool_version("gitleaks"))
        cfg = paths.config_path()
        cfg.parent.mkdir(parents=True)
        cfg.write_text('kit_root = "/x"\ngitleaks_path = "fakebin/gitleaks"\n')
        self.assertIsNone(paths.find_tool("gitleaks"), "a relative recorded path is ignored")
        exe = self.fake_tool(self.tmp / "elsewhere", "osv-scanner", "2.7.0")
        cfg.write_text(f'kit_root = "/x"\nosv_scanner_path = "{exe}"\n')
        self.assertEqual(paths.find_tool("osv-scanner"), str(exe))

    def test_relative_tools_dir_is_ignored(self):
        cfg = paths.config_path()
        cfg.parent.mkdir(parents=True)
        cfg.write_text('tools_dir = "tools"\n')
        self.assertEqual(paths.tools_dir(), self.home / ".local" / "bin")

    def test_install_missing_records_a_pinned_version_found_on_path(self):
        """Review R3-1: a correct-version tool on PATH at setup / doctor --install time is recorded
        as an absolute <tool>_path (after the version check) instead of being re-downloaded."""
        gl = self.fake_tool(self.tmp / "pathbin", "gitleaks", "8.30.1")
        osv = self.fake_tool(self.tmp / "pathbin", "osv-scanner", "2.7.0")
        os.environ["PATH"] = str(self.tmp / "pathbin")
        called = []
        orig = doctor.install_tool
        doctor.install_tool = lambda *a, **k: called.append(a)
        try:
            self.assertTrue(doctor.install_missing(paths.tools_dir(), log=lambda m: None))
        finally:
            doctor.install_tool = orig
        self.assertEqual(called, [])
        cfg = paths.load_config()
        self.assertEqual(cfg.get("gitleaks_path"), str(gl))
        self.assertEqual(cfg.get("osv_scanner_path"), str(osv))
        os.environ["PATH"] = str(self.tmp / "emptybin")
        self.assertEqual(paths.find_tool("gitleaks"), str(gl))

    def test_install_missing_does_not_record_a_wrong_version_on_path(self):
        self.fake_tool(self.tmp / "pathbin", "gitleaks", "1.0.0")
        os.environ["PATH"] = str(self.tmp / "pathbin")
        orig_inst, orig_plat = doctor.install_tool, doctor.platform_ok
        doctor.install_tool = lambda pin, d: (_ for _ in ()).throw(OSError("offline"))
        try:
            self.assertFalse(doctor.install_missing(paths.tools_dir(), log=lambda m: None))
        finally:
            doctor.install_tool, doctor.platform_ok = orig_inst, orig_plat
        self.assertNotIn("gitleaks_path", paths.load_config())

    def _doctor_install(self, bin_dir, ok=True):
        import argparse
        orig_inst, orig_checks = doctor.install_missing, doctor.run_checks
        doctor.install_missing = lambda d, log=print: ok
        doctor.run_checks = lambda: doctor.Report()
        try:
            return doctor.run(argparse.Namespace(install=True, bin_dir=bin_dir))
        finally:
            doctor.install_missing, doctor.run_checks = orig_inst, orig_checks

    def test_set_config_value_without_trailing_newline(self):
        """Review R3-6: inserting a key after a last line without a newline keeps valid TOML."""
        cfg = paths.config_path()
        cfg.parent.mkdir(parents=True)
        cfg.write_text('kit_root = "/x"\nprofile = "full"')
        paths.set_config_value("tools_dir", "/opt/t")
        self.assertEqual(paths.load_config(), {"kit_root": "/x", "profile": "full", "tools_dir": "/opt/t"})

    def test_doctor_install_relative_bin_dir_is_persisted_absolute(self):
        """Review R3-5: the guard reads tools_dir from any cwd — never record a relative one."""
        cwd = os.getcwd()
        os.chdir(self.tmp)
        try:
            self._doctor_install("tools")
        finally:
            os.chdir(cwd)
        self.assertEqual(paths.load_config().get("tools_dir"), str(self.tmp / "tools"))

    def test_doctor_install_failure_keeps_tools_dir(self):
        """Review R3-7: a failed install into a new --bin-dir must not move tools_dir away from a working one."""
        cfg = paths.config_path()
        cfg.parent.mkdir(parents=True)
        cfg.write_text(f'tools_dir = "{self.tmp / "old"}"\n')
        self.assertEqual(self._doctor_install(str(self.tmp / "new"), ok=False), 1)
        self.assertEqual(paths.load_config().get("tools_dir"), str(self.tmp / "old"))
        self._doctor_install(str(self.tmp / "new"), ok=True)
        self.assertEqual(paths.load_config().get("tools_dir"), str(self.tmp / "new"))
