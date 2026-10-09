#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
trace_root="$(cd "${script_dir}/.." && pwd)"
grdb_root="${trace_root}/Vendor/GRDB.swift"
sqlite_root="${grdb_root}/SQLiteCustom/src"

if [[ ! -d "${grdb_root}/GRDBCustom.xcodeproj" || ! -f "${sqlite_root}/SQLiteLib.xcconfig" ]]; then
  echo "error: GRDB submodule is missing; run git submodule update --init --recursive" >&2
  exit 1
fi

python3 "${trace_root}/Scripts/validate-benchmark-baseline.py" --configure-sqlite "${trace_root}"

install_if_changed() {
  # Preserve dependency timestamps when configuring another test invocation.
  # Rewriting identical headers forces a complete SQLite/GRDB rebuild.
  cmp -s "$1" "$2" || install -m 0644 "$1" "$2"
}
install_if_changed "${trace_root}/GRDBCustomSQLite/SQLiteLib-USER.xcconfig" \
  "${grdb_root}/SQLiteCustom/src/SQLiteLib-USER.xcconfig"
install_if_changed "${trace_root}/GRDBCustomSQLite/GRDBCustomSQLite-USER.xcconfig" \
  "${grdb_root}/SQLiteCustom/GRDBCustomSQLite-USER.xcconfig"
install_if_changed "${trace_root}/GRDBCustomSQLite/GRDBCustomSQLite-USER.h" \
  "${grdb_root}/SQLiteCustom/GRDBCustomSQLite-USER.h"

echo "Configured GRDB custom SQLite for macOS 15 with FTS5 and snapshot support."
