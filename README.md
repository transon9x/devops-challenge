# DevOps Challenge — solutions

[![ci](https://github.com/transon9x/devops-challenge/actions/workflows/ci.yml/badge.svg)](https://github.com/transon9x/devops-challenge/actions/workflows/ci.yml)

All five problems, in the layout of the challenge skeleton. Each problem's answer is in its
own `SOLUTION.md`.

| # | Problem | Solution | Runs for real? |
|---|---|---|---|
| 1 | Building Castle In The Cloud | [`src/problem1/SOLUTION.md`](src/problem1/SOLUTION.md) | Design + diagram |
| 2 | Diagnose Me Doctor | [`src/problem2/SOLUTION.md`](src/problem2/SOLUTION.md) | Runbook, a read-only triage script, and an asserting log-rotation test |
| 3 | Debugging issues within system | [`src/problem3/SOLUTION.md`](src/problem3/SOLUTION.md) | **Yes** — `./verify.sh` runs 22 checks against a live stack |
| 4 | Ship It Twice | [`src/problem4/SOLUTION.md`](src/problem4/SOLUTION.md) | **Mostly** — the shared pipeline runs here on every pull request and push to `main`: quality gate, hardened build, scans, and on `main` the signed, attested publish to a private registry. Only the AWS deploy stages need an account |
| 5 | Fortify The Castle | [`src/problem5/SOLUTION.md`](src/problem5/SOLUTION.md) | Design + marked diagram |

## Suggested reading order

**Problem 3** first (executable evidence), then **Problem 1** and **Problem 5** (one design
read twice: architecture, then the same architecture with security built in), then
**Problem 4**, and **Problem 2** last.

## This repository plays two roles for Problem 4

GitHub only executes reusable workflows from a repository's own `.github/workflows/`, so the
**shared CI/CD templates** live at the root here (`.github/workflows/pipeline.yml` and its
leaves, plus `ci/`), and the two **application repositories** are `src/problem4/backend` and
`src/problem4/frontend` with their thin caller workflows under
`src/problem4/.github/workflows/`. [`ci/README.md`](ci/README.md) is the template contract.

## What you can run

Needs Docker, Node 24, and Python 3.12 or newer — the bundle extractor relies on tarfile's
`data` filter, and fails on an older interpreter rather than extracting unfiltered.

```bash
# Problem 3 — brings the stack up, injects faults, prints a pass/fail table
cd src/problem3 && ./verify.sh            # 22 checks; --keep leaves the stack running

# Problem 4 — the applications and the template repository's own checks
(cd src/problem4/backend && npm ci && npm run lint && npm test && docker build -t backend .)
(cd src/problem4/frontend && npm ci && npm run lint && npm test && npm run build)
(cd ci/scripts && python3 -m unittest test_scan_ignore test_launch_template test_extract_bundle test_sql_guard test_runbooks)
ci/scripts/test-migration-sql.sh          # the migration contract against a real PostgreSQL
ci/policy/test-admission.sh               # the admission policy, with the Kyverno CLI
ci/scripts/lint-workflows.sh   # actionlint, including the "$/" self-repository calls
GH_TOKEN="$(gh auth token)" uvx --from zizmor==1.30.1 zizmor --persona=pedantic .github/workflows/
uvx --from zizmor==1.30.1 zizmor --persona=pedantic --no-online-audits src/problem4/.github/workflows/
shellcheck -x ci/scripts/*.sh ci/instance/*.sh src/problem2/*.sh src/problem3/verify.sh

# Problem 2 — read-only disk triage (safe to run on a live box; it changes nothing)
sudo src/problem2/diagnose.sh /

# Problem 2 — proves log rotation makes NGINX reopen; it rotates for real, so use a
# disposable host or an image build, never a box that is mid-incident
sudo src/problem2/rotate-check.sh
```

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs all of the above and, through
the shared pipeline, the Problem 4 quality gate, build, image scan and (on `main`) the
publish, keyless signature and attestations for both applications. It does **not** execute a
deploy to AWS, validate IAM behaviour or exercise an instance refresh or rollback.

## Notes on the challenge text

- Problem 3's page says "Reference README in Problem 4 repo", and `src/problem3/README.md`
  is titled "# Problem 4". I treated `src/problem3/` as the subject of Problem 3.
- Problem 2 says "two production issues" but describes one scenario. I answered the scenario
  given.
- This repository is a fresh repository, not a fork, as the upstream README asks.

Assumptions that affect a design are stated at the top of the relevant `SOLUTION.md`.
