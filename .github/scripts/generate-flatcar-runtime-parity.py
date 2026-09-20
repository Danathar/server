#!/usr/bin/env python3
"""Generate Flatcar container runtime parity matrix.

The matrix records the runtime versions Flatcar publishes in sysext manifests
and compares them with the freedesktop-sdk junction pinned by this repository.
It intentionally fetches upstream manifests on demand; the generated Markdown is
checked in so normal validation stays offline.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[2]
FLATCAR_INCLUDE = ROOT / "include" / "flatcar.yml"
FSDK_JUNCTION = ROOT / "elements" / "freedesktop-sdk.bst"
OUTPUT = ROOT / "docs" / "superpowers" / "specs" / "2026-09-19-flatcar-runtime-parity.md"

FSDK_RAW_URL = (
    "https://gitlab.com/freedesktop-sdk/freedesktop-sdk/-/raw/"
    "{ref}/elements/components/{element}.bst"
)


@dataclass(frozen=True)
class RuntimeSpec:
    name: str
    flatcar_sysext: str
    flatcar_manifest_path: str
    flatcar_package: str
    fsdk_element: str | None
    reference_raw_path: str
    reference_sha256: str
    decision: str


@dataclass(frozen=True)
class RuntimeRow:
    spec: RuntimeSpec
    flatcar_version: str
    fsdk_version: str | None
    fsdk_ref: str
    flatcar_version_source: str
    fsdk_version_source: str


RUNTIMES = (
    RuntimeSpec(
        name="podman",
        flatcar_sysext="flatcar-podman.raw",
        flatcar_manifest_path="flatcar-podman_packages.txt",
        flatcar_package="app-containers/podman",
        fsdk_element="podman",
        reference_raw_path="flatcar-podman.raw",
        reference_sha256="bc8c6777ab9dee286eb1f70a1605a880fcc5199246d87f9c92f00d880194d72b",
        decision=(
            "match Flatcar in the runtime sysext; do not treat FSDK's "
            "base-OS podman pin as the target"
        ),
    ),
    RuntimeSpec(
        name="containerd",
        flatcar_sysext="containerd-flatcar.raw",
        flatcar_manifest_path="rootfs-included-sysexts/containerd-flatcar_packages.txt",
        flatcar_package="app-containers/containerd",
        fsdk_element="containerd",
        reference_raw_path="rootfs-included-sysexts/containerd-flatcar.raw",
        reference_sha256="78e38344ac490004b9fa4c7da38bbfcffc393146aa990379aff7b5c09589f809",
        decision="match Flatcar through the referenced sysext; no FSDK component exists to retag",
    ),
    RuntimeSpec(
        name="docker",
        flatcar_sysext="docker-flatcar.raw",
        flatcar_manifest_path="rootfs-included-sysexts/docker-flatcar_packages.txt",
        flatcar_package="app-containers/docker",
        fsdk_element="docker",
        reference_raw_path="rootfs-included-sysexts/docker-flatcar.raw",
        reference_sha256="5105dfe9cfb1357fce76e0297c0285e169b1eeb47fa6edd83d5bafe697c72662",
        decision=(
            "accept divergence: Bluefin Server does not ship Docker; keep "
            "the Flatcar sysext only as a boot-comparison reference"
        ),
    ),
)


class FetchError(RuntimeError):
    pass


def read(path: Path) -> str:
    if not path.is_file():
        sys.exit(f"ERROR: expected file not found: {path.relative_to(ROOT)}")
    return path.read_text(encoding="utf-8")


def scalar(text: str, name: str, where: str) -> str:
    match = re.search(rf"^\s*{re.escape(name)}:\s*[\"']([^\"']+)[\"']\s*$", text, re.MULTILINE)
    if not match:
        sys.exit(f"ERROR: {where} does not declare '{name}:'.")
    return match.group(1)


def fsdk_ref() -> str:
    match = re.search(r"^\s*ref:\s*(\S+)\s*$", read(FSDK_JUNCTION), re.MULTILINE)
    if not match:
        sys.exit("ERROR: elements/freedesktop-sdk.bst does not declare a pinned ref.")
    return match.group(1)


def flatcar_version() -> str:
    return scalar(read(FLATCAR_INCLUDE), "flatcar-version", "include/flatcar.yml")


def fetch_text(url: str) -> str | None:
    request = Request(url, headers={"User-Agent": "projectbluefin-server-runtime-parity/1"})
    try:
        with urlopen(request, timeout=30) as response:
            return response.read().decode("utf-8")
    except HTTPError as exc:
        if exc.code == 404:
            return None
        raise FetchError(f"{url}: HTTP {exc.code}") from exc
    except URLError as exc:
        raise FetchError(f"{url}: {exc.reason}") from exc


def flatcar_manifest_url(version: str, spec: RuntimeSpec) -> str:
    return f"https://flatcar.cdn.cncf.io/stable/amd64-usr/{version}/{spec.flatcar_manifest_path}"


def flatcar_raw_url(version: str, spec: RuntimeSpec) -> str:
    return f"https://flatcar.cdn.cncf.io/stable/amd64-usr/{version}/{spec.reference_raw_path}"


def parse_flatcar_package_version(manifest: str, package: str) -> str:
    pattern = re.compile(rf"^{re.escape(package)}-(?P<version>.+?)::", re.MULTILINE)
    match = pattern.search(manifest)
    if not match:
        raise FetchError(f"{package} was not found in Flatcar package manifest")
    return match.group("version")


def parse_fsdk_source_version(element_text: str) -> str:
    match = re.search(r"^\s*ref:\s*v?(?P<version>[0-9][^-\s]*)-", element_text, re.MULTILINE)
    if not match:
        raise FetchError("FSDK component does not expose a versioned source ref")
    return match.group("version")


def collect_rows(fetch=fetch_text) -> list[RuntimeRow]:
    version = flatcar_version()
    pinned_fsdk_ref = fsdk_ref()
    rows: list[RuntimeRow] = []

    for spec in RUNTIMES:
        manifest_url = flatcar_manifest_url(version, spec)
        manifest = fetch(manifest_url)
        if manifest is None:
            raise FetchError(f"Flatcar manifest not found: {manifest_url}")
        flatcar_runtime_version = parse_flatcar_package_version(manifest, spec.flatcar_package)

        fsdk_version_value = None
        fsdk_source = "not packaged by FSDK 26.08"
        if spec.fsdk_element:
            source_url = FSDK_RAW_URL.format(ref=pinned_fsdk_ref, element=spec.fsdk_element)
            source = fetch(source_url)
            fsdk_source = f"freedesktop-sdk {pinned_fsdk_ref}:elements/components/{spec.fsdk_element}.bst"
            if source is not None:
                fsdk_version_value = parse_fsdk_source_version(source)
            else:
                fsdk_source = f"no elements/components/{spec.fsdk_element}.bst in freedesktop-sdk {pinned_fsdk_ref}"

        rows.append(
            RuntimeRow(
                spec=spec,
                flatcar_version=flatcar_runtime_version,
                fsdk_version=fsdk_version_value,
                fsdk_ref=pinned_fsdk_ref,
                flatcar_version_source=manifest_url,
                fsdk_version_source=fsdk_source,
            )
        )

    return rows


def gap(row: RuntimeRow) -> str:
    if row.fsdk_version is None:
        return "missing in FSDK 26.08"
    if row.fsdk_version == row.flatcar_version:
        return "match"
    return f"mismatch: FSDK {row.fsdk_version}, Flatcar {row.flatcar_version}"


def render(rows: list[RuntimeRow]) -> str:
    flatcar = flatcar_version()
    lines = [
        "# Flatcar container runtime parity matrix",
        "",
        "Generated by `.github/scripts/generate-flatcar-runtime-parity.py --write`.",
        "",
        f"Flatcar release: `{flatcar}`. FSDK junction: `{rows[0].fsdk_ref}`.",
        "",
        "| Runtime | Flatcar sysext | Flatcar version | FSDK 26.08 version | Gap | Decision | Sources | Reference raw sha256 |",
        "|---|---|---:|---:|---|---|---|---|",
    ]
    for row in rows:
        fsdk_version_value = row.fsdk_version or "absent"
        sources = (
            f"Flatcar package manifest: `{row.flatcar_version_source}`; "
            f"FSDK source: `{row.fsdk_version_source}`"
        )
        lines.append(
            "| "
            + " | ".join(
                [
                    row.spec.name,
                    f"`{row.spec.flatcar_sysext}`",
                    row.flatcar_version,
                    fsdk_version_value,
                    gap(row),
                    row.spec.decision,
                    sources,
                    f"`{row.spec.reference_sha256}`",
                ]
            )
            + " |"
        )
    lines.extend(
        [
            "",
            "## Reference sysext import",
            "",
            "`elements/flatcar/container-runtime-reference-sysexts.bst` imports the three Flatcar raw sysext images as reference artifacts only. No shipped OS DDI, installer, or k0s sysext target depends on that element.",
            "",
            "Reference raw URLs:",
            "",
        ]
    )
    for row in rows:
        lines.append(f"- `{flatcar_raw_url(flatcar, row.spec)}`")
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help=f"write {OUTPUT.relative_to(ROOT)}")
    parser.add_argument("--check", action="store_true", help="fail if the checked-in matrix is stale")
    args = parser.parse_args()

    try:
        content = render(collect_rows())
    except FetchError as exc:
        sys.exit(f"ERROR: {exc}")

    if args.write:
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        OUTPUT.write_text(content, encoding="utf-8")
        print(f"wrote {OUTPUT.relative_to(ROOT)}")
    elif args.check:
        if read(OUTPUT) != content:
            sys.exit(
                "ERROR: Flatcar runtime parity matrix is stale. "
                "Run .github/scripts/generate-flatcar-runtime-parity.py --write."
            )
        print("OK: Flatcar runtime parity matrix is current.")
    else:
        print(content, end="")


if __name__ == "__main__":
    main()
