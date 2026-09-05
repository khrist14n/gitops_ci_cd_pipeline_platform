# New Relic observability

demo-app ships with **New Relic Python Agent + New Relic Logging** integrated.
It's fully GitOps-driven: the agent and structured JSON logging are compiled
into the image, but *enabled or disabled purely by config* in the environment
overlay. Nothing about enabling telemetry requires a rebuild.

## What you get

| Data | Mechanism |
|---|---|
| APM traces (FastAPI/uvicorn) | `newrelic` agent, initialized before app import |
| Logs | Structured JSON on stdout (includes `timestamp`, `level`, `logger`, `message`, request `method`/`path`/`status`, `duration_ms`) |
| Context linking | Every JSON log line carries `newrelic: {trace-id, span-id, entity.guid, hostname}` (`linking_metadata()`) so logs and traces correlate in one UI |
| Log forwarding | Agent forwards JSON stdout logs to New Relic and maps `newrelic.level` ≥ ERROR → Error logs |
| Errors | `GET /ops/fail` endpoint returns 500 for smoke-testing error attribution |

## Enable per environment

Turn it on in `gitops/environments/<env>.yaml`:

```yaml
telemetry:
  newrelic:
    enabled: true
    appNameOverride: demo-app-prod   # optional; defaults to <chart>-<namespace>
    logLevel: info                    # agent telemetry verbosity
    licenseKeySecret:
      name: newrelic-license-key
      key: NEW_RELIC_LICENSE_KEY
```

Team is disable-by-default in `gitops/environments/dev.yaml` and enabled in
`staging.yaml` / `prod.yaml`.

When `enabled=true`, the chart injects these env vars into the pod:

```
NEW_RELIC_LICENSE_KEY                 (from the referenced Secret)
NEW_RELIC_APP_NAME
NEW_RELIC_LOG_LEVEL
NEW_RELIC_HOST                        (default gov-collector.newrelic.com)
NEW_RELIC_DISTRIBUTED_TRACING_ENABLED=true
NEW_RELIC_APPLICATION_LOGGING_ENABLED=true
NEW_RELIC_APPLICATION_LOGGING_FORWARDING_ENABLED=true
NEW_RELIC_APPLICATION_LOGGING_METRICS_ENABLED=true
NEW_RELIC_APPLICATION_LOGGING_LOCAL_DECORATING_ENABLED=true
```

The app's `init_newrelic()` treats a missing `NEW_RELIC_LICENSE_KEY` as "stay
disabled" and logs a notice, so the image degrades safely.

## Provisioning the license key

See `infra/argocd/newrelic-license-key.Secret.example.yaml`. The key must be
**encrypted before it reaches the cluster** (Sealed Secrets or ExternalSecrets
Operator). Create the secret in each namespace that turns New Relic on:

```bash
kubectl create secret generic newrelic-license-key \
  --namespace demo-app-prod --from-literal=NEW_RELIC_LICENSE_KEY='<key>'
# or reconcile via ExternalSecret against Vault on rotate
```

## Local verification

```bash
cd apps/demo-app
python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
# Without a license key the agent logs "stays disabled" and JSON logs still work:
NEW_RELIC_APP_NAME=demo-app python -m uvicorn src.app:app --port 8080
curl -s localhost:8080/ops/fail
curl -s localhost:8080/version
# observe structured lines on stdout, e.g.
# {"timestamp":"...","level":"INFO","logger":"demo-app.src.app","method":"GET",...}
```

With a real license key set, APM appears in New Relic under
`demo-app` / `demo-app-prod`, and logs carry `newrelic.trace-id`/`span-id`
for record-level correlation.

## Query examples (NRQL)

- Access logs and APM in one view:
  `SELECT * FROM Log WHERE newrelic.entity.guid IS NOT NULL SINCE 1 hour ago`
- Slow transactions (time spent in traces): `SELECT sum(duration) FROM Transaction`
- Errors surfaced from app logs:
  `SELECT count(*) FROM Log WHERE `newrelic.level` = 'ERROR' FACET message`

## Troubleshooting

| Symptom | Check |
|---|---|
| No APM in New Relic | license key wired correctly? `NEW_RELIC_LICENSE_KEY` present in pod? `telemetry.newrelic.enabled=true`? |
| No logs forwarded | confirm JSON lines on stdout (see Local verification); verify `NEW_RELIC_APPLICATION_LOGGING_FORWARDING_ENABLED=true` |
| Europe/other accounts | overrides `NEW_RELIC_HOST` in the env overlay (default is gov-collector.newrelic.com) |
| Correlating missing traces | agent must be initialized before library import — see `init_newrelic()` ordering in `src/app.py` |