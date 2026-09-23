import io
import pathlib
import subprocess
import sys
import tarfile
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SCRIPT = HERE / "extract-bundle.py"


def bundle(path: pathlib.Path, members):
    with tarfile.open(path, "w:gz") as tar:
        for name, kind, payload in members:
            info = tarfile.TarInfo(name)
            if kind == "dir":
                info.type = tarfile.DIRTYPE
                tar.addfile(info)
            elif kind == "symlink":
                info.type = tarfile.SYMTYPE
                info.linkname = payload
                tar.addfile(info)
            else:
                data = payload.encode()
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))


def run(bundle_path: pathlib.Path, out: pathlib.Path, layout: str = "static"):
    return subprocess.run(
        [sys.executable, str(SCRIPT), str(bundle_path), str(out), "--layout", layout],
        capture_output=True,
        text=True,
    )


class ExtractBundleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_valid_bundle_with_root_entry_is_extracted_and_hashed(self):
        b = self.root / "ok.tgz"
        bundle(
            b,
            [
                ("./", "dir", None),
                ("./assets", "dir", None),
                ("./index.html", "file", "<html></html>"),
                ("./assets/app.abc123.js", "file", "1"),
            ],
        )
        r = run(b, self.root / "out")
        self.assertEqual(r.returncode, 0, r.stderr)
        lines = r.stdout.strip().splitlines()
        self.assertEqual(
            [line.split("  ")[1] for line in lines],
            ["assets/app.abc123.js", "index.html"],
        )
        self.assertTrue(all(len(line.split("  ")[0]) == 64 for line in lines))

    def test_path_traversal_is_refused(self):
        b = self.root / "evil.tgz"
        bundle(b, [("index.html", "file", "x"), ("../etc/passwd", "file", "x")])
        self.assertNotEqual(run(b, self.root / "out").returncode, 0)

    def test_symlink_is_refused(self):
        b = self.root / "link.tgz"
        bundle(
            b, [("index.html", "file", "x"), ("assets/a.js", "symlink", "/etc/passwd")]
        )
        self.assertNotEqual(run(b, self.root / "out").returncode, 0)

    def test_unexpected_top_level_file_is_refused(self):
        b = self.root / "extra.tgz"
        bundle(
            b,
            [
                ("index.html", "file", "x"),
                ("assets/a.js", "file", "x"),
                ("robots.txt", "file", "x"),
            ],
        )
        self.assertNotEqual(run(b, self.root / "out").returncode, 0)

    def test_missing_index_or_assets_is_refused(self):
        b = self.root / "noindex.tgz"
        bundle(b, [("assets/a.js", "file", "x")])
        self.assertNotEqual(run(b, self.root / "out").returncode, 0)
        b2 = self.root / "noassets.tgz"
        bundle(b2, [("index.html", "file", "x")])
        self.assertNotEqual(run(b2, self.root / "out2").returncode, 0)

    def test_non_empty_target_is_refused(self):
        b = self.root / "ok.tgz"
        bundle(b, [("index.html", "file", "x"), ("assets/a.js", "file", "x")])
        out = self.root / "busy"
        out.mkdir()
        (out / "stale").write_text("x")
        self.assertEqual(run(b, out).returncode, 2)


class AppLayoutTests(unittest.TestCase):
    """The `app` layout is what a bundle-mode EC2 instance executes."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_runnable_tree_is_extracted(self):
        b = self.root / "app.tgz"
        bundle(
            b,
            [
                ("./", "dir", None),
                ("./src", "dir", None),
                ("./node_modules", "dir", None),
                ("./node_modules/@scope", "dir", None),
                ("./node_modules/@scope/pkg", "dir", None),
                ("./package.json", "file", "{}"),
                ("./package-lock.json", "file", "{}"),
                ("./src/server.js", "file", "1"),
                ("./migrations/001_init.sql", "file", "-- x"),
                ("./node_modules/@scope/pkg/index.js", "file", "1"),
            ],
        )
        r = run(b, self.root / "out", "app")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("src/server.js", r.stdout)
        self.assertIn("node_modules/@scope/pkg/index.js", r.stdout)

    def test_static_layout_refuses_an_app_tree(self):
        b = self.root / "app.tgz"
        bundle(b, [("package.json", "file", "{}"), ("src/server.js", "file", "1")])
        self.assertNotEqual(run(b, self.root / "out").returncode, 0)

    def test_app_layout_refuses_an_unexpected_top_level_file(self):
        b = self.root / "app.tgz"
        bundle(
            b,
            [
                ("package.json", "file", "{}"),
                ("src/server.js", "file", "1"),
                (".npmrc", "file", "//registry:_authToken=x"),
            ],
        )
        self.assertNotEqual(run(b, self.root / "out", "app").returncode, 0)

    def test_app_layout_refuses_a_symlink_and_requires_a_manifest(self):
        b = self.root / "link.tgz"
        bundle(
            b,
            [
                ("package.json", "file", "{}"),
                ("node_modules/.bin/x", "symlink", "../pkg/cli.js"),
            ],
        )
        self.assertNotEqual(run(b, self.root / "out", "app").returncode, 0)
        b2 = self.root / "nomanifest.tgz"
        bundle(b2, [("src/server.js", "file", "1")])
        self.assertNotEqual(run(b2, self.root / "out2", "app").returncode, 0)


if __name__ == "__main__":
    unittest.main()
