#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
trace_root="$(cd "${script_dir}/.." && pwd)"
grdb_root="${trace_root}/Vendor/GRDB.swift"
sqlite_root="${grdb_root}/SQLiteCustom/src"
sqlite_patch="${trace_root}/GRDBCustomSQLite/SQLiteLib-macOS15.patch"

if [[ ! -d "${grdb_root}/GRDBCustom.xcodeproj" || ! -f "${sqlite_root}/SQLiteLib.xcconfig" ]]; then
  echo "error: GRDB submodule is missing; run git submodule update --init --recursive" >&2
  exit 1
fi

if git -C "${sqlite_root}" apply --unidiff-zero --reverse --check "${sqlite_patch}" >/dev/null 2>&1; then
  : # The deployment-target patch is already applied.
elif git -C "${sqlite_root}" apply --unidiff-zero --check "${sqlite_patch}"; then
  git -C "${sqlite_root}" apply --unidiff-zero "${sqlite_patch}"
else
  echo "error: SQLiteLib's deployment-target patch no longer applies cleanly" >&2
  exit 1
fi

install -m 0644 "${trace_root}/GRDBCustomSQLite/SQLiteLib-USER.xcconfig" \
  "${grdb_root}/SQLiteCustom/src/SQLiteLib-USER.xcconfig"
install -m 0644 "${trace_root}/GRDBCustomSQLite/GRDBCustomSQLite-USER.xcconfig" \
  "${grdb_root}/SQLiteCustom/GRDBCustomSQLite-USER.xcconfig"
install -m 0644 "${trace_root}/GRDBCustomSQLite/GRDBCustomSQLite-USER.h" \
  "${grdb_root}/SQLiteCustom/GRDBCustomSQLite-USER.h"

echo "Configured GRDB custom SQLite for macOS 15 with FTS5 and snapshot support."
