#!/bin/sh
# Proposed command only. Execute after coordinator approves this exact script and fingerprints.
set -eu

ccl_fixture_root=$(CDPATH= cd -P -- "$(dirname -- "$0")/../.." && pwd -P)
ccl_run_dir=$(mktemp -d /private/tmp/ccl-manual-refresh-independent-run.XXXXXX)
mkdir "$ccl_run_dir/home" "$ccl_run_dir/tmp" "$ccl_run_dir/module-cache"
cp "$ccl_fixture_root/Sources/QuotaRefresh.swift" "$ccl_run_dir/QuotaRefresh.swift"
cp "$ccl_fixture_root/fixtures/manual-refresh-independent/ManualRefreshIndependent.swift" "$ccl_run_dir/ManualRefreshIndependent.swift"

# C1 (2026-10-18): LimitData.source needs RemoteSource. Self-contained either way: the stub only when the pure source
# does not declare the type itself; anything else QuotaRefresh.swift needs from the app fails the compile loudly.
ccl_stub=""
if ! grep -Eq '^(struct|final class|class|enum) RemoteSource([^A-Za-z0-9_]|$)' "$ccl_run_dir/QuotaRefresh.swift"; then
    cp "$ccl_fixture_root/fixtures/manual-refresh-independent/RemoteSourceStub.swift" "$ccl_run_dir/RemoteSourceStub.swift"
    ccl_stub="$ccl_run_dir/RemoteSourceStub.swift"
fi

# Verify the actual copied inputs, preventing a shared-tree edit from escaping the approved source set.
# Pins: QuotaRefresh.swift of e3a5ac6 (C1, with LimitData.source); a developer edit of that file needs a new approved pin.
printf '%s  %s\n' \
    '3904af40d8a09675a58a75f05f3aface4077a12c89e098c00fd08f0c8c36872e' "$ccl_run_dir/QuotaRefresh.swift" \
    '8aea790e19f539c07cccf2faa6526dbf1fedbfaaf22a040f0f03361bb4566350' "$ccl_run_dir/ManualRefreshIndependent.swift" \
    | /usr/bin/shasum -a 256 -c -
if [ -n "$ccl_stub" ]; then
    printf '%s  %s\n' '1064949e3717a4ac86ea4bc0b022119dcc1d8390b381d6d4a7043131903e0671' "$ccl_stub" | /usr/bin/shasum -a 256 -c -
fi

env HOME="$ccl_run_dir/home" TMPDIR="$ccl_run_dir/tmp/" \
    CLANG_MODULE_CACHE_PATH="$ccl_run_dir/module-cache" \
    /usr/bin/xcrun swiftc -parse-as-library -module-cache-path "$ccl_run_dir/module-cache" \
    "$ccl_run_dir/QuotaRefresh.swift" ${ccl_stub:+"$ccl_stub"} "$ccl_run_dir/ManualRefreshIndependent.swift" \
    -o "$ccl_run_dir/manual-refresh-independent"

env HOME="$ccl_run_dir/home" TMPDIR="$ccl_run_dir/tmp/" \
    "$ccl_run_dir/manual-refresh-independent"

printf 'Artifacts: %s\n' "$ccl_run_dir"
