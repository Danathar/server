from pathlib import Path

import os
import subprocess

import yaml

ROOT = Path(__file__).resolve().parents[2]
ARGOCD_INSTALL = ROOT / "files" / "k0s" / "manifests" / "argocd" / "install.yaml"


def argocd_docs():
    return [d for d in yaml.safe_load_all(ARGOCD_INSTALL.read_text()) if d]


def test_k0s_service_unit():
    unit = ROOT / "files" / "k0s" / "sysext" / "k0scontroller.service"
    assert unit.is_file(), "k0scontroller.service missing"
    text = unit.read_text()
    assert "--disable-components=helm,autopilot" in text
    assert "--enable-worker" in text
    assert "--single" in text


def test_k0s_manifests_conf():
    conf = ROOT / "files" / "k0s" / "sysext" / "k0s-manifests.conf"
    assert conf.is_file(), "k0s-manifests.conf missing"
    text = conf.read_text()
    assert "d /var/lib/k0s/manifests 0755 root root - -" in text
    assert "C+ /var/lib/k0s/manifests/argocd - - - - /usr/share/k0s/manifests/argocd" in text
    assert "C+ /var/lib/k0s/manifests/kubestellar - - - - /usr/share/k0s/manifests/kubestellar" in text


def test_k0s_manifest_files():
    argo_yaml = ROOT / "files" / "k0s" / "manifests" / "argocd" / "install.yaml"
    assert argo_yaml.is_file(), "argocd install.yaml missing"
    assert "namespace: argocd" in argo_yaml.read_text()

    ks_dir = ROOT / "files" / "k0s" / "manifests" / "kubestellar"
    assert (ks_dir / "00-kubeflex-crds.yaml").is_file()
    assert (ks_dir / "10-kubeflex-operator.yaml").is_file()
    assert (ks_dir / "20-postgres.yaml").is_file()
    assert (ks_dir / "30-kubestellar-core.yaml").is_file()
    assert (ks_dir / "40-kubestellar-console.yaml").is_file()
    assert (ks_dir / "41-kubestellar-kiosk-proxy.yaml").is_file()


def test_argocd_stack_is_complete():
    # #177: argocd-server never binds :8080 — and so never passes its readiness
    # probe — unless redis, the repo server, the application controller and the
    # CRDs it watches are all part of the stack.
    docs = argocd_docs()
    workloads = {(d["kind"], d["metadata"]["name"]) for d in docs}
    for name in (
        "argocd-redis",
        "argocd-repo-server",
        "argocd-server",
    ):
        assert ("Deployment", name) in workloads, f"{name} Deployment missing"
        assert ("Service", name) in workloads, f"{name} Service missing"
    assert ("StatefulSet", "argocd-application-controller") in workloads

    crds = {d["metadata"]["name"] for d in docs if d["kind"] == "CustomResourceDefinition"}
    assert crds == {
        "applications.argoproj.io",
        "appprojects.argoproj.io",
        "applicationsets.argoproj.io",
    }


def test_argocd_rbac_is_bound():
    # Without namespace RBAC the server's configmap/secret and Application
    # informers never sync, which is the state issue #177 reported.
    docs = argocd_docs()
    accounts = {d["metadata"]["name"] for d in docs if d["kind"] == "ServiceAccount"}
    assert accounts == {
        "argocd-server",
        "argocd-application-controller",
        "argocd-repo-server",
        "argocd-redis",
    }

    for kind, binding_kind in (("Role", "RoleBinding"), ("ClusterRole", "ClusterRoleBinding")):
        roles = {d["metadata"]["name"] for d in docs if d["kind"] == kind}
        assert {"argocd-server", "argocd-application-controller"} <= roles, f"{kind} missing"
        for binding in (d for d in docs if d["kind"] == binding_kind):
            assert binding["roleRef"]["kind"] == kind
            assert binding["roleRef"]["name"] in roles, "binding references an unknown role"
            for subject in binding["subjects"]:
                assert subject["name"] in accounts, "binding references an unknown ServiceAccount"


def test_argocd_workloads_are_wired_together():
    docs = argocd_docs()
    pod_specs = {
        d["metadata"]["name"]: d["spec"]["template"]["spec"]
        for d in docs
        if d["kind"] in ("Deployment", "StatefulSet")
    }
    services = {d["metadata"]["name"]: d["spec"] for d in docs if d["kind"] == "Service"}
    config_maps = {d["metadata"]["name"] for d in docs if d["kind"] == "ConfigMap"}

    for name, spec in pod_specs.items():
        assert spec["serviceAccountName"] == name, f"{name} runs under the wrong ServiceAccount"
        declared = {v["name"] for v in spec.get("volumes", [])}
        for container in spec["containers"]:
            for mount in container.get("volumeMounts", []):
                assert mount["name"] in declared, f"{name} mounts undeclared volume {mount['name']}"
        for volume in spec.get("volumes", []):
            if "configMap" in volume:
                assert volume["configMap"]["name"] in config_maps, f"{name} mounts a missing ConfigMap"

    # Clients address redis and the repo server through the shipped Services.
    for name in ("argocd-server", "argocd-application-controller", "argocd-repo-server"):
        command = " ".join(pod_specs[name]["containers"][0]["command"])
        assert "argocd-redis:6379" in command, f"{name} does not point at the redis Service"
    assert services["argocd-redis"]["ports"][0]["port"] == 6379
    assert services["argocd-repo-server"]["ports"][0]["port"] == 8081


def test_argocd_redis_ingress_is_restricted_to_its_clients():
    # redis carries no requirepass, and the application controller that reads
    # the cache holds */*/* cluster-admin, so ClusterIP on a single node is not
    # a boundary: every other workload on the node can dial it. The policy is
    # derived from, and must stay equal to, the set of pods that actually talk
    # to redis -- so adding a fourth client fails here rather than at runtime.
    docs = argocd_docs()
    pod_specs = {
        d["metadata"]["name"]: d["spec"]["template"]
        for d in docs
        if d["kind"] in ("Deployment", "StatefulSet")
    }
    clients = {
        template["metadata"]["labels"]["app.kubernetes.io/name"]
        for name, template in pod_specs.items()
        if "argocd-redis:6379" in " ".join(template["spec"]["containers"][0]["command"])
    }
    assert clients == {
        "argocd-server",
        "argocd-application-controller",
        "argocd-repo-server",
    }

    policy = next(d for d in docs if d["kind"] == "NetworkPolicy")
    assert policy["metadata"]["namespace"] == "argocd"
    assert policy["spec"]["policyTypes"] == ["Ingress"]

    # It must select the redis pod itself, by the label its Deployment uses.
    redis_labels = pod_specs["argocd-redis"]["metadata"]["labels"]
    assert policy["spec"]["podSelector"]["matchLabels"].items() <= redis_labels.items()

    (rule,) = policy["spec"]["ingress"]
    (selector,) = rule["from"]
    assert "namespaceSelector" not in selector, "ingress must not be opened to other namespaces"
    (expression,) = selector["podSelector"]["matchExpressions"]
    assert expression["key"] == "app.kubernetes.io/name"
    assert expression["operator"] == "In"
    assert set(expression["values"]) == clients
    assert rule["ports"] == [{"protocol": "TCP", "port": 6379}]


def test_argocd_secret_is_seeded_empty():
    # argocd-server writes server.secretkey into this Secret on first start; it
    # must exist but must never carry a committed credential.
    secret = next(d for d in argocd_docs() if d["kind"] == "Secret")
    assert secret["metadata"]["name"] == "argocd-secret"
    assert not secret.get("data") and not secret.get("stringData")


def test_postgres_password_not_hardcoded():
    # #98: the postgres superuser password must not be committed to git in
    # plaintext, and must not be the publicly documented kubeflex default.
    manifest = ROOT / "files" / "k0s" / "manifests" / "kubestellar" / "20-postgres.yaml"
    text = manifest.read_text()
    assert "kubeflex" not in text.lower().replace("kubeflex-system", "").replace("kubeflex-postgres", "")
    assert 'value: "kubeflex"' not in text
    assert "POSTGRESQL_PASSWORD" in text


def test_postgres_password_from_secret():
    # The StatefulSet reads the password from a Secret, not a plaintext env.
    docs = list(yaml.safe_load_all((ROOT / "files" / "k0s" / "manifests" / "kubestellar" / "20-postgres.yaml").read_text()))
    statefulset = next(d for d in docs if d and d.get("kind") == "StatefulSet")
    container = statefulset["spec"]["template"]["spec"]["containers"][0]
    env = {e["name"]: e for e in container["env"]}
    assert "value" not in env["POSTGRESQL_PASSWORD"]
    ref = env["POSTGRESQL_PASSWORD"]["valueFrom"]["secretKeyRef"]
    assert ref == {"name": "kubeflex-postgres", "key": "password"}


def test_k0s_first_boot_generates_postgres_secret_before_k0s():
    # The Secret must be staged before k0s applies the manifests, and the
    # generated 15- file must sort before 20-postgres.yaml.
    unit = ROOT / "files" / "os" / "systemd" / "system" / "k0s-first-boot.service"
    text = unit.read_text()
    lines = [l for l in text.splitlines() if l.startswith("ExecStart")]
    gen = next((i for i, l in enumerate(lines) if "generate-postgres-secret.sh" in l), None)
    k0s = next((i for i, l in enumerate(lines) if "k0scontroller.service" in l), None)
    assert gen is not None, "first-boot service never runs the postgres secret generator"
    assert k0s is not None, "first-boot service never starts k0scontroller"
    assert gen < k0s, "postgres secret generator must run before k0s applies manifests"


def test_generate_postgres_secret_is_idempotent(tmp_path):
    # Running the generator twice must not change an already-created password,
    # so the initialized database stays accessible across re-boots.
    script = ROOT / "files" / "k0s" / "kubeflex" / "generate-postgres-secret.sh"
    env = dict(os.environ, KUBEFLEX_MANIFEST_DIR=str(tmp_path))
    run = lambda: subprocess.run(["/bin/bash", str(script)], env=env, check=True, capture_output=True, text=True)
    run()
    secret_file = tmp_path / "15-kubeflex-postgres-secret.yaml"
    assert secret_file.is_file()
    secret = yaml.safe_load(secret_file.read_text())
    assert secret["kind"] == "Secret"
    assert secret["metadata"]["name"] == "kubeflex-postgres"
    assert secret["stringData"]["password"]
    first = secret_file.read_text()
    run()
    assert secret_file.read_text() == first, "password changed on re-run; DB would lose access"
