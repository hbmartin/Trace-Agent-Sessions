#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
trace_root="$(cd "${script_dir}/.." && pwd)"

check_configuration() {
  local configuration="$1"
  local expected_injection="$2"
  local settings
  local injection
  local hardened_runtime

  settings="$(xcodebuild -project "${trace_root}/Trace.xcodeproj" -target Trace -configuration "${configuration}" -showBuildSettings 2>/dev/null)"
  injection="$(printf '%s\n' "${settings}" | awk '$1 == "CODE_SIGN_INJECT_BASE_ENTITLEMENTS" && $2 == "=" { print $3; exit }')"
  hardened_runtime="$(printf '%s\n' "${settings}" | awk '$1 == "ENABLE_HARDENED_RUNTIME" && $2 == "=" { print $3; exit }')"

  if [[ "${injection}" != "${expected_injection}" ]]; then
    echo "error: ${configuration} CODE_SIGN_INJECT_BASE_ENTITLEMENTS is '${injection}', expected '${expected_injection}'" >&2
    return 1
  fi
  if [[ "${hardened_runtime}" != YES ]]; then
    echo "error: ${configuration} ENABLE_HARDENED_RUNTIME is '${hardened_runtime}', expected 'YES'" >&2
    return 1
  fi
}

check_configuration Debug YES
check_configuration Release NO
echo "Debug and Release signing settings are configured correctly."
