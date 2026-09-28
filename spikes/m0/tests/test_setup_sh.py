import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SETUP_SCRIPT = Path(__file__).resolve().parents[3] / "setup.sh"


class SetupShellTests(unittest.TestCase):
    def test_installs_venv_support_when_python_already_exists(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copyfile(SETUP_SCRIPT, root / "setup.sh")
            fake_bin = root / "bin"
            fake_bin.mkdir()
            marker = root / "venv-installed"
            apt_log = root / "apt.log"

            (fake_bin / "python3.12").write_text(
                "#!/bin/sh\n"
                'if [ "$1" = -c ]; then exit 0; fi\n'
                'if [ "$1" = -m ] && [ "$2" = ensurepip ]; then\n'
                '  [ -e "$FAKE_VENV_MARKER" ]; exit $?\n'
                "fi\n"
                "exit 77\n"
            )
            (fake_bin / "apt-get").write_text(
                "#!/bin/sh\n"
                'printf \'%s\\n\' "$*" >> "$FAKE_APT_LOG"\n'
                'if [ "$1" = install ]; then : > "$FAKE_VENV_MARKER"; fi\n'
            )
            (fake_bin / "sudo").write_text('#!/bin/sh\nexec "$@"\n')
            for tool in ("c++", "ninja"):
                (fake_bin / tool).write_text("#!/bin/sh\nexit 0\n")
            for executable in fake_bin.iterdir():
                executable.chmod(0o755)

            environment = os.environ.copy()
            environment["OSTYPE"] = "linux-gnu"
            environment["PATH"] = f"{fake_bin}:{environment['PATH']}"
            environment["FAKE_VENV_MARKER"] = str(marker)
            environment["FAKE_APT_LOG"] = str(apt_log)
            result = subprocess.run(
                ["bash", str(root / "setup.sh")],
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(result.returncode, 77, result.stderr)
            self.assertTrue(apt_log.exists(), "setup.sh did not invoke apt-get")
            self.assertIn("install -y python3.12-venv", apt_log.read_text())


if __name__ == "__main__":
    unittest.main()
