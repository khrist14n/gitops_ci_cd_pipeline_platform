---
name: probe-resource-config
description: Probe and audit the correctness and internal consistency of this project's infra and Kubernetes resource configuration — cross-file checks of replicaCount vs HPA/PDB, resource requests vs limits, prod digest pinning, Rollout vs Deployment per environment, ingress/telemetry/serviceMonitor placement, ArgoCD AppProject/RBAC/ApplicationSet consistency, secret hygiene, and security contexts; optionally live-check kubectl/argocd state. Use when the user asks to "probe", "audit", "verify the config", "cross-check resource config", or find out "is the infra correctly configured".
---

# Probing infra & resource configuration

Probe whether the infra and resource configuration is **correct** — internally
consistent and sane — not merely well-formed (for well-formedness use the
`test-infra-config` skill). Read-only; never edit files.

## 0. Load the source of truth first

Read `charts/demo-app/values.yaml`, `gitops/environments/{dev,staging,prod}.yaml`,
`gitops/applications/demo-app/*.yaml`, and `infra/argocd/*.yaml`. Every check
below is derived from these files.

## 1. Static consistency probes

Run each probe and record PASS / FAIL with `file:line` evidence. A probe whose
tool is missing (e.g. `helm`) reports SKIP.

### Resource requests/limits
- In `values.yaml` and every env overlay: **memory and CPU request ≤ limit**.
  Flag limits without requests, or requests without limits.
- HPA `maxReplicas >= minReplicas`; PDB `minAvailable <= maxReplicas` when
  autoscaling is enabled, otherwise `<= replicaCount`. Prod PDB (`minAvailable: 8`)
  must be satisfiable by prod `replicaCount: 10`.
- Overlay resources must not contradict the HPA CPU target
  (`targetCPUUtilizationPercentage`).

### Workload kind by environment
- `dev` (`progressiveDelivery.enabled: false`) → expect a **Deployment** only.
- `staging`/`prod` (`enabled: true`) → expect a **Rollout + AnalysisTemplate**,
  and the HPA must target apiVersion `argoproj.io/v1alpha1`, kind `Rollout`
  (not Deployment). Confirm with `helm template`.
- Ingress enabled **only** in prod (`className: nginx`, host `demo-app.example.com`);
  `serviceMonitor` enabled in all three environments.

### Image supply chain
- `prod` overlay must pin an **immutable digest** (never bare `tag: latest`);
  `dev`/`staging` may use a tag. Flag `tag`+`digest` coexistence where the chart
  resolves one silently — check `demo-app.image` in
  `charts/demo-app/templates/_helpers.tpl`.
- `image.repository` must match what `scripts/promote-image.sh` writes.
- `imagePullPolicy` must not be `Always` for digest-pinned images.

### Telemetry / New Relic
- `telemetry.newrelic.enabled` **only** in staging/prod. The chart must inject
  `NEW_RELIC_LICENSE_KEY` from the secret `newrelic-license-key`
  (key `NEW_RELIC_LICENSE_KEY`) in the destination namespace for those envs, and
  omit it in dev. Verify by grepping `helm template` output.

### Security context
- Overlays must not weaken the chart defaults: `runAsNonRoot: true`,
  `runAsUser: 10001`, `allowPrivilegeEscalation: false`,
  `readOnlyRootFilesystem: true`, `seccompProfile RuntimeDefault`, no
  `privileged: true`. Flag any overlay override.

### Probes / lifecycle
- Deployment and Rollout templates both carry liveness (`/healthz`) and
  readiness (`/readyz`) http probes. Flag missing probes or `failureThreshold`
  values that would make the canary/rollout flaky.

### ArgoCD consistency
- AppProject `destinations[].namespace` pattern `demo-app-*` must cover every
  Application descriptor `destNamespace` (`demo-app-<env>`).
- AppProject `sourceRepos` must include the ApplicationSet `source.repoURL`
  and the chart image registry.
- ApplicationSet generator (`gitops/applications/**/*.yaml`) descriptors must
  each carry `app, env, chartPath, targetRevision, destNamespace, valuesFile`.
- RBAC: `argocd-rbac-cm` `role:ci-deploy` grants on `gitops-platform/*`
  (the AppProject name) must match the AppProject roles, and the sync window
  must deny `*-prod` outside working hours.
- `kubectl kustomize infra/argocd` must render the expected resource set, and
  `argocd-cm` must enable `applicationset.enable.goTemplate` +
  `application.resourceTrackingMethod: annotation`.

### Secret hygiene
- Scan committed YAML for secrets: only placeholders (`replace-me`,
  `replace-with-provisioned-key`, empty `stringData`) may exist in `.example`
  files. FAIL if any real credential or plaintext secret is committed, or any
  Secret lacks SealedSecret/ExternalSecret-style encryption annotations.

## 2. Live cluster probes

Optional — only run if a cluster is reachable. Detect first:
`kubectl cluster-info` (failure → SKIP the live section; never invent results).

- `kubectl -n argocd get applicationset,appprojects`, and for each app:
  ```bash
  kubectl -n argocd get app demo-app-{dev,staging,prod} \
    -o jsonpath='{.metadata.name}{", "}{.status.sync.status}{", "}{.status.health.status}{"\n"}'
  ```
  Expect `Synced` + `Healthy` for all three; flag `OutOfSync`/`Degraded`/drift.
- `kubectl -n demo-app-<env> get deploy,rollout,hpa,pdb,svc,ingress,servicemonitor`
  — the resource set present must match the static expectation (dev: Deployment;
  staging/prod: Rollout; HPA/PDB everywhere except dev; ingress only in prod).
- If the `argocd` CLI is available, use `scripts/deploy-status.sh <app> <env>` to
  report sync/health/revision/images.
- Confirm running replicas ≥ PDB `minAvailable`, the HPA is within
  min/max range, and there is no cluster-side drift on the tracked resources.

## 3. Report

Concise PASS / SKIP / FAIL per probe with `file:line` evidence for every FAIL
and, for live probes, the observed state vs the expected state. Do not fix
findings unless the user asks.