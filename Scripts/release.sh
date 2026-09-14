#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
trace_root="$(cd "${script_dir}/.." && pwd)"
release_dir="${trace_root}/build/release"
archive_path="${release_dir}/Trace.xcarchive"
dmg_root="${release_dir}/dmg-root"
dmg_path="${release_dir}/Trace.dmg"
notary_profile="${TRACE_NOTARY_PROFILE:-TraceNotary}"
signing_identity="${TRACE_DEVELOPER_ID_APPLICATION:-}"

if [[ ! -f "${trace_root}/Config/Signing.xcconfig" ]]; then
  echo "error: copy Config/Signing.xcconfig.example to Config/Signing.xcconfig" >&2
  exit 1
fi

if ! xcrun notarytool history --keychain-profile "${notary_profile}" >/dev/null; then
  echo "error: notary keychain profile '${notary_profile}' is not configured; see Documentation/Release.md" >&2
  exit 1
fi

if [[ -z "${signing_identity}" ]]; then
  signing_identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -n 1)"
fi
if [[ -z "${signing_identity}" ]]; then
  echo "error: no Developer ID Application identity found" >&2
  exit 1
fi

mkdir -p "${release_dir}" "${dmg_root}"
"${trace_root}/Scripts/configure-grdb.sh"
xcodegen generate --spec "${trace_root}/project.yml"

xcodebuild archive \
  -project "${trace_root}/Trace.xcodeproj" \
  -scheme Trace \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "${archive_path}"

ditto "${archive_path}/Products/Applications/Trace.app" "${dmg_root}/Trace.app"
"${trace_root}/Scripts/check-network-surface.sh" "${dmg_root}/Trace.app"
ln -sfn /Applications "${dmg_root}/Applications"
hdiutil create -volname Trace -srcfolder "${dmg_root}" -ov -format UDZO "${dmg_path}"
codesign --force --timestamp --sign "${signing_identity}" "${dmg_path}"
xcrun notarytool submit "${dmg_path}" --keychain-profile "${notary_profile}" --wait
xcrun stapler staple "${dmg_path}"
codesign --verify --deep --strict --verbose=2 "${dmg_root}/Trace.app"
codesign --verify --strict --verbose=2 "${dmg_path}"
spctl --assess --type execute --verbose=2 "${dmg_root}/Trace.app"
spctl --assess --type open --context context:primary-signature --verbose=2 "${dmg_path}"

echo "Release ready: ${dmg_path}"
