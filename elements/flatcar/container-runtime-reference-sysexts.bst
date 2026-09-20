kind: manual
description: |
  Import Flatcar's amd64 container runtime system extensions as reference artifacts.
  These raw sysext images are an oracle for boot comparison and version parity;
  no shipped OS DDI, installer, or k0s sysext target depends on this element.

(@):
  - include/flatcar.yml

build-depends:
  - base/base-stack.bst

variables:
  strip-binaries: ""

sources:
  - kind: remote
    url: flatcar:stable/amd64-usr/%{flatcar-version}/flatcar-podman.raw
    ref: bc8c6777ab9dee286eb1f70a1605a880fcc5199246d87f9c92f00d880194d72b
  - kind: remote
    url: flatcar:stable/amd64-usr/%{flatcar-version}/rootfs-included-sysexts/containerd-flatcar.raw
    ref: 78e38344ac490004b9fa4c7da38bbfcffc393146aa990379aff7b5c09589f809
  - kind: remote
    url: flatcar:stable/amd64-usr/%{flatcar-version}/rootfs-included-sysexts/docker-flatcar.raw
    ref: 5105dfe9cfb1357fce76e0297c0285e169b1eeb47fa6edd83d5bafe697c72662

config:
  install-commands:
    - |
      set -euo pipefail

      out="%{install-root}/usr/lib/flatcar-reference-sysexts"
      mkdir -p "${out}"
      install -D -m 0644 flatcar-podman.raw "${out}/flatcar-podman.raw"
      install -D -m 0644 containerd-flatcar.raw "${out}/containerd-flatcar.raw"
      install -D -m 0644 docker-flatcar.raw "${out}/docker-flatcar.raw"
