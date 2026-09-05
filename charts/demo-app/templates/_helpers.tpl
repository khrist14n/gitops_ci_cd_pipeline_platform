{{- define "demo-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "demo-app.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "demo-app.labels" -}}
helm.sh/chart: {{ include "demo-app.chart" . }}
app.kubernetes.io/name: {{ include "demo-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "demo-app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "demo-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "demo-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "demo-app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "demo-app.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "demo-app.newrelicAppName" -}}
{{- if .Values.telemetry.newrelic.appNameOverride }}
{{- .Values.telemetry.newrelic.appNameOverride }}
{{- else }}
{{- printf "%s-%s" (include "demo-app.name" .) .Release.Namespace }}
{{- end }}
{{- end }}

{{- define "demo-app.newrelicEnv" -}}
{{- if .Values.telemetry.newrelic.enabled }}
- name: NEW_RELIC_LICENSE_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.telemetry.newrelic.licenseKeySecret.name }}
      key: {{ .Values.telemetry.newrelic.licenseKeySecret.key }}
- name: NEW_RELIC_APP_NAME
  value: {{ include "demo-app.newrelicAppName" . }}
- name: NEW_RELIC_LOG_LEVEL
  value: {{ .Values.telemetry.newrelic.logLevel }}
- name: NEW_RELIC_HOST
  value: {{ default "gov-collector.newrelic.com" .Values.telemetry.newrelic.host }}
- name: NEW_RELIC_DISTRIBUTED_TRACING_ENABLED
  value: {{ .Values.telemetry.newrelic.distributedTracingEnabled | quote }}
- name: NEW_RELIC_APPLICATION_LOGGING_ENABLED
  value: "true"
- name: NEW_RELIC_APPLICATION_LOGGING_FORWARDING_ENABLED
  value: {{ .Values.telemetry.newrelic.logForwardingEnabled | quote }}
- name: NEW_RELIC_APPLICATION_LOGGING_METRICS_ENABLED
  value: "true"
- name: NEW_RELIC_APPLICATION_LOGGING_LOCAL_DECORATING_ENABLED
  value: "true"
{{- end }}
{{- end }}

{{- define "demo-app.image" -}}
{{- if .Values.image.digest }}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest }}
{{- else }}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) }}
{{- end }}
{{- end }}