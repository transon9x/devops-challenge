# AWS prerequisites the pipelines consume but do not create

Illustrative policy documents with `<PLACEHOLDERS>`, not deployable IaC. A pipeline that can
create its own roles is a privilege-escalation path, so the boundary is deliberate.

## Roles

| Role | Trust | Permissions | Assumed by |
|---|---|---|---|
| `gha-<app>-publish` | [`trust-publish-role.json`](trust-publish-role.json): `sub` is ref-based (`main`), `job_workflow_ref` = `build-publish.yml@<TEMPLATE_SHA>` | [`policy-publish-role.json`](policy-publish-role.json): push to one ECR repository, never delete or retag | `build-publish.yml` |
| `gha-backend-deploy-{dev,prod}` | [`trust-deploy-backend-*-role.json`](trust-deploy-backend-dev-role.json): `sub` and `environment` claims name the environment, `job_workflow_ref` = `deploy-ec2.yml@<TEMPLATE_SHA>` | [`policy-deploy-backend-*-role.json`](policy-deploy-backend-dev-role.json): start **one numbered version** of **one** Automation document, read its outcome, read (dev: write) promotion markers; explicit deny on every EC2, Auto Scaling, load-balancer and Session Manager action | `deploy-ec2.yml` |
| `gha-frontend-deploy-{dev,prod}` | [`trust-deploy-frontend-*-role.json`](trust-deploy-frontend-dev-role.json) | [`policy-deploy-frontend-*-role.json`](policy-deploy-frontend-dev-role.json): write `index.html`, `config.json`, `assets/*` in one bucket, invalidate one distribution | `deploy-s3.yml` |
| `deploy-runbook-{dev,prod}` | [`trust-runbook-role.json`](trust-runbook-role.json): `ssm.amazonaws.com` from this account only | [`policy-runbook-role.json`](policy-runbook-role.json): new versions of **one** launch template, instance refresh on **one** group, read the promotion marker; deny Run Command, Session Manager, RunInstances | the Automation runbook, never a person or the runner |
| `gha-migrate-{dev,prod}` | [`trust-migrate-*-role.json`](trust-migrate-dev-role.json): as the deploy roles, with `job_workflow_ref` = `migrate-db.yml@<TEMPLATE_SHA>` | [`policy-migrate-*-role.json`](policy-migrate-dev-role.json): start **one numbered version** of the migration document and read its outcome, read (dev: write) migration markers; explicit deny on every RDS, `rds-db:connect`, Parameter Store, Secrets Manager, EC2 and Session Manager action, so the runner can ask for a migration but never perform one | `migrate-db.yml` |
| `migrate-runbook-{dev,prod}` | [`trust-migrate-runbook-role.json`](trust-migrate-runbook-role.json): `ssm.amazonaws.com` from this account only | [`policy-migrate-runbook-role.json`](policy-migrate-runbook-role.json): snapshot **one** cluster, launch **one** instance from **one** launch template, tag and terminate only a host tagged `app:job=migrate`, read the result parameter; deny Run Command, Session Manager, `rds-db:connect` and every destructive RDS action | the migration runbook |
| `backend-migrate-job` | EC2 | [`policy-migrate-job-instance-role.json`](policy-migrate-job-instance-role.json): pull and verify one repository, read the database endpoint, connect **only** as `app_migrator`, publish its own result parameter | the ephemeral migration host |
| `backend-instance` | EC2 | [`policy-instance-role.json`](policy-instance-role.json): pull one image repository, read one Parameter Store path, write one log group | the EC2 instances |

Every GitHub trust policy uses `StringEquals` on `aud`, the **immutable** `sub`
(`repo:<ORG>@<OWNER_ID>/<REPO>@<REPO_ID>:…`, the format repositories created after
15 July 2026 emit), `repository_id`, `repository_owner_id`, `ref` and `job_workflow_ref`
pinned to the template commit. A caller that pins a different template SHA cannot assume
any role until the trust policies are updated: bumping the template is a coordinated change.
Confirm the exact `job_workflow_ref` value from a real token before enforcing it, because a
nested reusable call inherits the ref of the workflow the application pinned.

No IAM user and no access key exists anywhere in this design. The `StringLike` operators
were avoided on purpose; `ForAllValues` evaluates true when a claim is absent.

## Buckets, registry, runbook

- **Promotion bucket**: versioned; [`bucket-policy-promotions.json`](bucket-policy-promotions.json)
  denies deletes to everyone, keeps versioning on, and lets only the two **dev** deploy roles
  write under `promotions/` (the two deploy roles and the migration role). Production reads
  markers and cannot write them.
- **ECR repositories** `backend` and `frontend`: tag immutability on, scan on push on, a
  lifecycle policy that never expires images referenced by a promotion marker (enforced by
  keeping `sha-*` tags for at least the retention window). Deploys never use a tag.
- **Deploy runbook** [`ssm-automation-deploy-ec2.yaml`](ssm-automation-deploy-ec2.yaml):
  registered once per environment as an Automation document; the deploy role may start only
  the document version recorded in `vars.SSM_DEPLOY_DOCUMENT_VERSION`. A change to the
  runbook is a new document version plus a variable change, reviewed like code.
- **Migration runbook** [`ssm-automation-migrate-db.yaml`](ssm-automation-migrate-db.yaml):
  registered per environment like the deploy runbook. It refuses `$Latest` and `$Default`
  launch-template versions, so editing a template cannot change what the job runs. The
  database user `app_migrator` holds DDL on the application schema and is reachable only
  through IAM authentication from the job's instance role; the runtime user has no DDL.
- **Launch template**: IMDSv2 required, instance metadata tags enabled, no key pair, no user
  data, the instance profile above, and an instance tag `app:artifact-digest`. The runbook
  refuses a template that violates any of these (`ci/scripts/launch_template.py`). A fleet
  that runs the application without a container adds the static tag
  `app:artifact-kind=bundle`; a deploy never changes it, only the digest.
- **Auto Scaling group**: pins a **numbered** launch-template version (never `$Latest`),
  ELB health checks, at least two instances in two AZs, a target group whose
  deregistration delay exceeds the container's graceful stop.
- **AMI** (EC2 Image Builder): pinned cosign and oras, the units and bootstrap from
  [`../instance/`](../instance/) — container fleets also install
  `backend-bootstrap.service.d/10-docker.conf`, which is the only place the Docker
  dependency lives — `ci/scripts/extract-bundle.py` and `ci/scripts/sql_guard.py`
  installed at `/opt/backend/`, `/etc/backend/bootstrap.env` from
  [`../instance/bootstrap.env.example`](../instance/bootstrap.env.example), **no `sshd`**,
  SSM agent for audited Session Manager break-glass only. Container fleets add Docker;
  bundle fleets add the Node runtime and a `backend` service user instead, and the migration
  AMI adds `psql`, the RDS CA bundle, a `migrator` user and the enabled
  `backend-migrate-guard.timer`, a dead-man switch that powers the job host off after 45
  minutes so a runbook failure cannot leave a host with database access running. Every AMI is scanned in its own
  Image Builder pipeline and the fleet is scanned continuously by Inspector, because without
  a container rebuild the OS is only refreshed when the AMI is.
- **CloudWatch alarms** named in `vars.BACKEND_ROLLBACK_ALARMS`: ALB target 5xx rate and
  unhealthy-host count, treating missing data as not breaching.

## GitHub configuration that IAM cannot replace

- Environments `dev` and `prod` with a **deployment-branch rule limited to `main`** on both,
  and required reviewers on `prod`. The environment-scoped OIDC subject proves the
  environment, not the branch.
- Branch protection on `main` of the application repositories and of `ci-templates`;
  CODEOWNERS on `.github/workflows/`.
- Repository variables and secrets listed in [`../README.md`](../README.md).
