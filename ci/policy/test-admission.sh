#!/usr/bin/env bash
# Prove the admission policy actually admits and rejects what the documents claim, using
# the Kyverno CLI against the sample pods in testdata/.
#
# The `verifyImages` rule needs registry access and a Sigstore lookup, so it is removed for
# this test and left to `verify-release.sh`, which checks the same identity in the pipeline.
# What is tested here is the part that is pure policy: digests, our registry, and the vendor
# allowlist for the platform namespaces.
#
# Requires Docker. Usage: ci/policy/test-admission.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KYVERNO_IMAGE="${KYVERNO_IMAGE:-ghcr.io/kyverno/kyverno-cli:v1.16.0}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

python3 - "$here" "$work" <<'PY'
import pathlib
import sys

import yaml

here, work = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
text = (here / "kyverno-verify-images.yaml").read_text()
for placeholder, value in {
    "<AWS_ACCOUNT_ID>": "111122223333",
    "<REGION>": "ap-southeast-1",
    "<ORG>": "example-org",
    "<APP_REPO>": "backend",
    "<TEMPLATE_SHA>": "0123456789abcdef0123456789abcdef01234567",
}.items():
    text = text.replace(placeholder, value)
doc = yaml.safe_load(text)
doc["spec"]["rules"] = [r for r in doc["spec"]["rules"] if "validate" in r]
(work / "policy.yaml").write_text(yaml.safe_dump(doc, sort_keys=False))
print("rules under test: " + ", ".join(r["name"] for r in doc["spec"]["rules"]))
PY

cp "${here}/testdata/pods.yaml" "${work}/pods.yaml"
# The Kyverno CLI image runs as a non-root user, and `mktemp -d` gives 0700, so without this
# the container cannot traverse the mount. It fails with a permission error rather than a
# policy verdict, which the summary check below turns into a failure instead of a silent pass.
chmod 0755 "$work"
chmod 0644 "$work"/*.yaml
out="${work}/out.txt"
docker run --rm -v "${work}":/w:ro "$KYVERNO_IMAGE" apply /w/policy.yaml --resource /w/pods.yaml \
  > "$out" 2>&1 || true
cat "$out"

# A test that reads "no rejection" as "admitted" passes when the CLI never ran. Require the
# CLI's own summary line, and require it to have applied the policy to all five pods.
if ! grep -qE '^pass: [0-9]+, fail: [0-9]+' "$out"; then
  printf 'FAIL the Kyverno CLI produced no summary, so nothing was actually evaluated\n'
  exit 1
fi
applied="$(sed -n 's/^pass: \([0-9]*\), fail: \([0-9]*\).*/\1 \2/p' "$out" | awk '{print $1 + $2}')"
if ((applied < 5)); then
  printf 'FAIL only %s policy result(s) reported; expected at least 5\n' "$applied"
  exit 1
fi

# The three pods that must be rejected, and the two that must be admitted.
expect_fail=(mutable-tag foreign-registry random-in-platform)
expect_pass=(good-app vendor-in-platform)
status=0
for pod in "${expect_fail[@]}"; do
  if grep -q "Pod/${pod} failed" "$out"; then
    printf 'OK   %s was rejected\n' "$pod"
  else
    printf 'FAIL %s should have been rejected\n' "$pod"
    status=1
  fi
done
for pod in "${expect_pass[@]}"; do
  if grep -q "Pod/${pod} failed" "$out"; then
    printf 'FAIL %s should have been admitted\n' "$pod"
    status=1
  else
    printf 'OK   %s was admitted\n' "$pod"
  fi
done
exit "$status"
