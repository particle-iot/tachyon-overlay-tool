import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import subprocess
import overlay


class OfflineRPMTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory()
        self.addCleanup(self.root.cleanup)
        self.addCleanup(setattr, overlay, "package_manager", "apt")
        self.addCleanup(setattr, overlay, "rpm_repo", None)
        overlay.package_manager = "rpm-offline"
        overlay.rpm_repo = "/tmp/rpms"
        metadata = Path(self.root.name) / "tmp/rpms/repodata/repomd.xml"
        metadata.parent.mkdir(parents=True)
        metadata.touch()

    @patch("overlay.subprocess.run")
    def test_only_local_repository_enabled(self, run):
        overlay.install_package(self.root.name, "", "particle-linux-0.25.2-1.aarch64 jq")
        command = run.call_args.args[0]
        self.assertIn("--disablerepo=*", command)
        self.assertIn("--setopt=reposdir=/dev/null", command)
        self.assertIn("--repofrompath=particle-build,file:///tmp/rpms", command)
        self.assertEqual(command[-2:], ["particle-linux-0.25.2-1.aarch64", "jq"])
        self.assertTrue(run.call_args.kwargs["check"])

    @patch("overlay.subprocess.run", side_effect=subprocess.CalledProcessError(1, "dnf"))
    def test_missing_dependency_is_fatal(self, run):
        with self.assertRaises(subprocess.CalledProcessError):
            overlay.install_package(self.root.name, "", "missing")
        self.assertEqual(run.call_count, 1)

    @patch("overlay.subprocess.run")
    def test_refuses_external_source_and_options(self, run):
        for value in ["https://example.com/a.rpm", "--enablerepo=external", "jq; reboot"]:
            with self.assertRaises(ValueError):
                overlay.install_package(self.root.name, "", value)
        run.assert_not_called()

    @patch("overlay.subprocess.run")
    def test_requires_metadata(self, run):
        overlay.rpm_repo = "/missing"
        with self.assertRaises(ValueError):
            overlay.install_package(self.root.name, "", "jq")
        run.assert_not_called()

    @patch("overlay.subprocess.run")
    def test_ubuntu_default_still_uses_apt(self, run):
        overlay.package_manager = "apt"
        overlay.install_package(self.root.name, "", "jq=1.7.1")
        self.assertIn("apt-get", run.call_args.args[0])
