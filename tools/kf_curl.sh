#!/usr/bin/env bash
out=
args=()
while [ $# -gt 0 ]; do
  if [ "$1" = -o ]; then out=$2; shift 2; else args+=("$1"); shift; fi
done
cmd=$(printf '%q ' curl "${args[@]}")
ssh=(ssh -i "$HOME/.ssh/kf" -o BatchMode=yes -o ConnectTimeout=30 -o ControlPath="$HOME/.ssh/kf.ctl" h220178@vh167.hoster.by "$cmd")
if [ -n "$out" ]; then "${ssh[@]}" > "$out"; else "${ssh[@]}"; fi
