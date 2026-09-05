---
name: test-infra-config
description: Run the full static validation/test surface for this GitOps platform's infra and resource configuration — scripts/run-tests.sh, tox, Helm lint and per-environment render, kubectl kustomize of infra/argocd, YAML syntax checks, actionlint, and the promotion/rollback e2e. Use when the user asks to "run the tests", "validate the infra config", "is the chart/config valid", "check the Helm charts or GitHub Actions workflows", or "verify nothing is broken before merging".
---

# Testing infra & resource configuration

Validate that the infra and resource config in this repo is well-formed and
passes the same gates CI runs. This skill is read-only — never modify files.

Prerequisite convention (same as `scripts/run-tests.sh`): a phase whose tool is
missing is reported as **SKIP**, not FAIL. Only report **FAIL** when the tool
ran and the check truly failed.

## 1. Run the canonical harness

```bash
./scripts/run-tests.sh              # full suite
./scripts/run-tests.sh --app-only   # app tests + ruff + chart lint only
tox                                 # pytest + ruff (same gate as CI lint job)
pre-commit run --all-files          # ruff + ruff-format + hygiene hooks
```

Expect every phase to print `[PASS]` / `[SKIP]` / `[FAIL]` plus a final
`summary: pass=.. fail=.. skip=..`. Exit code is non-zero if any phase FAILed.

`run-tests.sh` writes per-phase logs to `/tmp/opencode-test-*.log`. When a phase
FAILs, read that log and quote the root cause back to the user.

## 2. Run targeted gates

When the user asks about one specific area, run just that gate:

- **App unit tests**: create/use `.venv`, install `-r apps/demo-app/requirements-dev.txt`, then
  `(cd apps/demo-app && ../../.venv/bin/python -m pytest tests -q)` — expect `6 passed`.
  Equivalent: `tox -e py`.
- **Lint + format**: `ruff check apps/demo-app && ruff format --check apps/demo-app`. Equivalent: `tox -e lint`.
- **Helm chart lint**: `helm lint charts/demo-app` — expect `1 chart(s) linted, 0 chart(s) failed`.
- **Render each env overlay** and assert the output parses as k8s objects:
  ```bash
  for env in dev staging prod; do
    helm template demo-app charts/demo-app -f gitops/environments/$env.yaml \
      --set-string image.repository=ghcr.io/example/demo-app \
      | python3 -c 'import sys,yaml; docs=[d for d in yaml.safe_load_all(sys.stdin) if d]; assert docs and all(d.get("apiVersion") and d.get("kind") for d in docs)'
  done
  ```
- **New Relic wiring**: rendered `staging` and `prod` output must contain
  `NEW_RELIC_LICENSE_KEY`; rendered `dev` must not.
- **YAML syntax**: every `**/*.yaml` / `**/*.yml` must parse with
  `yaml.safe_load`, *except* `charts/demo-app/templates/**` (Go-template syntax,
  validated only by `helm template`).
- **ArgoCD manifests**: `kubectl kustomize infra/argocd` — expect the resource set
  `ConfigMap, ConfigMap, ConfigMap, AppProject, ApplicationSet`.
- **Workflow lint**: `actionlint .github/workflows/*.yaml` (5 workflows) — expect
  empty output / exit 0.
- **Promotion/rollback e2e**: `run-tests.sh` runs it in a scratch git repo
  (promote pins `sha256:feedface` into prod, rollback reverts to `tag: latest`).

## 3. Expected outcomes to verify

- Rendered object counts (from `docs/testing.md`): **dev 5**, **staging 8**, **prod 9**.
  `staging`/`prod` render a **Rollout + AnalysisTemplate** (HPA targeting the
  Rollout); `dev` renders a **Deployment** and no Rollout.
- `run-tests.sh`, `tox`, and `pre-commit` mirror CI — a local pass is a CI pass.

## 4. Report

Report a compact checklist: each gate → PASS / SKIP / FAIL, the log path and
root cause for any FAIL, and the tool install guidance already in
`docs/testing.md` (helm, kubectl, actionlint) for SKIPed phases. Do not claim
to have fixed anything.