#!/usr/bin/env bats
#
# Behavioural contract for the readiness-decision logic inside the
# `test-installer-artifact` recipe (the recipe `show-me-the-future` delegates
# to after `build-installer`/`export-installer`). This is the boot-proof gate
# named in issue #130.
#
# A prior attempt at this issue (#179) was closed because its test sliced
# recipe bodies out of the Justfile as text and asserted substrings — every
# assertion passed whether the underlying health check was correct, weakened,
# or deleted, because it matched echo/log wording rather than the checks
# themselves.
#
# The readiness decision is split across two sides, and this suite covers
# them differently because only one of them is reachable from a test host:
#
#   * Host side (executed for real): the recipe boots the target under QEMU
#     and waits for the in-guest unit's `KIOSK_CONSOLE_READY` marker to
#     appear in the serial log, failing on target death or deadline. The
#     suite runs the real recipe — a private sandbox copy of the Justfile,
#     with `qemu-system-x86_64`, `curl` and `zstd` replaced by logging stubs
#     on PATH, the same pattern as `flash-installer_test.bats` — so
#     `just test-installer-artifact` actually executes and the marker /
#     PID-death / timeout / log-tail behaviour is exercised, not paraphrased.
#
#   * Guest side (guarded as text): since #220 the two-condition check
#     (`/healthz` reporting `status: ok` AND `/` answering HTTP 200) lives in
#     a systemd unit injected over an SMBIOS credential and only ever runs
#     inside the booted guest, against a proxy bound to the guest's
#     loopback. Nothing on the host can execute it, so it is pinned by
#     fixed-string greps of the unit's ExecStart (the `guard:` tests below).
#     Those guards fail if either condition is weakened or dropped.
#
# One substitution is applied to the sandboxed Justfile, and asserted exactly
# like `flash-installer_test.bats` asserts its own: the recipe's OVMF
# firmware lookup only searches hardcoded absolute host paths
# (/usr/share/OVMF/..., linuxbrew Cellar paths, ...), none of which exist on
# an unprivileged CI runner, so the recipe would abort before ever reaching
# the readiness loop. `first_existing` is given one extra, env-controlled
# candidate at the front of its list; left unset it defaults to a path that
# does not exist, so production behaviour is unchanged. QEMU itself never
# reads the firmware content the stub points at, so the file only needs to
# exist.
#
# `os-base: flatcar` (issue #130's acceptance line) does not exist on `main`
# — there is no such build option anywhere in the tree — so this suite proves
# the readiness contract that `show-me-the-future`/`test-installer-artifact`
# already enforce today, independent of which payload eventually boots under
# it. It does not, and cannot yet, close #130.

setup() {
    if ! command -v just >/dev/null 2>&1; then
        skip "just is not installed"
    fi
    if ! command -v jq >/dev/null 2>&1; then
        skip "jq is not installed"
    fi

    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    JUSTFILE="${REPO_ROOT}/Justfile"
    SANDBOX="${BATS_TEST_TMPDIR}/sandbox"
    STUB_DIR="${BATS_TEST_TMPDIR}/bin"
    LOG="${BATS_TEST_TMPDIR}/calls.log"

    mkdir -p "$STUB_DIR" "$SANDBOX/dist" "$SANDBOX/cache" "$SANDBOX/elements"
    : > "$LOG"

    # The recipe reads no repository state other than dist/, but the
    # Justfile's top-level backtick assignments inspect
    # elements/freedesktop-sdk.bst regardless of which recipe runs. Copy it
    # so loading the sandbox Justfile behaves exactly like the real one.
    cp "${REPO_ROOT}/elements/freedesktop-sdk.bst" "${SANDBOX}/elements/"

    # Seed the exported artefacts the recipe copies out of dist/.
    : > "${SANDBOX}/dist/bluefin-server-installer-1.0.raw.zst"
    : > "${SANDBOX}/dist/bluefin-server-pxe-vmlinuz-1.0"
    : > "${SANDBOX}/dist/bluefin-server-pxe-initrd-1.0.cpio.gz"

    # A stand-in OVMF firmware file. QEMU is stubbed and never reads it; it
    # only has to exist so the recipe's firmware lookup succeeds.
    OVMF_STUB="${SANDBOX}/OVMF_CODE_stub.fd"
    truncate -s 1024 "$OVMF_STUB"

    apply_ovmf_override_substitution

    make_zstd_stub
    make_qemu_stub
    make_curl_stub
}

# The OVMF_CODE lookup (`Justfile:254`, duplicated verbatim at the same
# recipe boundary in `install-vm`) only searches hardcoded absolute paths
# that do not exist on an unprivileged CI runner. Insert one extra,
# env-gated candidate at the front of the `first_existing` call so the
# sandbox can point it at a stub file; asserted below so a future edit to
# that line is caught instead of silently un-sandboxing the suite.
apply_ovmf_override_substitution() {
    python3 - "$JUSTFILE" "${SANDBOX}/Justfile" <<'PY'
import sys

src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()

old = '    OVMF_CODE=$(first_existing \\\n'
new = '    OVMF_CODE=$(first_existing "${OVMF_CODE_TEST_OVERRIDE:-/nonexistent-ovmf-code}" \\\n'
count = text.count(old)
assert count == 2, f"expected exactly 2 occurrences of the OVMF_CODE lookup, found {count}"

open(dst, "w", encoding="utf-8").write(text.replace(old, new))
PY
}

@test "sandbox substitution: the OVMF_CODE lookup is patched exactly where expected" {
    run grep -cF 'OVMF_CODE=$(first_existing "${OVMF_CODE_TEST_OVERRIDE:-' "${SANDBOX}/Justfile"
    [ "$status" -eq 0 ]
    [ "$output" -eq 2 ]
}

# make_zstd_stub
#
# Records the invocation and materialises the `-o <file>` target so the
# recipe's subsequent `truncate`/`cp`/qemu-stub steps find the file they
# expect, without actually decompressing anything.
make_zstd_stub() {
    cat > "${STUB_DIR}/zstd" <<EOF
#!/usr/bin/env bash
echo "zstd \$*" >> "${LOG}"
args=("\$@")
for ((i = 0; i < \${#args[@]}; i++)); do
    if [ "\${args[\$i]}" = "-o" ]; then
        : > "\${args[\$((i + 1))]}"
    fi
done
exit 0
EOF
    chmod +x "${STUB_DIR}/zstd"
}

# make_qemu_stub
#
# The recipe invokes qemu-system-x86_64 twice: once in the foreground to run
# the installer to completion (`-serial mon:stdio`), once backgrounded to
# boot the installed target (`-serial file:<path>`). The stub tells the two
# apart by the `-serial` value. The foreground call exits immediately
# (installer "completed"). The backgrounded call either dies immediately
# (QEMU_TARGET_DIES=1, simulating a boot crash) or stays alive, handling
# SIGTERM cleanly, until the recipe's own cleanup trap kills it — exactly
# what `kill -0 "$TARGET_QEMU_PID"` in the polling loop needs to observe.
make_qemu_stub() {
    cat > "${STUB_DIR}/qemu-system-x86_64" <<EOF
#!/usr/bin/env bash
echo "qemu-system-x86_64 \$*" >> "${LOG}"

serial_arg=""
prev=""
for a in "\$@"; do
    if [ "\$prev" = "-serial" ]; then
        serial_arg="\$a"
    fi
    prev="\$a"
done

case "\$serial_arg" in
    file:*)
        serial_file="\${serial_arg#file:}"
        : > "\$serial_file"
        if [ -n "\${QEMU_SERIAL_LOG_CONTENT:-}" ]; then
            printf '%s\n' "\${QEMU_SERIAL_LOG_CONTENT}" >> "\$serial_file"
        fi
        if [ "\${QEMU_TARGET_DIES:-0}" = "1" ]; then
            exit 1
        fi
        trap 'exit 0' TERM INT
        while true; do sleep 1; done
        ;;
    *)
        exit "\${QEMU_INSTALL_EXIT:-0}"
        ;;
esac
EOF
    chmod +x "${STUB_DIR}/qemu-system-x86_64"
}

# make_curl_stub
#
# The readiness probe runs inside the guest, so the host should never invoke
# curl at all. This stub exists only to record any invocation in the call
# log, so `refute_host_probe_attempted` can prove that. It shapes no
# response: if the host ever did probe, the stub fails the call loudly
# rather than pretending to be a reachable kiosk proxy.
make_curl_stub() {
    cat > "${STUB_DIR}/curl" <<EOF
#!/usr/bin/env bash
echo "curl \$*" >> "${LOG}"
echo "curl stub: the host is not expected to probe the kiosk" >&2
exit 1
EOF
    chmod +x "${STUB_DIR}/curl"
}

# run_test_installer_artifact [deadline-seconds]
#
# The QEMU_*/OVMF_CODE_TEST_OVERRIDE knobs are read from the calling test's
# exported environment; only the deadline is parameterised here since every
# test needs one.
run_test_installer_artifact() {
    local deadline="${1:-5}"
    run env PATH="${STUB_DIR}:${PATH}" \
        XDG_CACHE_HOME="${SANDBOX}/cache" \
        OVMF_CODE_TEST_OVERRIDE="${OVMF_STUB}" \
        SHOW_ME_THE_FUTURE_DEADLINE="${deadline}" \
        QEMU_TARGET_DIES="${QEMU_TARGET_DIES:-0}" \
        QEMU_SERIAL_LOG_CONTENT="${QEMU_SERIAL_LOG_CONTENT:-}" \
        just --justfile "${SANDBOX}/Justfile" \
             --working-directory "${SANDBOX}" \
             test-installer-artifact
}

assert_log() {
    if ! grep -qF -- "$1" "$LOG"; then
        echo "expected call log to contain: $1" >&2
        cat "$LOG" >&2
        return 1
    fi
}

refute_log() {
    if grep -qF -- "$1" "$LOG"; then
        echo "expected call log NOT to contain: $1" >&2
        cat "$LOG" >&2
        return 1
    fi
}

# The readiness probe lives in the guest, so no host-side curl invocation is
# legitimate: any entry in the call log at all is a failure.
refute_host_probe_attempted() {
    if grep -qF 'curl ' "$LOG"; then
        echo "expected the host NOT to have run curl at all (the probe lives in the guest)" >&2
        cat "$LOG" >&2
        return 1
    fi
}

# --- guards: the checks this suite depends on are still the real ones -----

@test "guard: the in-guest probe still requires the healthz body to report status ok" {
    # The readiness decision moved into the guest with #220: a systemd unit
    # injected over an SMBIOS credential polls the kiosk proxy from inside
    # and prints KIOSK_CONSOLE_READY on the console. The two conditions are
    # now text inside that unit's ExecStart, so they are guarded as text.
    run grep -cF "curl --silent --fail --insecure --max-time 2 https://127.0.0.1:8080/healthz | jq -r .status)\" = ok ]" "$JUSTFILE"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
}

@test "guard: the in-guest probe still requires the root probe to answer exactly 200" {
    run grep -cF '"%%{http_code}" https://127.0.0.1:8080/)" = 200 ]' "$JUSTFILE"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
}

@test "guard: the unit is delivered as an SMBIOS credential and pulled in by the cmdline" {
    # Scoped to this recipe's body, like the host-probe guard below: install-vm
    # also carries this credential/cmdline pair (it reuses the same in-guest
    # kiosk-ready mechanism), so a whole-file grep would count both recipes'
    # copies instead of just this one's.
    run bash -c 'recipe_body() { awk "/^test-installer-artifact:/{p=1;next} p&&/^[a-z][a-z0-9-]*:/{exit} p" "$1"; }; recipe_body "$1" | grep -cF "io.systemd.credential.binary:systemd.extra-unit.bluefin-kiosk-ready.service="' _ "$JUSTFILE"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
    run bash -c 'recipe_body() { awk "/^test-installer-artifact:/{p=1;next} p&&/^[a-z][a-z0-9-]*:/{exit} p" "$1"; }; recipe_body "$1" | grep -cF "systemd.wants=bluefin-kiosk-ready.service"' _ "$JUSTFILE"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
}

@test "guard: this recipe never probes the kiosk from the host" {
    # The proxy is bound to the guest's loopback, which a QEMU hostfwd cannot
    # reach, so a host-side probe would be a probe of nothing. The only host
    # decision is the serial-log marker. Scoped to this recipe's body:
    # install-vm is a different recipe and forwards its own ports.
    recipe_body() {
        awk '/^test-installer-artifact:/{p=1;next} p&&/^[a-z][a-z0-9-]*:/{exit} p' "$JUSTFILE"
    }
    # http, not https: the in-guest probe speaks https to the TLS-terminating
    # proxy, so a plaintext probe here could only be a host-side one.
    run bash -c 'recipe_body() { awk "/^test-installer-artifact:/{p=1;next} p&&/^[a-z][a-z0-9-]*:/{exit} p" "$1"; }; recipe_body "$1" | grep -cE "curl [^|]*http://127\.0\.0\.1:8080"' _ "$JUSTFILE"
    [ "$output" -eq 0 ]
    run bash -c 'recipe_body() { awk "/^test-installer-artifact:/{p=1;next} p&&/^[a-z][a-z0-9-]*:/{exit} p" "$1"; }; recipe_body "$1" | grep -cF "hostfwd=tcp:127.0.0.1:8080-:8080"' _ "$JUSTFILE"
    [ "$output" -eq 0 ]
}

# --- the readiness decision -------------------------------------------------
#
# From the host's side the decision is: the marker the in-guest unit prints
# appears in the serial log. The QEMU stub writes whatever
# QEMU_SERIAL_LOG_CONTENT holds into the serial file, standing in for the
# guest console, so each case below seeds the log with what a guest in that
# state would have printed.

@test "declares readiness once the in-guest probe prints the marker on the console" {
    export QEMU_SERIAL_LOG_CONTENT="<4>kiosk-ready: polling https://127.0.0.1:8080
<4>KIOSK_CONSOLE_READY"
    run_test_installer_artifact 10
    [ "$status" -eq 0 ]
    [[ "$output" == *"KubeStellar Console is healthy: /healthz status ok, / returned HTTP 200"* ]]
    refute_host_probe_attempted
}

@test "does not declare readiness while the in-guest probe is still waiting" {
    # The unit prints a progress line every 15 polls while either condition
    # is unmet; that line must never be mistaken for the marker.
    export QEMU_SERIAL_LOG_CONTENT="<4>kiosk-ready: polling https://127.0.0.1:8080
<4>kiosk-ready: waiting k0s=active hz=200 root=503 pods=12 running=9"
    run_test_installer_artifact 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"Timed out after 1s waiting for KubeStellar Console readiness"* ]]
    [[ "$output" != *"KubeStellar Console is healthy"* ]]
}

@test "does not declare readiness when the guest never prints the marker at all" {
    export QEMU_SERIAL_LOG_CONTENT="kernel: still booting, never became ready"
    run_test_installer_artifact 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"Timed out after 1s waiting for KubeStellar Console readiness"* ]]
    [[ "$output" != *"KubeStellar Console is healthy"* ]]
}

@test "does not declare readiness on a near-miss of the marker" {
    # The host greps the serial log for the marker as an unanchored fixed
    # string, so any line *containing* KIOSK_CONSOLE_READY declares
    # readiness — that is the contract, not exact-line matching. What this
    # case pins is the other direction: console text that merely approaches
    # the marker without containing it (here, a truncated spelling) must not
    # trip the gate.
    export QEMU_SERIAL_LOG_CONTENT="<4>kiosk-ready: waiting for KIOSK_CONSOLE_READ"
    run_test_installer_artifact 1
    [ "$status" -ne 0 ]
    [[ "$output" != *"KubeStellar Console is healthy"* ]]
}

@test "exits nonzero and reports the failure once the target QEMU process dies" {
    export QEMU_TARGET_DIES="1"
    run_test_installer_artifact 30
    [ "$status" -ne 0 ]
    [[ "$output" == *"died unexpectedly"* ]]
    [[ "$output" != *"KubeStellar Console is healthy"* ]]
}

@test "dumps the serial log tail when the target QEMU process dies" {
    export QEMU_TARGET_DIES="1"
    export QEMU_SERIAL_LOG_CONTENT="kernel: this is the last thing the guest printed"
    run_test_installer_artifact 30
    [ "$status" -ne 0 ]
    [[ "$output" == *"Serial log tail"* ]]
    [[ "$output" == *"this is the last thing the guest printed"* ]]
}

@test "dumps the serial log tail when readiness times out instead of the target dying" {
    export QEMU_SERIAL_LOG_CONTENT="kernel: still booting, never became ready"
    run_test_installer_artifact 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"Serial log tail"* ]]
    [[ "$output" == *"still booting, never became ready"* ]]
    [[ "$output" != *"died unexpectedly"* ]]
}
