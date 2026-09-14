#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
trace_root="$(cd "${script_dir}/.." && pwd)"

cd "${trace_root}"
before_manifest="$(mktemp)"
after_manifest="$(mktemp)"
trap 'rm -f "${before_manifest}" "${after_manifest}"' EXIT

find Trace.xcodeproj -type f -print0 | sort -z | xargs -0 shasum > "${before_manifest}"
xcodegen generate --quiet
find Trace.xcodeproj -type f -print0 | sort -z | xargs -0 shasum > "${after_manifest}"

if ! diff -u "${before_manifest}" "${after_manifest}"; then
  echo "error: Trace.xcodeproj is out of date; run xcodegen generate" >&2
  exit 1
fi
