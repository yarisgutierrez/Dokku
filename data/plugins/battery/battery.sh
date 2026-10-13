#!/bin/sh
# Battery charge for the Dokku battery widget. The first line goes on the icon and the
# second is the tooltip. A machine without a battery prints nothing.
dir=${POWER_SUPPLY_DIR:-/sys/class/power_supply}
for bat in "$dir"/BAT*; do
    [ -r "$bat/capacity" ] || continue
    cap=$(cat "$bat/capacity" 2>/dev/null) || continue
    case $cap in ''|*[!0-9]*) continue ;; esac
    status=$(cat "$bat/status" 2>/dev/null) || status=Unknown
    printf '%s%%\n' "$cap"
    printf 'Battery %s%% (%s)\n' "$cap" "$status"
    exit 0
done
