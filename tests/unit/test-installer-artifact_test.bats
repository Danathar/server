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
# themselves. This suite instead runs the real recipe: a private sandbox copy
# of the Justfile, with `qemu-system-x86_64`, `curl` and `zstd` replaced by
# logging stubs on PATH so `just test-installer-artifact` executes for real
# and the decision logic (readiness requires BOTH a `{"status":"ok"}`
# `/healthz` body AND an HTTP 200 on `/`, exactly `flash-installer_test.bats`'
# behavioural style) is exercised rather than paraphrased.
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
# Answers the two probes the readiness loop makes, driven entirely by env
# vars set per test: CURL_HEALTHZ_EXIT/CURL_HEALTHZ_BODY for `/healthz`,
# CURL_ROOT_EXIT/CURL_ROOT_CODE for `/`. Real `jq` (not stubbed) parses
# whatever body this stub prints, so the suite exercises the actual
# `jq -e '.status == "ok"'` check rather than a paraphrase of it.
make_curl_stub() {
    cat > "${STUB_DIR}/curl" <<EOF
#!/usr/bin/env bash
echo "curl \$*" >> "${LOG}"

url=""
for a in "\$@"; do url="\$a"; done

case "\$url" in
    */healthz)
        [ "\${CURL_HEALTHZ_EXIT:-0}" = "0" ] || exit "\${CURL_HEALTHZ_EXIT}"
        printf '%s' "\${CURL_HEALTHZ_BODY:-}"
        exit 0
        ;;
    *)
        [ "\${CURL_ROOT_EXIT:-0}" = "0" ] || exit "\${CURL_ROOT_EXIT}"
        printf '%s' "\${CURL_ROOT_CODE:-000}"
        exit 0
        ;;
esac
EOF
    chmod +x "${STUB_DIR}/curl"
}

# run_test_installer_artifact [deadline-seconds]
#
# All CURL_*/QEMU_*/OVMF_CODE_TEST_OVERRIDE knobs are read from the calling
# test's exported environment; only the deadline is parameterised here since
# every test needs one.
run_test_installer_artifact() {
    local deadline="${1:-5}"
    run env PATH="${STUB_DIR}:${PATH}" \
        XDG_CACHE_HOME="${SANDBOX}/cache" \
        OVMF_CODE_TEST_OVERRIDE="${OVMF_STUB}" \
        SHOW_ME_THE_FUTURE_DEADLINE="${deadline}" \
        CURL_HEALTHZ_EXIT="${CURL_HEALTHZ_EXIT:-0}" \
        CURL_HEALTHZ_BODY="${CURL_HEALTHZ_BODY:-}" \
        CURL_ROOT_EXIT="${CURL_ROOT_EXIT:-0}" \
        CURL_ROOT_CODE="${CURL_ROOT_CODE:-}" \
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

# The root probe's URL has no path suffix; matching end-of-line distinguishes
# a real call to it from a call to /healthz (which also contains "8080/").
assert_root_probe_attempted() {
    if ! grep -qE 'curl .* http://127\.0\.0\.1:8080/$' "$LOG"; then
        echo "expected the root probe (http://127.0.0.1:8080/) to have been called" >&2
        cat "$LOG" >&2
        return 1
    fi
}

refute_root_probe_attempted() {
    if grep -qE 'curl .* http://127\.0\.0\.1:8080/$' "$LOG"; then
        echo "expected the root probe (http://127.0.0.1:8080/) NOT to have been called" >&2
        cat "$LOG" >&2
        return 1
    fi
}

# --- guards: the checks this suite depends on are still the real ones -----

@test "guard: readiness still requires the healthz body to report status ok" {
    run grep -cF 'jq -e '"'"'.status == "ok"'"'"'' "$JUSTFILE"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
}

@test "guard: readiness still requires the root probe to answer exactly 200" {
    run grep -cF '[ "$ROOT_CODE" = "200" ]' "$JUSTFILE"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
}

# --- the readiness decision -------------------------------------------------

@test "declares readiness only once healthz reports ok status and root answers 200" {
    export CURL_HEALTHZ_BODY='{"status":"ok"}'
    export CURL_ROOT_CODE="200"
    run_test_installer_artifact 10
    [ "$status" -eq 0 ]
    [[ "$output" == *"KubeStellar Console is healthy: /healthz status ok, / returned HTTP 200"* ]]
    assert_root_probe_attempted
}

@test "does not declare readiness when healthz is ok but the root probe never returns 200" {
    export CURL_HEALTHZ_BODY='{"status":"ok"}'
    export CURL_ROOT_CODE="503"
    run_test_installer_artifact 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"Timed out after 1s waiting for KubeStellar Console readiness"* ]]
    [[ "$output" != *"KubeStellar Console is healthy"* ]]
    # The root probe having been reached proves the failure is the "never
    # 200" branch, not an accidental short-circuit before it.
    assert_root_probe_attempted
}

@test "does not declare readiness when root answers 200 but healthz never reports ok" {
    export CURL_HEALTHZ_BODY='{"status":"degraded"}'
    export CURL_ROOT_CODE="200"
    run_test_installer_artifact 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"Timed out after 1s waiting for KubeStellar Console readiness"* ]]
    [[ "$output" != *"KubeStellar Console is healthy"* ]]
    # healthz status must gate the root probe: a failing/absent status must
    # never let the loop even ask the root probe.
    refute_root_probe_attempted
}

@test "does not declare readiness when the healthz probe cannot connect at all" {
    export CURL_HEALTHZ_EXIT="7"
    export CURL_ROOT_CODE="200"
    run_test_installer_artifact 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"Timed out after 1s waiting for KubeStellar Console readiness"* ]]
    refute_root_probe_attempted
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
    export CURL_HEALTHZ_EXIT="7"
    export QEMU_SERIAL_LOG_CONTENT="kernel: still booting, never became ready"
    run_test_installer_artifact 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"Serial log tail"* ]]
    [[ "$output" == *"still booting, never became ready"* ]]
    [[ "$output" != *"died unexpectedly"* ]]
}
