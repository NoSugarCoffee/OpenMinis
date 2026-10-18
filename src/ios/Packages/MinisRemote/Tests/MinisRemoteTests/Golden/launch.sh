R="$HOME/.minis/runs/"'run1'
mkdir -p "$R" || exit 96
cd '/home/a b/it'\''s' || exit 97
printf '%s' 'ZWNobyBoaQ==' > "$R/cmd.b64"
base64 -d < "$R/cmd.b64" > "$R/cmd" 2>/dev/null || base64 -D < "$R/cmd.b64" > "$R/cmd" 2>/dev/null
if [ $? -ne 0 ] || { [ -s "$R/cmd.b64" ] && [ ! -s "$R/cmd" ]; }; then echo "minis: cannot decode command" >&2; exit 98; fi
rm -f "$R/cmd.b64"
case "${SHELL##*/}" in
  sh|bash|zsh|dash|ksh|ash) S="$SHELL" ;;
  *) S=/bin/sh ;;
esac
export R
if ! mkdir "$R/started" 2>/dev/null || [ -e "$R/exit" ]; then echo "minis: run was cancelled before it started" >&2; exit 95; fi
nohup "$S" -lc '( . "$R/cmd" ); echo $? > "$R/exit.tmp"; mv "$R/exit.tmp" "$R/exit"' </dev/null >"$R/out" 2>&1 &
echo $! > "$R/pid.tmp" && mv "$R/pid.tmp" "$R/pid"
