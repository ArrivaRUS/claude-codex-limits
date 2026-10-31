#!/bin/bash
# Build "Claude Codex Limits.app" into ./dist (no install). Pure system tooling.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Claude Codex Limits"
EXE_NAME="ClaudeCodexLimits"
BUNDLE_ID="com.arrivarus.claudecodexlimits"
VERSION="3.3.1"
DIST_APP="$DIR/dist/$APP_NAME.app"

# Recover an interrupted publication before starting another build. Once the
# destination exists, any remaining backups belong to completed publications.
for old_app in "$DIST_APP".old.*; do
    [ -e "$old_app" ] || [ -L "$old_app" ] || continue
    if [ -e "$DIST_APP" ] || [ -L "$DIST_APP" ]; then
        rm -rf "$old_app"
    elif ! mv "$old_app" "$DIST_APP" 2>/dev/null; then
        echo 'ERROR: recovering previous dist app failed' >&2
        exit 1
    fi
done

echo "==> building $APP_NAME.app"
CCL_BUILD_TMP="${CCL_BUILD_TMP:-$DIR/.build-tmp}"
mkdir -p "$CCL_BUILD_TMP"
BUILD_SOURCE_DIR="$(mktemp -d "$CCL_BUILD_TMP/ccl-swift-build.XXXXXX")"
KEEP_BUILD_SOURCE=0
trap 'if [ "$KEEP_BUILD_SOURCE" = 0 ]; then rm -rf "$BUILD_SOURCE_DIR"; fi' EXIT
# Publish only a successfully signed bundle. A failed strict build cannot erase
# the owner's previously signed dist app, even when compilation itself fails.
APP="$BUILD_SOURCE_DIR/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
CODESIGN_LOG="$BUILD_SOURCE_DIR/codesign.err"
cp "$DIR/Sources/LimitsMonitor.swift" "$BUILD_SOURCE_DIR/main.swift"
# Match Info.plist's macOS 13.0 minimum for the current build architecture.
/usr/bin/swiftc -target "$(uname -m)-apple-macosx13.0" -O "$BUILD_SOURCE_DIR/main.swift" "$DIR/Sources/QuotaRefresh.swift" "$DIR/Sources/GitHubAuth.swift" "$DIR/Sources/GitHubAuthSelfTests.swift" "$DIR/Sources/RemoteLimitsSelfTests.swift" "$DIR/Sources/RemoteLimitsC4SelfTests.swift" "$DIR/Sources/RemoteLimitsC5SelfTests.swift" "$DIR/Sources/RemoteLimitsC4.swift" "$DIR/Sources/RemoteLimitsC2SelfTests.swift" "$DIR/Sources/RemoteLimitsC3SelfTests.swift" "$DIR/Sources/RemoteLimitsC3BSelfTests.swift" "$DIR/Sources/RemoteLimitsC3BPreviews.swift" "$DIR/Sources/RemoteLimitsC3B.swift" "$DIR/Sources/RemoteLimits.swift" -o "$APP/Contents/MacOS/$EXE_NAME"
cp -R "$DIR/Resources/"* "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$EXE_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST

# --- Code signing (persistent clone-local identity; ad-hoc fallback) ---------
# Never trace passwords, including when build.sh was invoked with bash -x.
set +x
SIGNING_REASON="$BUILD_SOURCE_DIR/signing.reason"
SIGNING_ERR="$BUILD_SOURCE_DIR/signing.err"
SIGNING_SEARCH_STATUS="$BUILD_SOURCE_DIR/signing.search-status"
SIGNING_RESTORE_FAILED="$BUILD_SOURCE_DIR/signing.restore-failed"
SIGNING_INTERRUPTED="$BUILD_SOURCE_DIR/signing.interrupted"
: > "$SIGNING_ERR"
printf '%s\n' 'setup failed' > "$SIGNING_REASON"
signing_unavailable() {
    printf '%s\n' "$1" > "$SIGNING_REASON"
    return 1
}
signing_display_path() {
    local text="$1" home_prefix="${HOME:-}"
    # Replace the longer prefix first, including when HOME is inside the clone.
    if [ "${#DIR}" -ge "${#home_prefix}" ]; then
        text="${text//"$DIR"/.}"
        if [ -n "$home_prefix" ]; then text="${text//"$home_prefix"/\~}"; fi
    else
        text="${text//"$home_prefix"/\~}"
        text="${text//"$DIR"/.}"
    fi
    printf '%s\n' "$text"
}
# Keep tool diagnostics, never command lines or passwords. Security normally
# does not echo passwords; redact defensively before writing even the private log.
signing_record_error() {
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        if [ -n "${pass:-}" ]; then line="${line//"$pass"/[REDACTED]}"; fi
        signing_display_path "$line" >> "$SIGNING_ERR"
    done < "$1"
}
signing_command() {
    local result=0
    "$@" 2> "$BUILD_SOURCE_DIR/signing-command.err" || result=$?
    if [ "$result" != 0 ]; then signing_record_error "$BUILD_SOURCE_DIR/signing-command.err"; fi
    rm -f "$BUILD_SOURCE_DIR/signing-command.err"
    return "$result"
}
# security list-keychains emits one double-quoted path per line. Decode it as
# data (including escaped quotes/backslashes), never eval user-controlled paths.
# These arrays are scoped to stable_sign_app; the functions are also mockable.
signing_snapshot_search_list() {
    local line encoded path char escaped index
    signing_command /usr/bin/security list-keychains -d user > "$work/search-list" || return 1
    search_paths=()
    search_count=0
    search_removed=0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -n "$line" ] || continue
        [[ "$line" == \"*\" ]] || return 1
        encoded="${line:1:${#line}-2}"
        path='' escaped=0
        for ((index=0; index<${#encoded}; index++)); do
            char="${encoded:index:1}"
            if [ "$escaped" = 1 ]; then
                [[ "$char" == '"' || "$char" == "\\" ]] || return 1
                path+="$char"; escaped=0
            elif [ "$char" = "\\" ]; then
                escaped=1
            elif [ "$char" = '"' ]; then
                return 1
            else
                path+="$char"
            fi
        done
        [ "$escaped" = 0 ] && [ -n "$path" ] || return 1
        if [ "$path" = "$keychain" ] || [ "$path" = "${keychain%-db}" ] || [ "$path" -ef "$keychain" ]; then
            search_removed=1
        else
            search_paths[search_count]="$path"
            search_count=$((search_count + 1))
        fi
    done < "$work/search-list"
}
signing_restore_search_list() {
    if [ "$search_count" = 0 ]; then
        signing_command /usr/bin/security list-keychains -d user -s >/dev/null
    else
        signing_command /usr/bin/security list-keychains -d user -s "${search_paths[@]}" >/dev/null
    fi
}
signing_add_search_keychain() {
    search_dirty=1
    if [ "$search_count" = 0 ]; then
        signing_command /usr/bin/security list-keychains -d user -s "$keychain" >/dev/null
    else
        signing_command /usr/bin/security list-keychains -d user -s "${search_paths[@]}" "$keychain" >/dev/null
    fi
}
signing_cleanup() {
    local result=$?
    trap '' HUP INT TERM
    trap - EXIT
    if [ "$search_dirty" = 1 ]; then
        if signing_restore_search_list; then
            printf '%s\n' 'removed from search list' > "$SIGNING_SEARCH_STATUS"
        else
            # Never publish/fall back while our keychain might remain searchable.
            : > "$SIGNING_RESTORE_FAILED"
            rm -f "$SIGNING_SEARCH_STATUS"
            signing_unavailable 'restoring user keychain search list' || true
            result=1
        fi
    fi
    rm -rf "$work"
    exit "$result"
}
stable_sign_app() (
    umask 077
    local signing_dir="$DIR/.signing" identity_dir="$DIR/.signing/identity"
    local keychain="$DIR/.signing/ccl-signing.keychain-db" password_file="$DIR/.signing/keychain-pass"
    local work pass leaf identities requirement attempt search_count search_removed search_dirty=0 codesign_failed
    local -a search_paths
    command -v /usr/bin/security >/dev/null 2>&1 || { signing_unavailable 'security missing'; return 1; }
    [ ! -L "$signing_dir" ] && [ ! -L "$identity_dir" ] \
        || { signing_unavailable 'signing directory is a symlink'; return 1; }
    if ! mkdir -p "$signing_dir" || ! chmod 700 "$signing_dir"; then
        signing_unavailable 'private signing directory'; return 1
    fi
    for file in "$password_file" "$keychain" "$identity_dir/key.pem" "$identity_dir/cert.pem" "$identity_dir/identity.p12"; do
        [ ! -L "$file" ] || { signing_unavailable 'signing file is a symlink'; return 1; }
    done
    work="$(mktemp -d "$signing_dir/.setup.XXXXXX")" \
        || { signing_unavailable 'signing temporary directory'; return 1; }
    trap signing_cleanup EXIT
    trap 'printf "129\n" > "$SIGNING_INTERRUPTED"; exit 129' HUP
    trap 'printf "130\n" > "$SIGNING_INTERRUPTED"; exit 130' INT
    trap 'printf "143\n" > "$SIGNING_INTERRUPTED"; exit 143' TERM
    signing_snapshot_search_list || { signing_unavailable 'reading user keychain search list'; return 1; }
    if [ "$search_removed" = 1 ]; then
        search_dirty=1
        signing_restore_search_list || { signing_unavailable 'removing signing keychain from search list'; return 1; }
        search_dirty=0
        printf '%s\n' 'removed from search list' > "$SIGNING_SEARCH_STATUS"
    else
        printf '%s\n' 'not in search list' > "$SIGNING_SEARCH_STATUS"
    fi
    command -v openssl >/dev/null 2>&1 || { signing_unavailable 'openssl missing'; return 1; }
    command -v /usr/bin/codesign >/dev/null 2>&1 || { signing_unavailable 'codesign missing'; return 1; }
    if [ ! -f "$password_file" ]; then
        [ ! -e "$keychain" ] || { signing_unavailable 'signing keychain password missing'; return 1; }
        if ! openssl rand -hex 32 > "$work/pass" 2>/dev/null || ! mv "$work/pass" "$password_file"; then
            signing_unavailable 'random signing password'; return 1
        fi
    fi
    chmod 600 "$password_file" || { signing_unavailable 'signing password permissions'; return 1; }
    pass="$(cat "$password_file")" || { signing_unavailable 'signing password unreadable'; return 1; }
    [[ "$pass" =~ ^[0-9a-fA-F]{64}$ ]] || { signing_unavailable 'signing password invalid'; return 1; }
    if [ ! -e "$identity_dir" ]; then
        [ ! -e "$keychain" ] || { signing_unavailable 'signing identity missing'; return 1; }
        mkdir "$work/identity" || { signing_unavailable 'identity directory'; return 1; }
        cat > "$work/identity/openssl.cnf" <<'SIGNING_CONFIG' || { signing_unavailable 'certificate configuration'; return 1; }
[req]
prompt = no
distinguished_name = subject
x509_extensions = signing
[subject]
CN = Claude Codex Limits Local Signing
[signing]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
SIGNING_CONFIG
        if ! openssl req -new -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
            -config "$work/identity/openssl.cnf" -keyout "$work/identity/key.pem" -out "$work/identity/cert.pem" \
            >/dev/null 2>&1 || ! mv "$work/identity" "$identity_dir"; then
            signing_unavailable 'certificate generation'; return 1
        fi
    fi
    [ -f "$identity_dir/key.pem" ] && [ -f "$identity_dir/cert.pem" ] \
        || { signing_unavailable 'incomplete signing identity'; return 1; }
    if ! chmod 700 "$identity_dir" || ! chmod 600 "$identity_dir/key.pem" "$identity_dir/cert.pem"; then
        signing_unavailable 'identity permissions'; return 1
    fi
    openssl x509 -in "$identity_dir/cert.pem" -noout -checkend 0 >/dev/null 2>&1 \
        || { signing_unavailable 'certificate invalid or expired'; return 1; }
    leaf="$(openssl x509 -in "$identity_dir/cert.pem" -noout -fingerprint -sha1 2>/dev/null \
        | sed 's/.*=//' | tr -d ':' | tr '[:lower:]' '[:upper:]')" \
        || { signing_unavailable 'certificate fingerprint'; return 1; }
    [[ "$leaf" =~ ^[0-9A-F]{40}$ ]] || { signing_unavailable 'certificate fingerprint invalid'; return 1; }
    if [ ! -e "$keychain" ]; then
        # Creation may modify the search list even if the command later fails.
        search_dirty=1
        signing_command /usr/bin/security create-keychain -p "$pass" "$keychain" >/dev/null \
            || { signing_unavailable 'signing keychain creation'; return 1; }
        signing_restore_search_list || { signing_unavailable 'restoring user keychain search list'; return 1; }
        search_dirty=0
        printf '%s\n' 'removed from search list' > "$SIGNING_SEARCH_STATUS"
    fi
    chmod 600 "$keychain" || { signing_unavailable 'signing keychain permissions'; return 1; }
    signing_command /usr/bin/security unlock-keychain -p "$pass" "$keychain" >/dev/null \
        || { signing_unavailable 'signing keychain unlock'; return 1; }
    identities="$(signing_command /usr/bin/security find-identity "$keychain")" \
        || { signing_unavailable 'signing identity lookup'; return 1; }
    if [[ "$identities" != *"$leaf"* ]]; then
        # Explicit PKCS#12 algorithms work with both system LibreSSL and OpenSSL3
        # and Apple's importer. The certificate itself is signed with SHA-256.
        if ! openssl pkcs12 -export -inkey "$identity_dir/key.pem" -in "$identity_dir/cert.pem" \
            -name 'Claude Codex Limits Local Signing' -out "$work/identity.p12" \
            -passout "file:$password_file" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1 \
            || ! mv "$work/identity.p12" "$identity_dir/identity.p12"; then
            signing_unavailable 'PKCS12 export'; return 1
        fi
        signing_command /usr/bin/security import "$identity_dir/identity.p12" -k "$keychain" -P "$pass" -T /usr/bin/codesign >/dev/null \
            || { signing_unavailable 'signing identity import'; return 1; }
    fi
    signing_command /usr/bin/security set-key-partition-list -S apple-tool:,apple: -s -k "$pass" "$keychain" >/dev/null \
        || { signing_unavailable 'signing key partition access'; return 1; }
    # Pin the leaf explicitly: self-signed certificates need no system trust,
    # and this DR stays identical when a rebuild changes the executable cdhash.
    requirement="designated => identifier \"$BUNDLE_ID\" and certificate leaf = H\"$leaf\""
    for attempt in 1 2 3 4 5 6 7 8; do
        signing_command /usr/bin/security unlock-keychain -p "$pass" "$keychain" >/dev/null \
            || { signing_unavailable 'signing keychain unlock'; return 1; }
        codesign_failed=0
        if signing_command xattr -cr "$APP" >/dev/null; then
            if ! signing_command /usr/bin/codesign --force --deep --sign "$leaf" --keychain "$keychain" \
                --identifier "$BUNDLE_ID" --requirements "=$requirement" --timestamp=none "$APP" >/dev/null; then
                codesign_failed=1
            fi
        else
            continue
        fi
        if [ "$codesign_failed" = 0 ] \
            && signing_command /usr/bin/codesign --verify --strict "$APP" >/dev/null \
            && signing_read_requirement "$work/requirement" \
            && grep '^designated =>' "$work/requirement" >"$work/dr" \
            && grep -Fqi "certificate leaf = H\"$leaf\"" "$work/dr" \
            && ! grep -q 'cdhash' "$work/dr"; then
            printf '%s\n' "$leaf"
            return 0
        fi
        # First try only the explicit --keychain. Some macOS versions also need
        # it in the search list; append once, restore on every exit/signal.
        if [ "$codesign_failed" = 1 ] && [ "$search_dirty" = 0 ]; then
            signing_add_search_keychain || { signing_unavailable 'temporary signing keychain search list'; return 1; }
        fi
    done
    signing_unavailable 'stable codesign or requirement verification'
)
signing_read_requirement() {
    if /usr/bin/codesign -dr - "$APP" >"$1" 2>&1; then return 0; fi
    signing_record_error "$1"
    return 1
}

# Clear extended attributes first. Files copied from Resources carry FinderInfo /
# resource forks; without this codesign aborts with "resource fork, Finder
# information, or similar detritus not allowed".
#
# When the build directory lives on a cloud file-provider volume (iCloud Drive / Dropbox / etc.,
# marked by a com.apple.fileprovider.fpfs xattr) the provider ASYNCHRONOUSLY
# re-injects com.apple.FinderInfo onto the freshly-created .app bundle root a
# moment after we clear it — so a single clear+sign can lose the race and fail
# intermittently with the "detritus not allowed" error. Retry the clear+sign+verify
# until codesign wins on a settled tree (it converges within a couple of attempts).
stable_ok=0
if STABLE_LEAF="$(stable_sign_app 2>/dev/null)"; then stable_ok=1; fi
if [ -f "$SIGNING_SEARCH_STATUS" ]; then
    echo "signing keychain: $(cat "$SIGNING_SEARCH_STATUS")"
fi
if [ -f "$SIGNING_RESTORE_FAILED" ]; then
    KEEP_BUILD_SOURCE=1
    echo 'ERROR: could not restore keychain search list; ccl-signing may still be listed — rerun build.sh to clean up' >&2
    exit 1
fi
if [ -f "$SIGNING_INTERRUPTED" ]; then
    echo 'ERROR: signing interrupted; dist unchanged' >&2
    exit "$(cat "$SIGNING_INTERRUPTED")"
fi
if [ "$stable_ok" = 1 ]; then
    echo "signing: stable (leaf ${STABLE_LEAF:0:8})"
else
    signing_reason="$(cat "$SIGNING_REASON" 2>/dev/null)" || signing_reason='setup failed'
    signing_detail="$(awk 'NF { last=$0 } END { print substr(last,1,160) }' "$SIGNING_ERR")"
    signing_detail="$(signing_display_path "$signing_detail")"
    if [ -n "$signing_detail" ]; then signing_reason="$signing_reason: $signing_detail"; fi
    if [ "${CCL_REQUIRE_STABLE_SIGNING:-0}" = 1 ]; then
        KEEP_BUILD_SOURCE=1
        echo "ERROR: stable signing unavailable ($signing_reason); dist unchanged" >&2
        echo "Build retained: $(signing_display_path "$BUILD_SOURCE_DIR")" >&2
        exit 1
    fi
    echo "WARNING: stable signing unavailable ($signing_reason), using ad-hoc" >&2
    signed=0
    for attempt in 1 2 3 4 5 6 7 8; do
        if xattr -cr "$APP" 2>"$CODESIGN_LOG" \
           && /usr/bin/codesign --force --deep -s - "$APP" 2>>"$CODESIGN_LOG" \
           && /usr/bin/codesign --verify --strict "$APP" 2>>"$CODESIGN_LOG"; then
            signed=1; break
        fi
        echo "   sign/verify attempt $attempt lost the FinderInfo race, retrying…" >&2
    done
    if [ "$signed" != 1 ]; then
        echo "!! codesign FAILED for $APP after 8 attempts" >&2
        cat "$CODESIGN_LOG" >&2 || true
        exit 1
    fi
    echo "signing: ad-hoc"
fi
echo "==> signed & verified"

mkdir -p "$DIR/dist"
old_app="$DIST_APP.old.$$"
if [ -e "$DIST_APP" ] || [ -L "$DIST_APP" ]; then
    if ! mv "$DIST_APP" "$old_app" 2>/dev/null; then
        echo 'ERROR: publishing to dist failed; previous app restored' >&2
        exit 1
    fi
fi
if ! mv "$APP" "$DIST_APP" 2>/dev/null; then
    rm -rf "$DIST_APP"
    if [ -e "$old_app" ] || [ -L "$old_app" ]; then
        if ! mv "$old_app" "$DIST_APP" 2>/dev/null; then
            echo 'ERROR: publishing to dist failed; previous app remains in .old backup' >&2
            exit 1
        fi
    fi
    echo 'ERROR: publishing to dist failed; previous app restored' >&2
    exit 1
fi
rm -rf "$old_app"
echo "==> built: $(signing_display_path "$DIST_APP")"
