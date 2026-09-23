"""Pure functions shared by the deploy runbook and its tests.

A new launch-template version may differ from the stable one in exactly one
place: the value of the instance tag that carries the image digest.
"""

from __future__ import annotations

import copy
import re

DIGEST_TAG = "app:artifact-digest"
# Fleets built before the tag was renamed still carry the old key. Both are accepted so a
# deploy keeps working during the rename, and exactly one must be present so a template
# cannot carry two digests that disagree.
LEGACY_DIGEST_TAG = "app:image-digest"
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")


def find_digest_tag(data: dict) -> tuple[int, int] | None:
    found: list[tuple[int, int]] = []
    for i, spec in enumerate(data.get("TagSpecifications", [])):
        if spec.get("ResourceType") != "instance":
            continue
        for j, tag in enumerate(spec.get("Tags", [])):
            if tag.get("Key") in (DIGEST_TAG, LEGACY_DIGEST_TAG):
                found.append((i, j))
    if len(found) > 1:
        raise ValueError(
            f"the launch template carries both {DIGEST_TAG!r} and {LEGACY_DIGEST_TAG!r}; "
            "leave exactly one"
        )
    return found[0] if found else None


def next_version_data(current: dict, digest: str) -> dict:
    if not DIGEST.match(digest):
        raise ValueError(f"not an image digest: {digest!r}")
    where = find_digest_tag(current)
    if where is None:
        raise ValueError(
            f"the stable launch template has no instance tag {DIGEST_TAG!r} "
            f"(or the legacy {LEGACY_DIGEST_TAG!r})"
        )
    new = copy.deepcopy(current)
    i, j = where
    new["TagSpecifications"][i]["Tags"][j]["Value"] = digest
    return new


def only_digest_changed(old: dict, new: dict) -> list[str]:
    """Return the list of differences other than the digest tag value (empty means OK)."""
    a, b = copy.deepcopy(old), copy.deepcopy(new)
    wa, wb = find_digest_tag(a), find_digest_tag(b)
    if wa is None or wb is None or wa != wb:
        return ["digest tag missing or moved"]
    a["TagSpecifications"][wa[0]]["Tags"][wa[1]]["Value"] = "<digest>"
    b["TagSpecifications"][wb[0]]["Tags"][wb[1]]["Value"] = "<digest>"
    return _diff(a, b, "")


def _diff(a, b, path: str) -> list[str]:
    if isinstance(a, dict) and isinstance(b, dict):
        out = []
        for key in sorted(set(a) | set(b)):
            out += _diff(a.get(key), b.get(key), f"{path}.{key}" if path else key)
        return out
    if isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            return [f"{path}: list length {len(a)} -> {len(b)}"]
        out = []
        for i, (x, y) in enumerate(zip(a, b)):
            out += _diff(x, y, f"{path}[{i}]")
        return out
    if a != b:
        return [f"{path}: {a!r} -> {b!r}"]
    return []


def hardened_launch_template(data: dict) -> list[str]:
    """Return the launch-template properties this deploy refuses to run without."""
    problems = []
    if data.get("KeyName"):
        problems.append("KeyName is set: no SSH key pair may exist")
    meta = data.get("MetadataOptions", {})
    if meta.get("HttpTokens") != "required":
        problems.append("MetadataOptions.HttpTokens must be 'required' (IMDSv2)")
    if meta.get("InstanceMetadataTags") != "enabled":
        problems.append(
            "MetadataOptions.InstanceMetadataTags must be 'enabled' (the digest is read from the tag)"
        )
    if meta.get("HttpPutResponseHopLimit", 1) != 1:
        problems.append("MetadataOptions.HttpPutResponseHopLimit must be 1")
    if not data.get("IamInstanceProfile"):
        problems.append("IamInstanceProfile is missing")
    if data.get("UserData"):
        problems.append(
            "UserData is set: the bootstrap is baked into the AMI, not passed at launch"
        )
    if find_digest_tag(data) is None:
        problems.append(f"instance tag {DIGEST_TAG!r} is missing")
    return problems
