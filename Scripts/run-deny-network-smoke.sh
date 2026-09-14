#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /path/to/Trace.app" >&2
  exit 2
fi

trace_app="$1"
trace_binary="${trace_app}/Contents/MacOS/Trace"
if [[ ! -x "${trace_binary}" ]]; then
  echo "error: Trace executable not found at ${trace_binary}" >&2
  exit 1
fi

profile='(version 1) (allow default) (deny network*)'
sandbox-exec -p "${profile}" "${trace_binary}" --network-smoke
