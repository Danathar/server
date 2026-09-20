"""Unit coverage for the Flatcar container runtime parity generator.

The checked-in matrix is the issue contract for version parity: if the parser
loses a runtime version or a reference sysext loses its content hash, follow-on
substitution work no longer has a stable target.
"""

import importlib.util
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / ".github" / "scripts" / "generate-flatcar-runtime-parity.py"
REFERENCE_ELEMENT = REPO_ROOT / "elements" / "flatcar" / "container-runtime-reference-sysexts.bst"

FLATCAR_MANIFESTS = {
    "flatcar-podman_packages.txt": "app-containers/podman-5.5.2::portage-stable\n",
    "containerd-flatcar_packages.txt": "app-containers/containerd-2.1.5::portage-stable\n",
    "docker-flatcar_packages.txt": "app-containers/docker-28.0.4::portage-stable\n",
}

FSDK_PODMAN = """
sources:
- kind: git_repo
  url: github:podman-container-tools/podman.git
  ref: v6.1.0-0-gcade97a52ebdf9dbf9e81de8009015776837a074
"""


def _load_module():
    spec = importlib.util.spec_from_file_location("flatcar_runtime_parity", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules["flatcar_runtime_parity"] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def generator(tmp_path):
    module = _load_module()
    module.ROOT = tmp_path
    module.FLATCAR_INCLUDE = tmp_path / "include" / "flatcar.yml"
    module.FSDK_JUNCTION = tmp_path / "elements" / "freedesktop-sdk.bst"
    module.FLATCAR_INCLUDE.parent.mkdir(parents=True)
    module.FSDK_JUNCTION.parent.mkdir(parents=True)
    module.FLATCAR_INCLUDE.write_text('variables:\n  flatcar-version: "4593.2.5"\n', encoding="utf-8")
    module.FSDK_JUNCTION.write_text(
        "sources:\n"
        "- kind: git_repo\n"
        "  ref: freedesktop-sdk-26.08.0-0-gdb97cce32cecadc7a3e98f06d557ebfa6ba9ad46\n",
        encoding="utf-8",
    )
    yield module
    sys.modules.pop("flatcar_runtime_parity", None)


def fake_fetch(url):
    for suffix, body in FLATCAR_MANIFESTS.items():
        if url.endswith(suffix):
            return body
    if url.endswith("/podman.bst"):
        return FSDK_PODMAN
    if url.endswith("/containerd.bst") or url.endswith("/docker.bst"):
        return None
    raise AssertionError(f"unexpected URL: {url}")


def test_collect_rows_records_flatcar_and_fsdk_runtime_versions(generator):
    rows = generator.collect_rows(fetch=fake_fetch)

    assert [(row.spec.name, row.flatcar_version, row.fsdk_version) for row in rows] == [
        ("podman", "5.5.2", "6.1.0"),
        ("containerd", "2.1.5", None),
        ("docker", "28.0.4", None),
    ]
    assert generator.gap(rows[0]) == "mismatch: FSDK 6.1.0, Flatcar 5.5.2"
    assert generator.gap(rows[1]) == "missing in FSDK 26.08"


def test_rendered_matrix_records_decisions_and_sources(generator):
    content = generator.render(generator.collect_rows(fetch=fake_fetch))

    assert "match Flatcar in the runtime sysext" in content
    assert "accept divergence: Bluefin Server does not ship Docker" in content
    assert "flatcar-podman_packages.txt" in content
    assert "elements/components/podman.bst" in content
    assert "bc8c6777ab9dee286eb1f70a1605a880fcc5199246d87f9c92f00d880194d72b" in content


def test_reference_element_pins_all_runtime_sysexts():
    text = REFERENCE_ELEMENT.read_text(encoding="utf-8")

    for name, sha256 in {
        "flatcar-podman.raw": "bc8c6777ab9dee286eb1f70a1605a880fcc5199246d87f9c92f00d880194d72b",
        "containerd-flatcar.raw": "78e38344ac490004b9fa4c7da38bbfcffc393146aa990379aff7b5c09589f809",
        "docker-flatcar.raw": "5105dfe9cfb1357fce76e0297c0285e169b1eeb47fa6edd83d5bafe697c72662",
    }.items():
        assert name in text
        assert sha256 in text

    assert "no shipped OS DDI, installer, or k0s sysext target depends" in text
