#!/bin/sh
# Output volume for the Dokku volume widget.   usage: volume.sh [status|up|down|toggle]
# Uses wpctl (PipeWire) and falls back to pactl (PulseAudio). The first line goes on the
# icon and the second is the tooltip. Prints nothing when neither tool is there.
step=${DOKKU_VOLUME_STEP:-5}
case $step in ''|*[!0-9]*) step=5 ;; esac

if command -v wpctl >/dev/null 2>&1; then
    case ${1:-status} in
        up)     wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ "${step}%+" ;;
        down)   wpctl set-volume @DEFAULT_AUDIO_SINK@ "${step}%-" ;;
        toggle) wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle ;;
    esac
    out=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null) || exit 0
    # "Volume: 0.45" or "Volume: 0.45 [MUTED]"
    vol=$(printf '%s\n' "$out" | awk '{ printf "%d", $2 * 100 + 0.5 }')
    muted=no
    case $out in *MUTED*) muted=yes ;; esac
elif command -v pactl >/dev/null 2>&1; then
    case ${1:-status} in
        up)     pactl set-sink-volume @DEFAULT_SINK@ "+${step}%" ;;
        down)   pactl set-sink-volume @DEFAULT_SINK@ "-${step}%" ;;
        toggle) pactl set-sink-mute @DEFAULT_SINK@ toggle ;;
    esac
    # "Volume: front-left: 29491 /  45% / -20.00 dB, ..."
    vol=$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | awk -F'/' 'NR==1 { gsub(/[ %]/, "", $2); print $2 }')
    [ -n "$vol" ] || exit 0
    muted=no
    case $(pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null) in *yes*) muted=yes ;; esac
else
    exit 0
fi

case $vol in ''|*[!0-9]*) exit 0 ;; esac
if [ "$muted" = yes ]; then
    printf 'mute\nVolume %s%% (muted)\n' "$vol"
else
    printf '%s%%\nVolume %s%%\n' "$vol" "$vol"
fi
