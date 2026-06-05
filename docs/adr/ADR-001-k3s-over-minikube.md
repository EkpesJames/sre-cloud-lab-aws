# ADR-001: Use k3s as the local Kubernetes distribution

**Date:** 2026-05
**Status:** Accepted
**Author:** EJ

---

## Context

The project needed a local Kubernetes cluster to run on WSL2 (Windows Subsystem
for Linux) without requiring a cloud account. Several options were available:

- **minikube** — the most commonly used local K8s tool
- **kind** (Kubernetes in Docker) — runs cluster nodes as Docker containers
- **k3s** — lightweight Kubernetes designed for edge and IoT
- **k0s** — another lightweight distribution
- **Docker Desktop Kubernetes** — built into Docker Desktop

The choice needed to support: Helm, Prometheus Operator CRDs, Chaos Mesh,
persistent volumes, and a self-hosted GitHub Actions runner — all on WSL2.

---

## Decision

Use **k3s** as the local Kubernetes distribution.

---

## Reasons

**WSL2 compatibility.** k3s installs with a single curl command and runs as
a systemd service on WSL2 without requiring additional configuration. minikube
requires a VM driver (VirtualBox, Hyper-V) which conflicts with WSL2's own
Hyper-V usage.

**Lightweight footprint.** k3s uses approximately 512MB RAM at idle compared
to minikube's 2–4GB. On a development machine also running Docker, Prometheus,
Grafana, Loki, and Jaeger, resource efficiency matters.

**Production-like architecture.** k3s uses containerd (not Docker) as its
container runtime — the same runtime used by most production Kubernetes clusters
(GKE, EKS, AKS). This means skills learned on k3s transfer directly to
production environments.

**Built-in components.** k3s includes Traefik as an ingress controller and
a local-path provisioner for persistent volumes out of the box — both needed
for the observability stack.

**Self-hosted runner support.** The GitHub Actions self-hosted runner runs
directly on WSL2 and uses the same kubeconfig as the developer — no additional
networking configuration needed.

---

## Consequences

**Positive:**
- Single-command install (`curl -sfL https://get.k3s.io | sh -`)
- Minimal resource usage
- containerd runtime mirrors production
- Built-in Traefik ingress and local-path storage

**Negative:**
- k3s disables some Kubernetes components by default (kube-scheduler metrics,
  etcd metrics, controller-manager metrics) — addressed by disabling those
  scrape targets in the Prometheus Helm values
- node-exporter cannot mount host paths on WSL2 — addressed by disabling
  node-exporter in the Helm values
- NodePort services are not directly accessible from Windows — addressed by
  using `kubectl port-forward` for all UI access

---

## Alternatives considered

| Option | Reason rejected |
|---|---|
| minikube | VM driver conflicts with WSL2 Hyper-V |
| kind | Docker-in-Docker complexity; containerd import workflow different |
| Docker Desktop K8s | Not available on WSL2 directly; licensing concerns |
| k0s | Less community support; fewer Helm charts tested against it |
