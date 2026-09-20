---
name: k0s-sysext-ops
description: Operator runbook for the k0s systemd-sysext extension — provisioning, runtime testing, and troubleshooting.
metadata:
  type: how-to
  status: stable
  last_updated: "2026-09-08"
  context7-sources:
    - /systemd/systemd
---
# k0s systemd-sysext Operations

Use this skill when running, testing, or debugging the k0s systemd-sysext on a live Bluefin Server host.

## Enabling k0s on a Host

On a running Bluefin Server system:

```bash
just k8s
```

Or manually:

```bash
# 1. Fetch the extension image into persistent k0s staging.
systemd-sysupdate --component=k0s update

# 2. Copy it to the ephemeral sysext scan directory and merge into /usr.
install -D -m 0644 /var/lib/k0s/k0s.raw /run/extensions/k0s.raw
systemd-sysext merge

# 3. Seed declarative manifest stacks into /var/lib/k0s/manifests/
systemd-tmpfiles --create /usr/lib/tmpfiles.d/k0s-manifests.conf

# 4. Start the controller service
systemctl enable --now k0scontroller.service
```

## Verifying Manifest Reconciliation

k0s automatically applies all `.yaml` files under `/var/lib/k0s/manifests/argocd/` and `/var/lib/k0s/manifests/kubestellar/`.

```bash
# Verify pods in argocd and kubestellar namespaces
k0s kubectl get pods -A
```

## Troubleshooting

- **Extension not merged**: Check `systemd-sysext status`. Verify the persistent image is `/var/lib/k0s/k0s.raw`; the boot activation unit copies it into `/run/extensions/k0s.raw`.
- **Manifests not applied**: Check `/var/lib/k0s/manifests/`. Ensure files end in `.yaml` (not `.yml`).
- **Service failed**: Check `journalctl -u k0scontroller -e`.
- **`argocd-server` stuck at `0/1` with `connection refused` on `/healthz`**: it is waiting on a dependency, not the probe. Confirm `argocd-redis`, `argocd-repo-server` and `argocd-application-controller` are `Running`, then check `k0s kubectl -n argocd logs deploy/argocd-server` for RBAC `forbidden` errors — the server only binds `:8080` once its configmap/secret and Application informers have synced.
- **An Argo CD component cannot reach redis**: the `argocd-redis` NetworkPolicy allows ingress on `6379` only from pods labelled `app.kubernetes.io/name in (argocd-server, argocd-repo-server, argocd-application-controller)`. redis carries no `requirepass`, so that policy is the only thing keeping the cache private from the KubeStellar and Postgres workloads sharing this node — widen the label set rather than deleting the policy. If `argocd-redis` itself never goes `Ready`, suspect the kubelet `tcpSocket` probe: it dials from the node, not from a pod, and needs the CNI's local-node exemption. Check enforcement with `k0s kubectl -n argocd describe networkpolicy argocd-redis`.

## See also

- [k0s-sysext.md](k0s-sysext.md)
- [CONTEXT.md](../../CONTEXT.md) — canonical project domain glossary (Sysext definition).
- `systemd-sysext(8)`
