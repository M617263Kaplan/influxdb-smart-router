{{/* Chart name */}}
{{- define "isr.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Fully qualified release name */}}
{{- define "isr.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/* Common labels */}}
{{- define "isr.labels" -}}
app.kubernetes.io/name: {{ include "isr.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/* Selector labels — stable across upgrades */}}
{{- define "isr.selectorLabels" -}}
app.kubernetes.io/name: {{ include "isr.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Image reference. image.tag is REQUIRED: ISR images are distributed as
     arch-suffixed tarballs (isr:vX.Y.Z-arm64 / -amd64) and no registry carries
     a bare isr:v<appVersion>, so the chart refuses to render without a tag and
     names the one to set. */}}
{{- define "isr.image" -}}
{{- $tag := required (printf "image.tag is required — set it to the arch-suffixed tag you loaded, e.g. --set image.tag=%s-arm64 (or -amd64)" .Chart.AppVersion) .Values.image.tag -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}

{{/* ServiceAccount name */}}
{{- define "isr.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "isr.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
The one hard rule this chart enforces rather than documents: SQLite is a
single-writer database on a single volume. Two replicas against one state.db
is corruption, not HA.
*/}}
{{- define "isr.validateReplicas" -}}
{{- if gt (int .Values.replicaCount) 1 -}}
{{- if ne .Values.state.backend "postgres" -}}
{{- fail (printf "replicaCount=%d with state.backend=sqlite: SQLite state supports exactly 1 replica. Set state.backend=postgres (with a DSN) to scale the control plane." (int .Values.replicaCount)) -}}
{{- end -}}
{{- if .Values.persistence.enabled -}}
{{- fail "replicaCount > 1 with persistence.enabled: the chart's PVC is ReadWriteOnce and cannot be shared across replicas. Set persistence.enabled=false (the write queue becomes ephemeral) or run one release per replica." -}}
{{- end -}}
{{- end -}}
{{- end -}}
