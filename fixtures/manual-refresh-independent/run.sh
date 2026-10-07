#!/bin/sh
# Proposed command only. Execute after coordinator approves this exact script and fingerprints.
set -eu

ccl_fixture_root=$(CDPATH= cd -P -- "$(dirname -- "$0")/../.." && pwd -P)
ccl_run_dir=$(mktemp -d /private/tmp/ccl-manual-refresh-independent-run.XXXXXX)
mkdir "$ccl_run_dir/home" "$ccl_run_dir/tmp" "$ccl_run_dir/module-cache"
cp "$ccl_fixture_root/Sources/QuotaRefresh.swift" "$ccl_run_dir/QuotaRefresh.swift"
cp "$ccl_fixture_root/fixtures/manual-refresh-independent/ManualRefreshIndependent.swift" "$ccl_run_dir/ManualRefreshIndependent.swift"

# Verify the actual copied inputs, preventing a shared-tree edit from escaping the approved source set.
printf '%s  %s\n' \
    'b118084f80c26a4c86fe24417b3c5dd229ff14f686906b974feeea8af717e41b' "$ccl_run_dir/QuotaRefresh.swift" \
    '8aea790e19f539c07cccf2faa6526dbf1fedbfaaf22a040f0f03361bb4566350' "$ccl_run_dir/ManualRefreshIndependent.swift" \
    | /usr/bin/shasum -a 256 -c -

env HOME="$ccl_run_dir/home" TMPDIR="$ccl_run_dir/tmp/" \
    CLANG_MODULE_CACHE_PATH="$ccl_run_dir/module-cache" \
    /usr/bin/xcrun swiftc -parse-as-library -module-cache-path "$ccl_run_dir/module-cache" \
    "$ccl_run_dir/QuotaRefresh.swift" "$ccl_run_dir/ManualRefreshIndependent.swift" \
    -o "$ccl_run_dir/manual-refresh-independent"

env HOME="$ccl_run_dir/home" TMPDIR="$ccl_run_dir/tmp/" \
    "$ccl_run_dir/manual-refresh-independent"

printf 'Artifacts: %s\n' "$ccl_run_dir"
