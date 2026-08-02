#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
TARGET="${TARGET:-aarch64-macos}"
OPTIMIZE="${OPTIMIZE:-ReleaseSafe}"
OUT_DIR="${OUTPUT_DIR:-${ROOT}/zig-out/release}"
PACKAGE_APP="${ROOT}/zig-out/package/phux-cockpit.app"
APP="${OUT_DIR}/Phux Cockpit.app"
BASE="phux-cockpit-${VERSION}-macos-arm64"
ZIP="${OUT_DIR}/${BASE}.zip"
DMG="${OUT_DIR}/${BASE}.dmg"
CHECKSUMS="${OUT_DIR}/SHA256SUMS"
STAGING="${ROOT}/zig-out/package/dmg-staging"
NOTARY_ZIP="${ROOT}/zig-out/package/${BASE}-notarization.zip"

cleanup() {
    rm -rf -- "${STAGING}"
    rm -f -- "${NOTARY_ZIP}"
}
trap cleanup EXIT

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'error: macOS packaging must run on macOS\n' >&2
    exit 1
fi
if [[ "${TARGET}" != "aarch64-macos" ]]; then
    printf 'error: release target must be aarch64-macos (got %s)\n' "${TARGET}" >&2
    exit 1
fi

for tool in zig codesign ditto hdiutil lipo plutil shasum unzip; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        printf 'error: required tool not found: %s\n' "${tool}" >&2
        exit 1
    fi
done

rm -rf -- "${PACKAGE_APP}" "${APP}" "${STAGING}"
rm -f -- "${ZIP}" "${DMG}" "${CHECKSUMS}" "${NOTARY_ZIP}"
mkdir -p -- "${OUT_DIR}"

(
    cd "${ROOT}"
    zig build package \
        -Dtarget="${TARGET}" \
        -Doptimize="${OPTIMIZE}" \
        --summary all
)

if [[ ! -d "${PACKAGE_APP}" ]]; then
    printf 'error: native-sdk did not produce %s\n' "${PACKAGE_APP}" >&2
    exit 1
fi
mv -- "${PACKAGE_APP}" "${APP}"

RESOURCES="${APP}/Contents/Resources"
/bin/cp "${ROOT}/LICENSE" "${RESOURCES}/LICENSE.txt"
/bin/cp "${ROOT}/THIRD_PARTY_NOTICES.md" "${RESOURCES}/THIRD_PARTY_NOTICES.md"
rm -f -- "${RESOURCES}/package-manifest.zon"
cat > "${RESOURCES}/README.txt" <<'EOF'
Phux Cockpit

This bundle is assembled by the project's release packaging script after
native-sdk creates the application skeleton. See signing-plan.txt for the
signature mode and THIRD_PARTY_NOTICES.md for bundled software licenses.
EOF

PLIST="${APP}/Contents/Info.plist"
plist_value() {
    /usr/bin/plutil -extract "$1" raw -o - "${PLIST}"
}

[[ "$(plist_value CFBundleIdentifier)" == "dev.phux.cockpit" ]] || {
    printf 'error: unexpected CFBundleIdentifier\n' >&2
    exit 1
}
[[ "$(plist_value CFBundleDisplayName)" == "Phux Cockpit" ]] || {
    printf 'error: unexpected CFBundleDisplayName\n' >&2
    exit 1
}
[[ "$(plist_value CFBundleShortVersionString)" == "${VERSION}" ]] || {
    printf 'error: bundle version does not match VERSION=%s\n' "${VERSION}" >&2
    exit 1
}
[[ "$(plist_value CFBundleExecutable)" == "phux-cockpit" ]] || {
    printf 'error: unexpected CFBundleExecutable\n' >&2
    exit 1
}

EXECUTABLE="${APP}/Contents/MacOS/phux-cockpit"
[[ -x "${EXECUTABLE}" ]] || {
    printf 'error: app executable is missing or not executable\n' >&2
    exit 1
}
ARCHS="$(/usr/bin/lipo -archs "${EXECUTABLE}")"
[[ " ${ARCHS} " == *" arm64 "* && " ${ARCHS} " != *" x86_64 "* ]] || {
    printf 'error: expected an arm64-only executable, found: %s\n' "${ARCHS}" >&2
    exit 1
}

SIGNING_MODE="adhoc"
SIGNING_PLAN="${RESOURCES}/signing-plan.txt"
if [[ -n "${MACOS_SIGNING_IDENTITY:-}" ]]; then
    SIGNING_MODE="identity"
    sign_args=(--force --deep --options runtime --timestamp --sign "${MACOS_SIGNING_IDENTITY}")
    if [[ -n "${MACOS_ENTITLEMENTS:-}" ]]; then
        [[ -f "${MACOS_ENTITLEMENTS}" ]] || {
            printf 'error: MACOS_ENTITLEMENTS does not name a file\n' >&2
            exit 1
        }
        sign_args+=(--entitlements "${MACOS_ENTITLEMENTS}")
    fi
    printf 'signing=identity\nsigned with %s\n' "${MACOS_SIGNING_IDENTITY}" > "${SIGNING_PLAN}"
    /usr/bin/codesign "${sign_args[@]}" "${APP}"
else
    printf 'signing=adhoc\nad-hoc signed local build\n' > "${SIGNING_PLAN}"
    /usr/bin/codesign --force --deep --timestamp=none --sign - "${APP}"
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "${APP}"

NOTARIZED="false"
notary_values=(
    "${APPLE_NOTARY_KEY_PATH:-}"
    "${APPLE_NOTARY_KEY_ID:-}"
    "${APPLE_NOTARY_ISSUER_ID:-}"
)
notary_count=0
for value in "${notary_values[@]}"; do
    [[ -n "${value}" ]] && notary_count=$((notary_count + 1))
done

if [[ "${notary_count}" -eq 3 && "${SIGNING_MODE}" == "identity" ]]; then
    [[ -f "${APPLE_NOTARY_KEY_PATH}" ]] || {
        printf 'error: APPLE_NOTARY_KEY_PATH does not name a file\n' >&2
        exit 1
    }
    /usr/bin/ditto -c -k --keepParent "${APP}" "${NOTARY_ZIP}"
    /usr/bin/xcrun notarytool submit "${NOTARY_ZIP}" \
        --key "${APPLE_NOTARY_KEY_PATH}" \
        --key-id "${APPLE_NOTARY_KEY_ID}" \
        --issuer "${APPLE_NOTARY_ISSUER_ID}" \
        --wait
    /usr/bin/xcrun stapler staple "${APP}"
    /usr/bin/xcrun stapler validate "${APP}"
    /usr/sbin/spctl --assess --type execute --verbose=2 "${APP}"
    NOTARIZED="true"
elif [[ "${notary_count}" -ne 0 ]]; then
    printf 'warning: notarization needs a signing identity and all three APPLE_NOTARY_* values; producing an unnotarized release\n' >&2
fi
rm -f -- "${NOTARY_ZIP}"

# ditto preserves the signed bundle's resource forks, metadata, and symlinks.
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${APP}" "${ZIP}"
/usr/bin/unzip -tq "${ZIP}"

mkdir -p -- "${STAGING}"
/usr/bin/ditto "${APP}" "${STAGING}/Phux Cockpit.app"
ln -s /Applications "${STAGING}/Applications"
/usr/bin/hdiutil create \
    -quiet \
    -ov \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -volname "Phux Cockpit" \
    -srcfolder "${STAGING}" \
    "${DMG}"
/usr/bin/hdiutil verify -quiet "${DMG}"
rm -rf -- "${STAGING}"

(
    cd "${OUT_DIR}"
    /usr/bin/shasum -a 256 "$(basename "${ZIP}")" "$(basename "${DMG}")" > "$(basename "${CHECKSUMS}")"
    /usr/bin/shasum -a 256 -c "$(basename "${CHECKSUMS}")"
)

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'signing=%s\nnotarized=%s\n' "${SIGNING_MODE}" "${NOTARIZED}" >> "${GITHUB_OUTPUT}"
fi

printf 'Created and verified:\n'
printf '  %s\n  %s\n  %s\n  %s\n' "${APP}" "${ZIP}" "${DMG}" "${CHECKSUMS}"
printf 'Signing: %s; notarized: %s\n' "${SIGNING_MODE}" "${NOTARIZED}"
