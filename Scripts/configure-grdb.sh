#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
trace_root="$(cd "${script_dir}/.." && pwd)"
grdb_root="${trace_root}/Vendor/GRDB.swift"

if [[ ! -d "${grdb_root}/GRDBCustom.xcodeproj" ]]; then
  echo "error: GRDB submodule is missing; run git submodule update --init --recursive" >&2
  exit 1
fi

install -m 0644 "${trace_root}/GRDBCustomSQLite/SQLiteLib-USER.xcconfig" \
  "${grdb_root}/SQLiteCustom/src/SQLiteLib-USER.xcconfig"
install -m 0644 "${trace_root}/GRDBCustomSQLite/GRDBCustomSQLite-USER.xcconfig" \
  "${grdb_root}/SQLiteCustom/GRDBCustomSQLite-USER.xcconfig"
install -m 0644 "${trace_root}/GRDBCustomSQLite/GRDBCustomSQLite-USER.h" \
  "${grdb_root}/SQLiteCustom/GRDBCustomSQLite-USER.h"

echo "Configured GRDB custom SQLite with FTS5 and snapshot support."
