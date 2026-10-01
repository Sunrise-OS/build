#!/usr/bin/env python3
"""Host-only tests for corecrypto target-manifest selection."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("builder", Path(__file__).with_name("build-corecrypto.py"))
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        project = self.root / "corecrypto.xcodeproj"
        project.mkdir()
        (project / "project.pbxproj").write_text('''
        000000000000000000000001 /* corecrypto_kext */ = {
            isa = PBXNativeTarget;
            buildPhases = (
                000000000000000000000002 /* Sources */,
            );
\t\t};
\t\t000000000000000000000002 /* Sources */ = {
            isa = PBXSourcesBuildPhase;
            files = (
                000000000000000000000003 /* selected.c in Sources */,
                000000000000000000000004 /* fast.s in Sources */,
            );
\t\t};
''')
        (self.root / "selected.c").touch()
        (self.root / "unrelated-test.c").touch()

    def test_only_target_c_sources(self):
        self.assertEqual(builder.kext_sources(self.root), [self.root / "selected.c"])

    def test_ambiguous_basename_fails(self):
        (self.root / "other").mkdir()
        (self.root / "other/selected.c").touch()
        with self.assertRaisesRegex(ValueError, "ambiguous"):
            builder.kext_sources(self.root)

    def test_missing_source_fails(self):
        (self.root / "selected.c").unlink()
        with self.assertRaisesRegex(ValueError, "missing"):
            builder.kext_sources(self.root)


class SourceTests(unittest.TestCase):
    def test_fixed_fetcher_needs_no_git(self):
        with patch.object(builder, "run") as run:
            self.assertEqual(builder.verify_source(Path("/nix/source"), builder.REVISION,
                                                   builder.REVISION), builder.REVISION)
            run.assert_not_called()

    def test_wrong_fetcher_revision_fails(self):
        with self.assertRaisesRegex(ValueError, "does not match"):
            builder.verify_source(Path("/nix/source"), builder.REVISION, "wrong")

    def test_dirty_git_checkout_fails(self):
        with patch.object(builder, "run", side_effect=[builder.REVISION, " M source.c"]):
            with self.assertRaisesRegex(ValueError, "must be clean"):
                builder.verify_source(Path("/source"), builder.REVISION)

    def test_clean_git_checkout(self):
        with patch.object(builder, "run", side_effect=[builder.REVISION, ""]):
            self.assertEqual(builder.verify_source(Path("/source"), builder.REVISION),
                             builder.REVISION)


if __name__ == "__main__":
    unittest.main()
