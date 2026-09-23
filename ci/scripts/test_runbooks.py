"""The Automation runbooks carry Python inline, so it is compiled and exercised here.

A syntax error or a wrong comparison in an embedded handler would only surface during a
real deploy or migration, which is the worst place to find it.
"""

import json
import pathlib
import sys
import types
import unittest

import yaml

INFRA = pathlib.Path(__file__).resolve().parents[1] / "infra"
RUNBOOKS = sorted(INFRA.glob("ssm-automation-*.yaml"))


def scripts(path: pathlib.Path):
    doc = yaml.safe_load(path.read_text())
    for step in doc["mainSteps"]:
        source = step.get("inputs", {}).get("Script")
        if source:
            yield step["name"], source


class EmbeddedScriptsCompile(unittest.TestCase):
    def test_every_runbook_has_scripts_that_compile(self):
        self.assertTrue(RUNBOOKS, "no runbooks found")
        for path in RUNBOOKS:
            found = list(scripts(path))
            self.assertTrue(found, f"{path.name} has no inline script")
            for name, source in found:
                with self.subTest(runbook=path.name, step=name):
                    compile(source, f"{path.name}:{name}", "exec")


class MigrationOutcomeHandler(unittest.TestCase):
    """The ReadOutcome step decides whether a published result belongs to this execution."""

    @staticmethod
    def load_handler(status_value, detail_value):
        source = dict(scripts(INFRA / "ssm-automation-migrate-db.yaml"))["ReadOutcome"]
        parameters = {
            "/p/sha/exec/status": status_value,
            "/p/sha/exec/detail": json.dumps(detail_value),
        }

        class Ssm:
            def get_parameter(self, Name):  # noqa: N803 - boto3's own signature
                return {"Parameter": {"Value": parameters[Name]}}

        stub = types.ModuleType("boto3")
        stub.client = lambda service: Ssm()
        saved = sys.modules.get("boto3")
        sys.modules["boto3"] = stub
        try:
            namespace: dict = {}
            exec(compile(source, "ReadOutcome", "exec"), namespace)  # noqa: S102
            return namespace["handler"]
        finally:
            if saved is None:
                del sys.modules["boto3"]
            else:
                sys.modules["boto3"] = saved

    @staticmethod
    def events():
        return {
            "StatusName": "/p/sha/exec/status",
            "DetailName": "/p/sha/exec/detail",
            "ExpectedDigest": "sha256:" + "a" * 64,
            "ExpectedReleaseSha": "b" * 40,
            "InstanceId": "i-0123456789abcdef0",
        }

    def detail(self, **overrides):
        base = {
            "detail": "applied 1 file",
            "digest": "sha256:" + "a" * 64,
            "release_sha": "b" * 40,
            "instance": "i-0123456789abcdef0",
        }
        base.update(overrides)
        return base

    def test_a_matching_ok_result_is_accepted(self):
        handler = self.load_handler("ok", self.detail())
        self.assertEqual(handler(self.events(), None)["Status"], "ok")

    def test_a_failed_status_raises(self):
        handler = self.load_handler("failed", self.detail(detail="lock timeout"))
        with self.assertRaises(Exception) as caught:
            handler(self.events(), None)
        self.assertIn("lock timeout", str(caught.exception))

    def test_another_release_is_refused(self):
        handler = self.load_handler("ok", self.detail(release_sha="c" * 40))
        with self.assertRaises(Exception) as caught:
            handler(self.events(), None)
        self.assertIn("does not belong to this execution", str(caught.exception))

    def test_another_instance_is_refused(self):
        handler = self.load_handler("ok", self.detail(instance="i-999"))
        with self.assertRaises(Exception):
            handler(self.events(), None)

    def test_another_digest_is_refused(self):
        handler = self.load_handler("ok", self.detail(digest="sha256:" + "f" * 64))
        with self.assertRaises(Exception):
            handler(self.events(), None)


if __name__ == "__main__":
    unittest.main()
