# Shared CI/CD templates

This directory plus `.github/workflows/{pipeline,quality-gate,build-publish,deploy-ec2,deploy-s3}.yml`
is the content of the shared **`ci-templates`** repository. In this submission it lives at the
repository root because GitHub only executes reusable workflows from a repository's own
`.github/workflows/`; the two application repositories are the directories
`src/problem4/backend` and `src/problem4/frontend`, whose caller workflows are under
`src/problem4/.github/workflows/`.

## Contract

An application repository has one workflow: triggers plus a single job that calls
`pipeline.yml` at a **commit SHA**:

```yaml
jobs:
  pipeline:
    permissions: {contents: read, packages: write, id-token: write, attestations: write}
    uses: <ORG>/ci-templates/.github/workflows/pipeline.yml@<40-char SHA>  # v1.4.0
    with:
      artifact_kind: image        # or static
      registry: ecr               # or ghcr
      image_name: <account>.dkr.ecr.<region>.amazonaws.com/<app>
      aws_region: <region>
      ecr_publish_role_arn: arn:aws:iam::<account>:role/gha-<app>-publish
      coverage_min: '85'          # may only raise the floor (70)
      sonar_project_key: <key>    # Sonar runs only when vars.SONAR_HOST_URL is set
```

`pipeline.yml` owns the stage graph and calls the leaf workflows with local paths, so one
pin fixes the revision of every stage:

| Stage | Workflow | Runs on | Produces |
|---|---|---|---|
| Quality gate | `quality-gate.yml` | PR, push to main, dispatch | lint, unit tests with a coverage floor, `npm audit signatures`, gitleaks, Semgrep, Trivy (SCA + misconfig + licence + CycloneDX SBOM), dependency review (PRs), hadolint, SonarQube when configured |
| Build once | `build-publish.yml` | PR (build + scan only), main (publish) | one OCI digest per commit — container image, host bundle or static bundle; scan of the pushed image or of the extracted bundle (vulnerabilities, baked secrets); cosign keyless signature; SBOM and SLSA provenance attestations |
| Migrate | `migrate-db.yml` | before each environment's deploy, when `migrate: true` (needs `artifact_kind: bundle`) | expand-only migrations applied by a one-shot job on an ephemeral host, behind a pre-migration snapshot; authoring rules checked by `check-migrations.sh` at build time; migration marker + attestation |
| Deploy dev | `deploy-ec2.yml` / `deploy-s3.yml` | main, dispatch | verified deploy; promotion marker + attestation |
| Deploy prod | same | after dev, behind the `prod` environment approval | verified deploy of the same digest; requires the dev promotion |

Every stage checks out **its own revision** of this repository
(`job.workflow_repository` at `job.workflow_sha`) for scripts and hooks. Application code
runs only in jobs that hold no credentials; the publish and deploy jobs never check it out.

## What the caller can and cannot change

- Can: raise `coverage_min`, tighten `fail_on` (high → medium → low), choose registry,
  image name, Sonar project key, redeploy targets.
- Cannot: lower the severity floor below `high`, lower coverage below 70 %, disable the
  secret scan, migrate outside the job (no stage of this pipeline holds database credentials), run stages in a different order, deploy to prod without dev, deploy a digest
  that was not signed by `build-publish.yml`, point a deploy at another environment's
  resources (those come from the GitHub Environment's variables, never from inputs).

## Environment variables the deploy stages read

Set per GitHub Environment (`dev`, `prod`) in the application repository:

| Variable | Used by |
|---|---|
| `AWS_REGION`, `AWS_DEPLOY_ROLE_ARN`, `PROMOTION_BUCKET` | both |
| `AWS_MIGRATE_ROLE_ARN`, `SSM_MIGRATE_DOCUMENT_ARN`, `SSM_MIGRATE_DOCUMENT_VERSION`, `SSM_MIGRATE_AUTOMATION_ROLE_ARN`, `MIGRATION_LAUNCH_TEMPLATE_ID`, `MIGRATION_LAUNCH_TEMPLATE_VERSION`, `DB_CLUSTER_IDENTIFIER`, `MIGRATION_RESULT_PARAMETER_PREFIX` | `migrate-db.yml` |
| `SITE_BUCKET`, `CLOUDFRONT_DISTRIBUTION_ID`, `SITE_URL`, `FRONTEND_RUNTIME_CONFIG_JSON` | `deploy-s3.yml` |
| `SSM_DEPLOY_DOCUMENT_ARN`, `SSM_DEPLOY_DOCUMENT_VERSION`, `SSM_AUTOMATION_ROLE_ARN`, `BACKEND_ASG_NAME`, `BACKEND_LAUNCH_TEMPLATE_ID`, `BACKEND_URL`, `BACKEND_ROLLBACK_ALARMS`, `BACKEND_REFRESH_CHECKPOINTS` | `deploy-ec2.yml` |

Repository-level: `SONAR_HOST_URL` (variable) and `SONAR_TOKEN` (secret), both optional.

## Versioning

- Tags `vMAJOR.MINOR.PATCH` are the human-readable channel; **callers pin the SHA** and put
  the tag in the comment. Dependabot keeps the pins current.
- The IAM trust policies (`job_workflow_ref`), the promotion-attestation identity check and
  the Kyverno policy's signer subject pin the same SHA (`ci/infra/`, `ci/policy/`). Bumping
  the template is therefore a coordinated change: new SHA in the caller, in the trust
  policies, in the admission policy.
- A change to this repository goes through its own pull request with `actionlint`
  (`ci/scripts/lint-workflows.sh`), zizmor 1.30.1 in pedantic mode (the exact commands are
  in the root README), `shellcheck`, `yamllint` and the Python unit tests
  (`ci/scripts/test_*.py`), and CODEOWNERS on `.github/workflows/`, `ci/` and `ci/infra/`.

## Layout

```
ci/
├── tools.env                 # pinned scanner/signing tool versions and SHA-256s
├── scripts/                  # everything the workflows run (bash + python, unit-tested)
├── infra/                    # IAM trust and permission policies, bucket policy, the deploy runbook
├── instance/                 # baked into the backend AMIs: bootstrap, the container, bundle and migration units
└── policy/                   # Kyverno admission policy for the container platform of Problem 1
```
