# Testing

Everything is covered by `scripts/run-tests.sh` **and** by CI (`ci.yaml`,
`verify-gitops.yaml`). Run the full local surface first:

```bash
./scripts/run-tests.sh              # full suite
./scripts/run-tests.sh --app-only   # app unit tests + ruff + chart lint
tox                                 # pytest + ruff check/format (py, lint)
pre-commit run --all-files          # ruff + ruff-format + hygiene hooks
```

All phases PASS/SKIP/FAIL independently and exit non-zero on any failure.

## Prerequisites

| Tool | Needed for | Install |
|---|---|---|
| `python3` + `pyyaml` | app tests, YAML checks, scripts | `apt install python3 python3-yaml` |
| `helm` | chart lint + render | `curl -fsSL https://get.helm.sh/helm-v3.15.4-linux-amd64.tar.gz \| tar -xz` |
| `kubectl` | kustomize build of ArgoCD manifests | `snap install kubectl` or distro package |
| `actionlint` | GitHub Actions workflow lint | download release binary from `rhysd/actionlint` |
| `git` | hooks, scripts e2e, promotion | distro package |
| `pre-commit` | local git hooks | `pip install pre-commit` |

Python dev tools (`ruff`, `tox`, `pytest`, `httpx`) are pinned in
`apps/demo-app/requirements-dev.txt` and installed by `tox`/`run-tests.sh`
automatically.

Note: steps that need a missing tool are reported as `SKIP`, not `FAIL`.

### 0. Install git hooks (once)

```bash
pre-commit install
```

From now on every commit runs `ruff --fix`, `ruff-format`, trailing-whitespace,
end-of-file, merge-conflict and YAML checks (Helm Go-template files excluded —
those go through `helm lint`).

## Step-by-step

### 1. Application unit tests

```bash
python3 -m venv .venv
.venv/bin/pip install -r apps/demo-app/requirements-dev.txt
cd apps/demo-app && ../../.venv/bin/python -m pytest tests -q
```

Expected: `6 passed` (includes New Relic JSON logging + middleware tests).

Or through tox (same result, isolated env):

```bash
tox -e py
```

### 2. Lint + format (ruff)

```bash
ruff check apps/demo-app                 # rule set: E, F, I, UP, B
ruff format --check apps/demo-app
```

Or through tox:

```bash
tox -e lint
```

Auto-fix before committing: `ruff check apps/demo-app --fix`.

`pyproject.toml` pins the rule set and line length; `apps/demo-app/src/app.py`
excludes `E402`/`I001` for the intentional "New Relic agent before framework
import" ordering.

### 2. Helm chart lint

```bash
helm lint charts/demo-app
```

Expected: `1 chart(s) linted, 0 chart(s) failed`.

### 3. Render chart against every environment overlay

```bash
helm template demo-app charts/demo-app -f gitops/environments/dev.yaml \
  --set-string image.repository=ghcr.io/example/demo-app
```

Repeat for `staging.yaml` and `prod.yaml`. Verify:
- `dev` renders a **Deployment** (no Rollout)
- `staging`/`prod` render a **Rollout** + **AnalysisTemplate** with the HPA targeting the Rollout
- expected object counts: dev `5`, staging `8`, prod `9`

### 4. YAML syntax check

All non-template YAML must parse (note: `charts/demo-app/templates/*` contain
Go template syntax and are only validated by `helm template`).

```bash
python3 - <<'PY'
import glob, yaml
for f in glob.glob('**/*.yaml', recursive=True):
    if not f.startswith('charts/demo-app/templates/'):
        yaml.safe_load(open(f)) or None
print('all non-template YAML parses OK')
PY
```

### 5. ArgoCD manifests via kustomize

```bash
kubectl kustomize infra/argocd
```

Expected: `ConfigMap, ConfigMap, ConfigMap, AppProject, ApplicationSet`.

### 6. Workflow validation with actionlint

```bash
actionlint .github/workflows/*.yaml
```

Expected: no output (exit 0).

### 7. Promotion + rollback scripts e2e

`run-tests.sh` performs this in a scratch git repo. Manual equivalent:

```bash
SCRATCH=$(mktemp -d)
cp -r apps charts gitops scripts "$SCRATCH"
cd "$SCRATCH" && git init -b main && git add -A && git commit -m v0

./scripts/promote-image.sh demo-app prod ghcr.io/example/demo-app@sha256:feedface
# overlay files now pin digest: sha256:feedface  (digest pin wins over tag)

git checkout main && git merge --no-ff promotion/demo-app-prod -m merge
./scripts/rollback.sh demo-app prod --to-previous
# overlay returns to tag: latest, digest removed
```

## What CI runs automatically

| Workflow | Scope | Tests covered |
|---|---|---|
| `ci.yaml` | `apps/**` changes | **`lint` job: `tox -e lint` (ruff check + format check)**, app unit tests, `helm lint`, `helm template` of every chart, buildx image build, SBOM + Trivy scan gate |
| `verify-gitops.yaml` | PRs touching `charts/**`/`gitops/**` | helm lint, render of every env overlay, promotion PRs may only change `image`/`tag`/`digest`/`repository` keys, Application descriptor validation |
| `drift-detect.yaml` | cron 30 min | sync/health reconciliation of ArgoCD applications |

CI's `lint` job runs exactly the same command as the local `tox -e lint`, so a
pass locally is a pass in CI.

## Adding a new app

1. Create `apps/<app>/Dockerfile` + tests (pytest/httpx for Python services), kept ruff-clean — `tox -e lint` covers all `apps/`.
2. Add a chart under `charts/<app>/` — it is picked up automatically by `helm lint`/render loops.
3. Add `gitops/environments/*` overlays and `gitops/applications/<app>/{dev,staging,prod}.yaml`.
4. Run `./scripts/run-tests.sh`, `tox`, and `pre-commit run --all-files` before opening the PR — all three gates mirror CI.