# Architecture

## 1. High-level flow

```
                       ┌──────────────────────────────────────────────┐
                       │  github.com/<org>/gitops-platform repo       │
                       └──────────────────────────────────────────────┘
 apps/* → CI (build/test) → registry → Sbom/scan → tag
                                              │
                              promote-image.sh (bot commit/PR)
                                              ▼
                        gitops/applications + gitops/environments
                                              │  merge to main = desired state
                                              ▼
                          ┌───────────────────────────────────────────┐
                          │ ArgoCD: ApplicationSet renders an         │
                          │ Application per (app, environment)         │
                          └───────────────────────────────────────────┘
                                     │ automated.sync + selfHeal
                                     ▼
                              Helm release  (atomic, timeout, hooks)
                                     │
                                     ▼
                 ┌──────────────────────────────────────────────┐
                 │  K8s: Deployment → Service → HPA/PDB/Ingress │
                 │  Rollouts (canary) → metric analysis (auto    │
                 │  rollback) → Dashboard stack → webhooks       │
                 └──────────────────────────────────────────────┘
```

## 2. CI/CD pipeline (GitHub Actions)

**`ci.yaml`** on every push/PR:
1. Validate Helm charts (`helm lint` + `helm template` diff)
2. Unit/integration tests (matrix by service)
3. Buildx multi-arch image build with **registry layer cache**
4. `docker sbom` + gated scanners (Trivy/`ghcr.io` native scanning)
5. Tag and push: `ghcr.io/<org>/<app>:<semver>-<sha>` (signed)
6. Return a machine-readable **release manifest** (artifact: `image-tag.txt`)

**`deploy.yaml`** on merge/`deployment` repository_dispatch:
1. Concurrency lock `deploy-<app>-<env>` — serializes same-app/env releases (no interleaved state)
2. `promote-image.sh` — writes the new digest into env values on a **promotion branch**
3. PR is verified by a status-check workflow; merge to `main` triggers ArgoCD sync
4. Post-sync **health gate** monitors rollout; on failure, auto-revert + `argocd app rollback`

**`rollback.yaml`** — manual or webhook-triggered (workflow_dispatch / repository_dispatch from Alertmanager):
reverts the environment values to the last-known-good tag and force-resyncs ArgoCD.

**`drift-detect.yaml`** — cron drift + reconciliation metrics; pages if a namespace drifts > threshold.

### Identity: GitHub OIDC (no stored cloud secrets in Actions)

- `permissions: id-token: write` in jobs.
- AWS: role assumption via `aws-actions/configure-aws-credentials@v4` with `role-to-assume` scoped by
  repo + environment (`repo:owner/name:environment:prod`).
- Registry pushes, cluster `kubeconfig` (short-lived STS token) and ArgoCD tokens are all minted at
  runtime from the same OIDC role. Static tokens exist only in ArgoCD's sealed secret.

## 3. Delivery model (ArgoCD + Helm)

### ApplicationSet

```
infra/argocd/ApplicationSet.yaml
```

- `generators: []` over app × environment from `gitops/`.
- Each Application targets a **path** `gitops/applications/<app>/<env>.yaml`, points at the Helm chart
  repo of this same source, and sets:
  - `syncPolicy.automated.syncOptions`: `CreateNamespace=true`, `ServerSideApply=true`, `Replace=true`
  - `syncPolicy.automated.prune: true`, `selfHeal: true`
  - `syncPolicy.automated.allowEmpty: false`
  - `syncPolicy.retry`: 5 attempts, backoff 5s/10s/3×
- Per-environment cluster/dest mapped via the environment overlay.

### Sync sequence (Helm hooks)

1. `pre-install/pre-upgrade`: config-maps, migrations, DB checks
2. workload rollout with `--atomic --wait --timeout 5m`
3. `post-upgrade`: smoke test + connectivity checks
4. **ROLLBACK**: Helm releases are `atomic` → any failed hook or health timeout triggers
   `helm rollback` automatically; for ArgoCD-native flows ArgoCD reverts to `revisionHistoryLimit`
   revision and self-heals to the last-good git state.

### Progressive delivery (auto rollback by analysis)

`charts/demo-app/templates/rollout.yaml` uses **Argo Rollouts** for environments with
`progressiveDelivery.enabled=true`:

- Canary: 10% → 50% → 100% with per-step `pause`.
- `AnalysisTemplate` queries Prometheus for error-rate / SLO burn; a failure fatally aborts the canary,
  triggers immediate **auto-rollback** to the stable ReplicaSet and pages the SRE channel.

## 4. Throughput engineering (the 200+/day part)

- **Deploy lock** — one deploy per `(app, env)` at a time; different apps/envs run fully parallel.
- **Cached builds** — buildx `cache-to/from: type=registry`; unchanged layers are never rebuilt.
- **Batched promotion** — the promotion branch is shared for the merge window, so N apps merged in a
  minute coalesce into a single ArgoCD sync.
- **Registry pull-through caching** — namespaces pin base images to the internal mirror.
- **Stateless controller rack** — ArgoCD, Rollouts, and the regression suite all run in-cluster with
  HPA; the only fragile resource is git, which is authoritative and replicated.
- **Dedicated runner pool** — self-hosted runners with Kubernetes executor (3s cold start, no
  per-job VM burn).

## 5. Automated rollback playbook

| Trigger | Action | Time |
|---|---|---|
| `helm upgrade --atomic` failure (hooks/timeout) | Helm rolls back, `deploy.yaml` marks job failed | < 5 min |
| Post-sync health gate fail (readiness/liveness) | `rollback.yaml` reverts env values + `argocd app rollback` | < 3 min |
| Canary metric violation (error rate/SLO) | Argo Rollouts auto-abort + revert | ~ analysis interval |
| Drift (manual edits to cluster) | `drift-detect.yaml` → force resync + alert | < 15 min |
| LivenessProbe failing in prod | ServiceMesh circuit-breaker + webhook to GitHub dispatch | sub-minute |

Rollback is **idempotent and git-authoritative**: reverting the environment overlay is the same
operation as reverting any other manifest — git history is the audit trail.

## 6. Observability & compliance

- **Metrics**: Prometheus Operator, ServiceMonitor per service, kube-state-metrics, ArgoCD exporter.
- **Alerts**: Alertmanager → Slack/email webhook → GitHub `repository_dispatch` auto-rollback.
- **Dashboards**: grafana dashboards for deploy frequency, lead time, change-failure-rate, MTTR (DORA).
- **Policy**: Kyverno cluster-policies enforced at sync (privileged containers, imagePullPolicy,
  required labels); `AllowBackingOutOfSyncPatch(true)` for emergency hotfixes.
- **Audit**: all changes are git commits via promotion bot (signed with GPG); every rollback is a
  revert commit, visible in `git log`.