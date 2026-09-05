# GitOps CI/CD Pipeline Platform

A production-grade GitOps CI/CD platform architected for **200+ deployments per day** built on:

- **GitHub Actions** — build, test, scan, and orchestrate promotion (OIDC workload identity, zero long-lived secrets)
- **ArgoCD** — declarative GitOps delivery with automated sync, self-heal, and drift detection
- **Helm** — templated release packaging with atomic upgrades and automatic rollback on failure

## Highlights

| Capability | Mechanism |
|---|---|
| Throughput (200+ deploys/day) | Matrix builds, layer caching, deploy lock per app/env, parallel promotion |
| Security | GitHub OIDC → short-lived cloud/registry/cluster creds, SBOM + image scan gates |
| Delivery | ArgoCD ApplicationSet per environment, Helm `--atomic --wait --timeout` |
| Automated rollback | Health-gate auto-revert of GitOps tag + Argo Rollouts metric analysis + drift CI |
| Observability | Prometheus ServiceMonitor, Alertmanager, deployment-stack webhook → GitHub |
| Compliance | Signed commits, SBOM, policy via Kyverno hooks, audit trail in git |

## Layout

```
apps/                   Application source code + Dockerfiles
charts/                 Helm charts owned by the platform
gitops/environments/    Per-env values overlays (dev, staging, prod)
gitops/applications/    ArgoCD Application manifests
gitops/project/         ArgoCD AppProject
infra/argocd/           ArgoCD controller config, RBAC, ApplicationSet
scripts/                Promotion, rollback, release-tag helpers
docs/                   Architecture & runbook
```

## Getting started

```bash
# Run the full test suite locally (app tests, ruff lint, helm lint/render, yaml,
# kustomize, actionlint, promote/rollback e2e) — then promote to dev:
./scripts/run-tests.sh
tox                                  # pytest + ruff (same gate as CI's lint job)
pre-commit install                   # git hooks: ruff, ruff-format, hygiene

# Promote the latest built image to dev (CI automation or manual)
./scripts/promote-image.sh demo-app dev <image-digest>

# Dry-run the dev release locally
helm lint charts/demo-app
helm template charts/demo-app -f gitops/environments/dev.yaml --dry-run \
  --set image.tag=$(cat apps/demo-app/src/VERSION)

# Bootstrap ArgoCD from this repo
kubectl apply -k infra/argocd   # generates ApplicationSet + AppProject
```

See [docs/architecture.md](docs/architecture.md) for the full design,
[docs/testing.md](docs/testing.md) for step-by-step test instructions,
[docs/newrelic.md](docs/newrelic.md) for the app's New Relic (APM + logs)
integration, and [docs/runbook.md](docs/runbook.md) for operational procedures.
