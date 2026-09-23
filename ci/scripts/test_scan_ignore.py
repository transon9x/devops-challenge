import datetime as dt
import pathlib
import tempfile
import unittest

import yaml

import scan_ignore

TODAY = dt.date(2026, 9, 22)


def entry(**overrides):
    base = {
        "id": "CVE-2026-0001",
        "type": "vulnerability",
        "until": "2026-12-31",
        "reason": "waiting for the upstream fix, tracked in TICKET-1",
    }
    base.update(overrides)
    return base


class ValidateTests(unittest.TestCase):
    def test_valid_entry_has_no_errors(self):
        self.assertEqual(scan_ignore.validate(entry(), 0), [])

    def test_every_required_field_is_enforced(self):
        for key in scan_ignore.REQUIRED:
            e = entry()
            del e[key]
            errors = scan_ignore.validate(e, 0)
            self.assertTrue(any(f"missing `{key}`" in x for x in errors), key)

    def test_unknown_type_and_key_are_rejected(self):
        self.assertTrue(scan_ignore.validate(entry(type="gitleaks"), 0))
        self.assertTrue(scan_ignore.validate(entry(owner="bob"), 0))

    def test_short_reason_is_rejected(self):
        self.assertTrue(scan_ignore.validate(entry(reason="fp"), 0))

    def test_bad_dates_are_rejected(self):
        self.assertTrue(scan_ignore.validate(entry(until="soon"), 0))
        self.assertTrue(scan_ignore.validate(entry(until="2026-02-30"), 0))

    def test_paths_only_for_trivy_types(self):
        self.assertTrue(scan_ignore.validate(entry(type="semgrep", paths=["a"]), 0))
        self.assertEqual(scan_ignore.validate(entry(paths=["vendor/**"]), 0), [])


class RenderTests(unittest.TestCase):
    def test_expired_entries_are_dropped_and_reported(self):
        trivy, semgrep, expired = scan_ignore.render(
            [entry(until="2026-09-22"), entry(id="CVE-2026-0002")], TODAY
        )
        self.assertEqual([e["id"] for e in expired], ["CVE-2026-0001"])
        self.assertEqual([v["id"] for v in trivy["vulnerabilities"]], ["CVE-2026-0002"])
        self.assertEqual(semgrep, [])

    def test_sections_and_semgrep_rules(self):
        trivy, semgrep, _ = scan_ignore.render(
            [
                entry(type="misconfiguration", id="AVD-DS-0002"),
                entry(type="license", id="GPL-3.0"),
                entry(
                    type="semgrep", id="javascript.lang.security.audit.path-traversal"
                ),
            ],
            TODAY,
        )
        self.assertEqual(set(trivy), {"misconfigurations", "licenses"})
        self.assertEqual(
            trivy["misconfigurations"][0]["expired_at"], dt.date(2026, 12, 31)
        )
        self.assertEqual(semgrep, ["javascript.lang.security.audit.path-traversal"])


class MainTests(unittest.TestCase):
    def run_main(self, content):
        with tempfile.TemporaryDirectory() as tmp:
            src = pathlib.Path(tmp, "scan-ignore.yml")
            if content is not None:
                src.write_text(content)
            out = pathlib.Path(tmp, "out")
            rc = scan_ignore.main(["scan_ignore.py", str(src), str(out)])
            files = (
                {p.name: p.read_text() for p in out.iterdir()} if out.exists() else {}
            )
            return rc, files

    def test_missing_file_yields_empty_suppressions(self):
        rc, files = self.run_main(None)
        self.assertEqual(rc, 0)
        self.assertEqual(yaml.safe_load(files["trivyignore.yaml"]), {})
        self.assertEqual(files["semgrep-exclude.args"], "")

    def test_valid_file_renders_both_outputs(self):
        rc, files = self.run_main(
            yaml.safe_dump(
                {
                    "ignores": [
                        entry(until="2999-01-01"),
                        entry(type="semgrep", id="rule.one", until="2999-01-01"),
                    ]
                }
            )
        )
        self.assertEqual(rc, 0)
        self.assertIn("CVE-2026-0001", files["trivyignore.yaml"])
        self.assertEqual(files["semgrep-exclude.args"], "--exclude-rule\nrule.one\n")

    def test_invalid_file_fails_the_gate(self):
        rc, _ = self.run_main(yaml.safe_dump({"ignores": [entry(reason="")]}))
        self.assertEqual(rc, 2)

    def test_non_list_document_fails(self):
        rc, _ = self.run_main("ignores: nope\n")
        self.assertEqual(rc, 2)


if __name__ == "__main__":
    unittest.main()
