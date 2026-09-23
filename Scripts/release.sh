#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
trace_root="$(cd "${script_dir}/.." && pwd)"
release_dir="${trace_root}/build/release"
archive_path="${release_dir}/Trace.xcarchive"
export_path="${release_dir}/export"
export_options="${trace_root}/Config/DeveloperIDExportOptions.plist"
dmg_root="${release_dir}/dmg-root"
dmg_path="${release_dir}/Trace.dmg"
staged_dmg_path="${release_dir}/Trace.pending.dmg"
notary_profile="${TRACE_NOTARY_PROFILE:-TraceNotary}"
signing_identity="${TRACE_DEVELOPER_ID_APPLICATION:-}"
release_team="$(/usr/libexec/PlistBuddy -c 'Print :teamID' "${export_options}")"

if [[ ! -f "${trace_root}/Config/Signing.xcconfig" ]]; then
  echo "error: copy Config/Signing.xcconfig.example to Config/Signing.xcconfig" >&2
  exit 1
fi

if ! xcrun notarytool history --keychain-profile "${notary_profile}" >/dev/null 2>&1; then
  echo "error: notary keychain profile '${notary_profile}' is not configured; see Documentation/Release.md" >&2
  exit 1
fi

available_identities="$(security find-identity -v -p codesigning)"
if [[ -z "${signing_identity}" ]]; then
  signing_identity="$(printf '%s\n' "${available_identities}" | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | grep -F "(${release_team})" | head -n 1 || true)"
fi
if [[ -z "${signing_identity}" ]]; then
  echo "error: no Developer ID Application identity found for team ${release_team}" >&2
  exit 1
fi
if [[ "${signing_identity}" != "Developer ID Application: "* || "${signing_identity}" != *"(${release_team})" ]]; then
  echo "error: Developer ID Application identity must belong to team ${release_team}" >&2
  exit 1
fi
if ! printf '%s\n' "${available_identities}" | grep -Fq "\"${signing_identity}\""; then
  echo "error: Developer ID Application identity is not available in the keychain: ${signing_identity}" >&2
  exit 1
fi

mkdir -p "${release_dir}"
"${trace_root}/Scripts/configure-grdb.sh"

configured_team="$(xcodebuild -project "${trace_root}/Trace.xcodeproj" -target Trace -configuration Release -showBuildSettings 2>/dev/null | awk '$1 == "DEVELOPMENT_TEAM" { print $3; exit }')"
if [[ "${configured_team}" != "${release_team}" ]]; then
  echo "error: Release DEVELOPMENT_TEAM is '${configured_team}', expected '${release_team}'; update Config/Signing.xcconfig" >&2
  exit 1
fi

rm -rf "${archive_path}" "${export_path}" "${dmg_root}"
rm -f "${staged_dmg_path}"
mkdir -p "${dmg_root}"
xcodebuild archive \
  -project "${trace_root}/Trace.xcodeproj" \
  -scheme Trace \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "${archive_path}"

xcodebuild -exportArchive \
  -archivePath "${archive_path}" \
  -exportOptionsPlist "${export_options}" \
  -exportPath "${export_path}"

python3 "${trace_root}/Scripts/check-release-signing.py" \
  --team "${release_team}" \
  --identity "${signing_identity}" \
  "${export_path}/Trace.app"
ditto "${export_path}/Trace.app" "${dmg_root}/Trace.app"
"${trace_root}/Scripts/check-network-surface.sh" "${dmg_root}/Trace.app"
ln -sfn /Applications "${dmg_root}/Applications"
hdiutil create -volname Trace -srcfolder "${dmg_root}" -ov -format UDZO "${staged_dmg_path}"
codesign --force --timestamp --sign "${signing_identity}" "${staged_dmg_path}"
xcrun notarytool submit "${staged_dmg_path}" --keychain-profile "${notary_profile}" --wait
xcrun stapler staple "${staged_dmg_path}"
xcrun stapler validate "${staged_dmg_path}"
codesign --verify --deep --strict --verbose=2 "${dmg_root}/Trace.app"
codesign --verify --strict --verbose=2 "${staged_dmg_path}"
spctl --assess --type execute --verbose=2 "${dmg_root}/Trace.app"
spctl --assess --type open --context context:primary-signature --verbose=2 "${staged_dmg_path}"

mv -f "${staged_dmg_path}" "${dmg_path}"
echo "Release ready: ${dmg_path}"
