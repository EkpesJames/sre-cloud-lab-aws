# ADR-003: Use Loki for log aggregation over Elasticsearch

**Date:** 2026-05
**Status:** Accepted
**Author:** EJ

---

## Context

The observability stack needed a log aggregation system to collect, store, and
query structured JSON logs from all Kubernetes pods. The two main options
considered were Grafana Loki and the Elastic Stack (Elasticsearch + Kibana).

---

## Decision

Use **Grafana Loki** with Promtail as the log shipper.

---

## Reasons

**Resource efficiency.** Elasticsearch requires a minimum of 2GB RAM and
significant CPU for indexing. On a local WSL2 machine already running k3s,
Prometheus, Grafana, Alertmanager, and Jaeger, an Elasticsearch instance would
consume the majority of available resources. Loki is designed to be resource
efficient — it indexes only metadata (labels) not the full log content.

**Native Grafana integration.** Loki is built by Grafana Labs and integrates
natively with Grafana. This means logs, metrics, and traces are all queryable
in a single tool with a consistent UI. Switching between Grafana and Kibana
breaks the observability workflow.

**Operational simplicity.** Loki requires minimal configuration — a single
Helm chart installs both Loki and Promtail. Elasticsearch requires separate
installation of Elasticsearch, Logstash or Filebeat, and Kibana, plus
index lifecycle management, mapping configuration, and shard tuning.

**Label-based querying matches Prometheus model.** Loki uses the same
label model as Prometheus — logs are filtered by labels (namespace, pod, app)
and then searched with a content filter. This is consistent with how the
team already queries metrics, reducing cognitive overhead.

**Cost in production.** In cloud environments, Loki can use object storage
(S3, GCS, Azure Blob) which is significantly cheaper than the block storage
required by Elasticsearch. For a portfolio project demonstrating production
thinking, this is worth noting.

---

## Consequences

**Positive:**
- Minimal resource usage — suitable for local lab
- Single Grafana UI for metrics, logs, and traces
- Simple Helm installation (`grafana/loki-stack`)
- Label model consistent with Prometheus
- Object storage backend for cloud deployment

**Negative:**
- Less powerful full-text search than Elasticsearch
- No built-in anomaly detection (Elasticsearch ML features)
- LogQL query language is less familiar than Elasticsearch's Lucene syntax
- Loki is designed for recent logs — long-term retention requires configuration

---

## Alternatives considered

| Option | Reason rejected |
|---|---|
| Elasticsearch + Kibana | Resource intensive; separate UI from Grafana |
| Splunk | Commercial licensing; resource intensive |
| CloudWatch / Azure Monitor | Cloud-specific; not portable |
| stdout only (no aggregation) | No cross-pod correlation; no persistence |
