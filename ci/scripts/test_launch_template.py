import copy
import pathlib
import unittest

import yaml

import launch_template as lt

DIGEST_A = "sha256:" + "a" * 64
DIGEST_B = "sha256:" + "b" * 64

STABLE = {
    "ImageId": "ami-0123456789abcdef0",
    "InstanceType": "m8i.large",
    "IamInstanceProfile": {"Arn": "arn:aws:iam::123456789012:instance-profile/backend"},
    "MetadataOptions": {
        "HttpTokens": "required",
        "HttpPutResponseHopLimit": 1,
        "InstanceMetadataTags": "enabled",
    },
    "SecurityGroupIds": ["sg-0123456789abcdef0"],
    "TagSpecifications": [
        {
            "ResourceType": "instance",
            "Tags": [
                {"Key": "Name", "Value": "backend"},
                {"Key": lt.DIGEST_TAG, "Value": DIGEST_A},
            ],
        },
        {"ResourceType": "volume", "Tags": [{"Key": "Name", "Value": "backend"}]},
    ],
}


class NextVersionTests(unittest.TestCase):
    def test_changes_only_the_digest_tag(self):
        new = lt.next_version_data(STABLE, DIGEST_B)
        self.assertEqual(new["TagSpecifications"][0]["Tags"][1]["Value"], DIGEST_B)
        self.assertEqual(lt.only_digest_changed(STABLE, new), [])
        self.assertEqual(STABLE["TagSpecifications"][0]["Tags"][1]["Value"], DIGEST_A)

    def test_rejects_tags_and_malformed_digests(self):
        for bad in ("latest", "sha256:abc", "sha512:" + "a" * 128, DIGEST_B.upper()):
            with self.assertRaises(ValueError):
                lt.next_version_data(STABLE, bad)

    def test_rejects_a_template_without_the_digest_tag(self):
        stripped = copy.deepcopy(STABLE)
        stripped["TagSpecifications"][0]["Tags"].pop(1)
        with self.assertRaises(ValueError):
            lt.next_version_data(stripped, DIGEST_B)


class OnlyDigestChangedTests(unittest.TestCase):
    def test_detects_any_other_change(self):
        new = lt.next_version_data(STABLE, DIGEST_B)
        new["ImageId"] = "ami-0fedcba9876543210"
        new["SecurityGroupIds"].append("sg-evil")
        new["IamInstanceProfile"]["Arn"] = (
            "arn:aws:iam::123456789012:instance-profile/admin"
        )
        diffs = lt.only_digest_changed(STABLE, new)
        self.assertEqual(len(diffs), 3, diffs)
        self.assertTrue(any(d.startswith("ImageId") for d in diffs))
        self.assertTrue(any(d.startswith("SecurityGroupIds") for d in diffs))
        self.assertTrue(any(d.startswith("IamInstanceProfile") for d in diffs))

    def test_detects_a_moved_tag(self):
        new = lt.next_version_data(STABLE, DIGEST_B)
        tags = new["TagSpecifications"][0]["Tags"]
        tags[0], tags[1] = tags[1], tags[0]
        self.assertEqual(
            lt.only_digest_changed(STABLE, new), ["digest tag missing or moved"]
        )


class HardeningTests(unittest.TestCase):
    def test_stable_template_is_accepted(self):
        self.assertEqual(lt.hardened_launch_template(STABLE), [])

    def test_each_weakening_is_named(self):
        weak = copy.deepcopy(STABLE)
        weak["KeyName"] = "ops-key"
        weak["MetadataOptions"]["HttpTokens"] = "optional"
        weak["MetadataOptions"]["HttpPutResponseHopLimit"] = 2
        weak["UserData"] = "IyEvYmluL2Jhc2g="
        problems = lt.hardened_launch_template(weak)
        self.assertEqual(len(problems), 4, problems)


class RunbookEmbedsTheSameCodeTests(unittest.TestCase):
    def test_runbook_script_contains_the_shared_functions(self):
        here = pathlib.Path(__file__).resolve().parent
        runbook = yaml.safe_load(
            (here / "../infra/ssm-automation-deploy-ec2.yaml").read_text()
        )
        scripts = [
            step["inputs"]["Script"]
            for step in runbook["mainSteps"]
            if step["action"] == "aws:executeScript"
        ]
        self.assertTrue(scripts, "the runbook has no aws:executeScript step")
        embedded = "\n".join(scripts)
        source = (here / "launch_template.py").read_text()
        for name in (
            "def find_digest_tag",
            "def next_version_data",
            "def only_digest_changed",
            "def hardened_launch_template",
        ):
            start = source.index(name)
            end = source.find("\n\n\n", start)
            body = source[start:end]
            self.assertIn(
                body,
                embedded,
                f"{name} in launch_template.py differs from the runbook copy",
            )


class DigestTagRenameTests(unittest.TestCase):
    """A fleet approved before the rename still carries the old tag key."""

    @staticmethod
    def template(key):
        return {
            "ImageId": "ami-0123456789abcdef0",
            "TagSpecifications": [
                {
                    "ResourceType": "instance",
                    "Tags": [{"Key": key, "Value": "sha256:" + "0" * 64}],
                }
            ],
        }

    def test_legacy_tag_is_still_updated(self):
        old = self.template("app:image-digest")
        new = lt.next_version_data(old, "sha256:" + "a" * 64)
        self.assertEqual(
            new["TagSpecifications"][0]["Tags"][0]["Value"], "sha256:" + "a" * 64
        )
        self.assertEqual(lt.only_digest_changed(old, new), [])

    def test_both_tags_present_is_refused(self):
        both = self.template("app:artifact-digest")
        both["TagSpecifications"][0]["Tags"].append(
            {"Key": "app:image-digest", "Value": "sha256:" + "1" * 64}
        )
        with self.assertRaises(ValueError):
            lt.next_version_data(both, "sha256:" + "a" * 64)


if __name__ == "__main__":
    unittest.main()
