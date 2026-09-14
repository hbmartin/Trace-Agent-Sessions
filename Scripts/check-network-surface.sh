#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
trace_root="$(cd "${script_dir}/.." && pwd)"

if rg -n --glob '*.swift' \
  '(^|[^A-Za-z])(URLSession|NWConnection|NWListener|CFStreamCreatePairWithSocketToHost|WebSocket|Network\.framework)([^A-Za-z]|$)' \
  "${trace_root}/Sources"; then
  echo "error: runtime network API found in Trace sources" >&2
  exit 1
fi

echo "No prohibited runtime network APIs found."

if [[ $# -gt 0 ]]; then
  trace_app="$1"
  trace_binary="${trace_app}/Contents/MacOS/Trace"
  if [[ ! -x "${trace_binary}" ]]; then
    echo "error: Trace executable not found at ${trace_binary}" >&2
    exit 1
  fi
  if otool -L "${trace_binary}" | rg -n '/(Network|CFNetwork)\.framework/'; then
    echo "error: prohibited networking framework linked by Trace" >&2
    exit 1
  fi
  if nm -u "${trace_binary}" | rg -n '(URLSession|NWConnection|NWListener|CFStreamCreatePairWithSocketToHost)'; then
    echo "error: prohibited networking symbol imported by Trace" >&2
    exit 1
  fi
  echo "No prohibited runtime network frameworks or symbols found in ${trace_binary}."
fi
