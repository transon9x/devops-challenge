# Problem 4: Ship It Twice

CI/CD for two applications: an HTTP API on EC2 and a static SPA on S3 behind CloudFront,
built with **shared GitHub reusable workflows** so neither application repository defines a
stage.

## Layout: this repository plays two roles

GitHub only executes reusable workflows from a repository's own `.github/workflows/`, so the
shared templates live at the **root** of this repository and the two application repositories
are directories under `src/problem4/`:

```
.github/workflows/pipeline.yml   # the ONE workflow an app repo calls: quality → build once → dev → prod
.github/workflows/{quality-gate,build-publish,migrate-db,deploy-ec2,deploy-s3}.yml   # its stages
ci/                              # scripts, runbook, IAM policies, instance units, Kyverno policy — see ci/README.md
src/problem4/.github/workflows/  # backend.yml, frontend.yml: the caller workflows an app repo contains
src/problem4/{backend,frontend}  # the two applications
```

`pipeline.yml` reaches its stages with GitHub's `$/` self-repository syntax: the stages are pinned to the commit already running and cannot be swapped by files a previous step wrote into the workspace. It needs runner 2.336.0 or newer and github.com (not GitHub Enterprise Server).

**What runs for real here.** [`ci.yml`](../../.github/workflows/ci.yml) calls the shared
pipeline three times on every pull request and push to `main` — the backend as a container,
the backend as a host bundle, the frontend as a static bundle: lint, unit tests
with the coverage floor, `npm audit signatures`, gitleaks, Semgrep, Trivy, hadolint,
container build and health check, and on `main` the publish to GitHub Container Registry
with the image scan, cosign signature, SBOM attestation and SLSA provenance, verified back
exactly as a deploy would. The deploy stages are disabled here (no AWS account), so
OIDC assumption, the IAM conditions, the instance refresh, the alarm rollback and the
promotion marker are implemented and unit-tested but not executed against AWS.

## Assumptions

| Assumption | Detail |
|---|---|
| Registry | ECR private for the platform; GHCR private for this repository's live evidence. The templates take `registry: ecr | ghcr` and use the same digest interface |
| Environments | `dev` then `prod`, both GitHub Environments with a deployment-branch rule limited to `main`; `prod` has required reviewers |
| Backend runtime | EC2 in an Auto Scaling group behind an ALB, AMI built by EC2 Image Builder, pinned cosign and oras, the systemd units from `ci/instance/`, and **no `sshd`**. Two modes: a container, or the application running directly on the host |
| Runtime configuration | Backend: Parameter Store path `/app/backend/<env>/config/*` read at boot. Frontend: `config.json` written by the deploy from `vars.FRONTEND_RUNTIME_CONFIG_JSON`. Nothing environment-specific is baked into an artifact |
| Database | Aurora PostgreSQL with IAM database authentication. Migrations are expand-only and ship inside the release, applied by a job, never by the pipeline |
| Region | `ap-southeast-1` |

## How the pipeline works

### Build once, deploy the same digest everywhere

`build-publish.yml` produces **one OCI digest per commit**: the backend as a container image,
the frontend as a deterministic `tar.gz` pushed with ORAS as an OCI artifact. Deploys accept
a digest or resolve one from the `sha-<commit>` tag and then **verify the signature binds
that digest to that commit**, so a moved tag fails. A re-run of an already published commit
verifies and reuses the existing digest instead of building again. Nothing is rebuilt for an
environment: dev and prod pull the same bytes.

### Quality gate (every pull request and push to `main`)

| Check | Tool | Gate |
|---|---|---|
| Lint, unit tests | ESLint, `node --test` | coverage floor per app (default 80 %, organisation floor 70 %, callers may only raise it) |
| Dependency provenance | `npm audit signatures` | registry signatures and provenance of every installed package |
| Secrets | gitleaks (full history on push, PR range on PRs) | any finding blocks; false positives only through `.gitleaksignore` |
| SAST | Semgrep CE (`p/default` + stack packs) | `fail_on` severity, floor `high` |
| SCA, misconfiguration, licences, SBOM | Trivy `fs` (CycloneDX SBOM artifact) | same severity floor |
| Dependency changes | GitHub dependency review | on pull requests |
| Dockerfile | hadolint | warnings block |
| Image | Trivy `image` on the pushed digest | vulnerabilities at the floor with the same expiring ignore file; **any** baked secret, never suppressible |
| Quality | SonarQube scan + quality gate wait | runs when `vars.SONAR_HOST_URL` is set, otherwise reports "not configured" |

Suppressions live in `<app>/.ci/scan-ignore.yml`; every entry needs `id`, `type`, `until`
and `reason`, expired entries re-fail, and the translator is unit-tested
(`ci/scripts/test_scan_ignore.py`). The floors are enforced in the template, so an
application repository cannot weaken them.

### Signing and identity

`build-publish.yml` is two jobs: `build` runs the application's `npm ci`, tests, container
and bundle with **no credentials**, and hands an OCI image layout (or the bundle) to
`publish`, which holds the OIDC, registry and attestation permissions and executes nothing
from the application repository. `publish` copies the layout to the registry digest-for-
digest, scans the pushed image, signs the digest **keyless** with cosign (Sigstore
Fulcio/Rekor, the job's OIDC token), attaches a CycloneDX SBOM attestation (for the frontend
bundle: the production-dependency BOM of its build), and GitHub records SLSA v1 provenance
and the SBOM as artifact attestations. Because signing happens in the shared workflow, the
certificate identity is the **template's** workflow: an ad-hoc step in an application
repository cannot produce a valid signature.

Every deploy runs [`verify-release.sh`](../../ci/scripts/verify-release.sh) before touching
anything: `cosign verify` with the issuer, the identity regexp of `build-publish.yml`, and
the source repository, commit and ref; `cosign verify-attestation` for the SBOM; and
`gh attestation verify` with `--signer-digest` pinned to the exact template commit,
`--source-digest` and `--source-ref`. The EC2 instance repeats the cosign checks at boot.

### Publish to a private registry

Images and bundles go to ECR (design) or GHCR (evidence), tagged `sha-<commit>` for lookup
only. ECR repositories have tag immutability and scan-on-push; deploys never use a tag.

### Deploy: keyless, and no SSH anywhere

**AWS authentication.** OIDC federation only, one role per (application, environment).
Trust policies use `StringEquals` on `aud`, the immutable `sub`, `repository_id`,
`repository_owner_id`, `environment`, `ref` and `job_workflow_ref` pinned to the template
commit, so AWS trusts only deploys that ran through the shared template. Self-hosted
runners use the same OIDC token; their instance role carries no deploy rights, and if an
organisation insists on an instance role instead, the runner group must be dedicated to
the CD repository with the same scoped policy (any workflow on that runner inherits it).
Policies: [`ci/infra/`](../../ci/infra/README.md).

**Frontend (`deploy-s3.yml`).** Verify → (prod) require the dev promotion → `oras pull` by
digest → extract into an empty directory with an allowlist (`index.html`, `assets/*`; no
links, devices or `..`) → record the live `index.html` version → upload assets with an
immutable cache → `config.json` → `index.html` last → invalidate → smoke test for the new
version. Any failure after arming restores the previous `index.html` version and
smoke-tests **for the old version string**, so a failed restore is not reported healthy.

**Backend (`deploy-ec2.yml`), immutable rollout.** Instead of an agent that mutates live
hosts, the release is a new **launch-template version** and an **EC2 Auto Scaling instance
refresh**:

1. The runner verifies the release and, for prod, the dev promotion, then starts **one
   numbered version of one SSM Automation runbook**
   ([`ci/infra/ssm-automation-deploy-ec2.yaml`](../../ci/infra/ssm-automation-deploy-ec2.yaml)).
   That is the runner's only fleet-related permission; it holds no EC2, Auto Scaling, Run
   Command or Session Manager rights.
2. The runbook, under its own role, resolves the group's stable **numbered** launch-template
   version, refuses a template that is not hardened (IMDSv2, no key pair, no user data,
   instance profile, digest tag), creates a new version that differs **only** in the
   `app:artifact-digest` tag (checked before and after, unit-tested in
   `ci/scripts/test_launch_template.py`), and starts an instance refresh with
   `MinHealthyPercentage 100`, `AutoRollback`, the ALB 5xx alarm, warm-up, bake time,
   checkpoints for prod, protected instances refreshed and standby instances terminated, so
   no old-digest instance can survive; after the refresh it verifies every `InService`
   instance runs the new version.
3. Each new instance boots the AMI-baked
   [`backend-bootstrap.sh`](../../ci/instance/backend-bootstrap.sh): reads the digest from
   its instance tag, verifies the cosign signature and provenance, pulls by digest, checks
   the pulled `RepoDigests`, reads its configuration from Parameter Store, and starts the
   container non-root, read-only, all capabilities dropped, `no-new-privileges`, with
   resource limits. It reports healthy only after `/health` answers; otherwise the refresh
   fails and **Auto Scaling rolls back** to the previous numbered version.
4. The runner polls the automation to a terminal state, smoke-tests `/health` for the
   release version, and on dev records the promotion.

Rollback is a new refresh to the previous numbered version, automatic on failure or on the
alarm, manual with `rollback-instance-refresh` while in progress. Nothing SSHes anywhere:
the instance pulls, the runner talks to the AWS control plane. Session Manager exists for
audited break-glass only.

### Two EC2 runtime modes, one release contract

A backend release is either a container image or a **bundle**: the runnable tree
(`package.json`, `src/`, production `node_modules`, `migrations/`) as a deterministic
`tar.gz` pushed as an OCI artifact. Both are one digest per commit, signed and attested the
same way, and both deploy through the same launch-template version and instance refresh.
The mode belongs to the fleet, not to the release: the AMI and the launch template carry
`app:artifact-kind`, and a deploy only ever changes `app:artifact-digest`. Fleets built
before that tag was renamed still carry `app:image-digest`; the runbook accepts either key
and refuses a template carrying both, so the rename is a one-time launch-template edit
rather than a flag day.

Running without a container removes two controls, so the pipeline replaces them:

| Control lost | Replacement |
|---|---|
| Image scan of the pushed layers, and hadolint | [`gate-bundle.sh`](../../ci/scripts/gate-bundle.sh) scans the **extracted** tree at the same severity floor with the same expiring ignore file, plus a never-suppressible secret scan and its CycloneDX SBOM. The bundle's sha256 is recorded before the scan and checked again before the push, so the scanned bytes are the pushed bytes |
| Base-image CVEs caught on every release, because a rebuild pulls a new base | The OS is the AMI, so it is only refreshed when the AMI is: the Image Builder pipeline scans each build and fails on the same severity floor, Inspector scans the running fleet continuously, and AMI currency is a scheduled rebuild plus an Inspector alert — the deploy runbook does not check AMI age, and does not claim to |
| The container sandbox (read-only root, dropped capabilities, non-root user, CPU and memory limits, a private `noexec` `/tmp`) | Systemd covers most of it in [`backend-bundle.service`](../../ci/instance/backend-bundle.service): `User=backend`, `ProtectSystem=strict`, `NoNewPrivileges`, empty `CapabilityBoundingSet`, `SystemCallFilter=@system-service`, `RestrictAddressFamilies`, `MemoryMax`, `CPUQuota`, `TasksMax`, `PrivateTmp`. Two gaps stay, and are accepted rather than papered over: `PrivateTmp` is not mounted `noexec,nosuid`, and the process shares the host's filesystem namespace instead of an image of its own, so a bundle fleet is a weaker boundary than a container fleet on the same host |

The build job also runs the extracted bundle and checks its `/health` response, the same way
it runs the container, so a bundle that cannot start fails before it is published. The
instance bootstrap verifies the signature and provenance before it unpacks anything,
and [`extract-bundle.py`](../../ci/scripts/extract-bundle.py) admits only plain files at
allowed paths, so a tampered bundle cannot write outside the release directory.

### Database migrations: a job on a host, never a pipeline step

The pipeline holds no database credentials and has no network path to the database. It
starts one numbered version of one runbook
([`ssm-automation-migrate-db.yaml`](../../ci/infra/ssm-automation-migrate-db.yaml)), which:

1. takes a **pre-migration cluster snapshot** — the one deploy step that redeploying the
   previous release cannot undo;
2. launches a single ephemeral host from the pinned migration launch template, tagged with
   the release digest and the Parameter Store path for its result;
3. waits on a status parameter it seeded before the host existed — `aws:executeScript` is
   capped at ten minutes, so the wait is a `waitForAwsResourceProperty` step that admits only
   `ok` or `failed` — reads the detail and checks the digest, release and instance are this
   execution's, then terminates every host tagged with that execution. Nothing sends a command to
   the host, so no remote-execution path into the data subnet exists, and a dead-man timer
   in the AMI powers the host off after 45 minutes if the runbook itself fails.

On the host, [`backend-migrate.sh`](../../ci/instance/backend-migrate.sh) runs as a
`Type=oneshot` unit: it verifies the release, extracts it, connects as `app_migrator` with
an **IAM authentication token** over TLS, and applies each `migrations/*.sql` in its own
transaction behind an advisory lock, recording it in a ledger table so a re-run is a no-op.
The job takes the advisory lock and then **inserts the ledger row before the file runs**, so
an already-applied file is rejected by the primary key and its statements never execute; a
file whose content changed since it was applied is an error, not a silent skip. Migration files are submitted
as one SQL string, never with `psql --file`, and a file containing a psql meta-command
(`\!` runs a shell command) or its own `BEGIN`/`COMMIT` is rejected — on the host and again
in the pipeline by [`check-migrations.sh`](../../ci/scripts/check-migrations.sh), which also
requires a zero-padded `NNNN_` prefix so file order is unambiguous and strips comments before
scanning. It is a guardrail in front of review, not a proof: `migrations/` is
CODEOWNERS-gated ([`.github/CODEOWNERS`](../../.github/CODEOWNERS)) because a regex cannot
recognise every destructive statement. The SQL rules themselves live in
[`sql_guard.py`](../../ci/scripts/sql_guard.py), which both the pipeline and the migration
host run, so they cannot drift apart. `normalise()` is a single left-to-right scan rather
than a pass per construct, because a pass per construct lets a dollar tag inside two ordinary
strings swallow the statement between them; its twenty unit tests cover that case and the
other evasions worth naming — a transaction statement hidden in a block comment, behind a
`--` inside a string literal, after identifier characters as in `foo$x$`, in
`COMMIT AND CHAIN`, as the `ABORT` alias, or after another statement on the same line.
`lock_timeout` and `statement_timeout` mean a migration that cannot take its locks is
abandoned instead of blocking the fleet. The migrator may change the schema; the runtime
user may not. Migrations are **expand-only**: an authoring contract, not something the pipeline can prove.
What it does enforce is that a contracting statement (a drop, a rename, a new `NOT NULL`)
declares itself with a `-- phase: contract` line and is reviewed, so the running release
still tolerates the schema and the deploy that follows is a plain instance refresh.
[`src/problem4/backend/migrations/`](backend/migrations/) ships three files that exercise both
halves of that rule rather than describing it: two expanding ones, and a third whose `DROP
INDEX` is refused by the check until the declaration is present. Deleting the declaration and
re-running the check is the shortest way to see it work.
Migrations require `artifact_kind: bundle`, because they travel inside the bundle. An image
fleet therefore publishes a **companion migration bundle** from the same commit and calls
this pipeline for it with `migrate: true, deploy: false` — migrating and deploying are gated
separately, so that is a migration-only run — then calls it again for the image with
`migrate: false`. Production migrates only a digest that dev migrated, proved
by the same marker-and-attestation pair the deploys use, and its own environment approval.

### Promotion evidence: prod deploys what dev accepted

After a successful dev deploy and smoke test, the dev role writes
`promotions/<kind>/<digest>.dev-ok` to a versioned bucket whose policy lets only the dev
roles write and nobody delete, and signs a promotion attestation on the artifact with the
deploy template's identity. Production requires **both** for the exact digest: the marker,
and `cosign verify-attestation` pinned to the deploy workflow at the exact template commit
with a CUE policy that checks `environment`, `digest` and the smoke-test result inside the
signed predicate. The prod role is denied `s3:PutObject` there. An `AccessDenied` or
throttle while reading the marker is an error, never permission to proceed. Redeploying a
digest that is already current is a no-op refresh followed by the smoke test and an
idempotent re-record of both proofs.

### After the deploy: the runtime verifies too

Signing is only useful if the deploy target refuses anything unsigned. For EC2 that is the
bootstrap's cosign check above. For the container platform of Problems 1 and 5, the same
identity pin is an admission policy: [`ci/policy/kyverno-verify-images.yaml`](../../ci/policy/kyverno-verify-images.yaml)
rejects images without a digest, without a keyless signature from `build-publish.yml`
built from the expected repository and branch, or without the SLSA provenance and SBOM
attestations.

### Dispatch and dry run

`workflow_dispatch` redeploys a published `release_sha` to one environment, or builds
`HEAD` from `main` for dev. Prod never builds: it only promotes a release that dev has
accepted. `dry_run: true` is allowed only with an existing `release_sha`; the deploy jobs
then print every operation under `### DRY RUN — nothing was deployed` and request no OIDC
token. Nothing is built or published in a dry run.

The local check commands are in the root [README](../../README.md).
