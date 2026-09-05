# Runbook

## How a deployment happens

1. `git push` to `apps/**` → `ci.yaml` builds and publishes the image.
2. Operator or automation runs `scripts/promote-image.sh <app> <env> [image-tag]`.
   If no tag is given, the latest build for that app is discovered.
3. The script creates/updates a `promotion/<app>-<env>` branch with the pinned digest in
   `gitops/applications/<app>/<env>.yaml` **and** the env values `image.tag`.
4. `deploy.yaml` verifies the PR, merges to `main` → ArgoCD Application auto-syncs.
5. ArgoCD applies the Helm chart (atomic). Post-sync health gate verifies readiness.
6. `deploy-status.sh` reports revision + sync state back to the PR / Slack.

## Manual rollback

```bash
# GitOps-native: revert the promoted commit
./scripts/rollback.sh demo-app prod --to-previous

# Or via ArgoCD CLI
argocd app rollback demo-app-prod <previous-revision>
argocd app sync demo-app-prod
```

## Emergency hotfix (bypass sync gating)

```bash
kubectl -n prod scale deploy demo-app --replicas=3
# ArgoCD detects drift; AllowBackingOutOfSyncPatch keeps the runtime change until
# the git state is updated, then self-heals.
```

## Common incidents

| Symptom | Check | Fix |
|---|---|---|
| `deploy.yaml` failed on sync timeout | `helm -n <ns> history <app>` | `helm rollback` succeeded automatically; verify gate re-runs |
| App CrashLoopBackOff after deploy | `kubectl get events -n <ns>` | Root-cause in image; revert promotion PR |
| ArgoCD shows `OutOfSync` with no recent commit | `argocd app diff demo-app-prod` | Manual patch → `kubectl rollout undo` or apply git state |
| Canary stuck at 10% | Rollout analysis in pause | Check Prometheus query; escalate if SLO true-positive |
| Drift alert every cron | `drift-detect.yaml` logs | Find non-git mutation; revert or document as allowed |

## Metrics

- **Deploy frequency**: ArgoCD exporter `argocd_app_sync_total`
- **Change failure**: webhook stack tracking failed `deploy.yaml` runs per app
- **MTTR**: time from `deploy.yaml` failure to `rollback.yaml` completion
- **Drift**: `argocd_app_sync_status{comparedTo>"0"}`

## Bootstrap

```bash
export KUBECONFIG=$HOME/.kube/cluster-prod
helm repo add argo https://argoproj.github.io/argo-helm
# ArgoCD
helm upgrade --install argocd argo/argo-cd --namespace argocd --create-namespace \
  --set server.insecure=true --set configs.params.enable.Dex=false
# Rollouts controller (needed for canary/auto-rollback)
helm upgrade --install argo-rollouts argo/argo-rollouts --namespace argocd \
  --set fullnameOverride=argo-rollouts controller.installCRDs=true
# Register the GitOps repo + pull secrets, then:
kubectl apply -f infra/argocd/ApplicationSet.yaml   # creates all Applications
kubectl apply -f infra/argocd/app-project.AppProject.yaml
```