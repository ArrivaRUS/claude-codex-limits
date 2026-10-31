#!/bin/bash
# Build "Claude Codex Limits.app" into ./dist (no install). Pure system tooling.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Claude Codex Limits"
EXE_NAME="ClaudeCodexLimits"
BUNDLE_ID="com.arrivarus.claudecodexlimits"
VERSION="3.3.1"
APP="$DIR/dist/$APP_NAME.app"

echo "==> building $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

CCL_BUILD_TMP="${CCL_BUILD_TMP:-$DIR/.build-tmp}"
mkdir -p "$CCL_BUILD_TMP"
BUILD_SOURCE_DIR="$(mktemp -d "$CCL_BUILD_TMP/ccl-swift-build.XXXXXX")"
trap 'rm -rf "$BUILD_SOURCE_DIR"' EXIT
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
printf '%s\n' 'setup failed' > "$SIGNING_REASON"
signing_unavailable() {
    printf '%s\n' "$1" > "$SIGNING_REASON"
    return 1
}
stable_sign_app() (
    umask 077
    local signing_dir="$DIR/.signing" identity_dir="$DIR/.signing/identity"
    local keychain="$DIR/.signing/ccl-signing.keychain-db" password_file="$DIR/.signing/keychain-pass"
    local work pass leaf identities requirement attempt
    command -v openssl >/dev/null 2>&1 || { signing_unavailable 'openssl missing'; return 1; }
    command -v /usr/bin/security >/dev/null 2>&1 || { signing_unavailable 'security missing'; return 1; }
    command -v /usr/bin/codesign >/dev/null 2>&1 || { signing_unavailable 'codesign missing'; return 1; }
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
    trap 'rm -rf "$work"' EXIT
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
        /usr/bin/security create-keychain -p "$pass" "$keychain" >/dev/null 2>&1 \
            || { signing_unavailable 'signing keychain creation'; return 1; }
    fi
    chmod 600 "$keychain" || { signing_unavailable 'signing keychain permissions'; return 1; }
    /usr/bin/security unlock-keychain -p "$pass" "$keychain" >/dev/null 2>&1 \
        || { signing_unavailable 'signing keychain unlock'; return 1; }
    identities="$(/usr/bin/security find-identity "$keychain" 2>/dev/null)" \
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
        /usr/bin/security import "$identity_dir/identity.p12" -k "$keychain" -P "$pass" -T /usr/bin/codesign >/dev/null 2>&1 \
            || { signing_unavailable 'signing identity import'; return 1; }
    fi
    /usr/bin/security set-key-partition-list -S apple-tool:,apple: -s -k "$pass" "$keychain" >/dev/null 2>&1 \
        || { signing_unavailable 'signing key partition access'; return 1; }
    # Pin the leaf explicitly: self-signed certificates need no system trust,
    # and this DR stays identical when a rebuild changes the executable cdhash.
    requirement="designated => identifier \"$BUNDLE_ID\" and certificate leaf = H\"$leaf\""
    for attempt in 1 2 3 4 5 6 7 8; do
        /usr/bin/security unlock-keychain -p "$pass" "$keychain" >/dev/null 2>&1 \
            || { signing_unavailable 'signing keychain unlock'; return 1; }
        if xattr -cr "$APP" 2>"$CODESIGN_LOG" \
            && /usr/bin/codesign --force --deep --sign "$leaf" --keychain "$keychain" \
                --identifier "$BUNDLE_ID" --requirements "=$requirement" --timestamp=none "$APP" 2>>"$CODESIGN_LOG" \
            && /usr/bin/codesign --verify --strict "$APP" 2>>"$CODESIGN_LOG" \
            && /usr/bin/codesign -dr - "$APP" >"$work/requirement" 2>&1 \
            && grep '^designated =>' "$work/requirement" >"$work/dr" \
            && grep -Fqi "certificate leaf = H\"$leaf\"" "$work/dr" \
            && ! grep -q 'cdhash' "$work/dr"; then
            printf '%s\n' "$leaf"
            return 0
        fi
    done
    signing_unavailable 'stable codesign or requirement verification'
)

# Clear extended attributes first. Files copied from Resources carry FinderInfo /
# resource forks; without this codesign aborts with "resource fork, Finder
# information, or similar detritus not allowed".
#
# When dist/ lives on a cloud file-provider volume (iCloud Drive / Dropbox / etc.,
# marked by a com.apple.fileprovider.fpfs xattr) the provider ASYNCHRONOUSLY
# re-injects com.apple.FinderInfo onto the freshly-created .app bundle root a
# moment after we clear it — so a single clear+sign can lose the race and fail
# intermittently with the "detritus not allowed" error. Retry the clear+sign+verify
# until codesign wins on a settled tree (it converges within a couple of attempts).
if STABLE_LEAF="$(stable_sign_app 2>/dev/null)"; then
    echo "signing: stable (leaf ${STABLE_LEAF:0:8})"
else
    signing_reason="$(cat "$SIGNING_REASON" 2>/dev/null)" || signing_reason='setup failed'
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

echo "==> built: $APP"
