R="$HOME/.minis/runs/"'run1'
sig='TERM'
root=$(cat "$R/pid" 2>/dev/null)
if [ -z "$root" ]; then echo 0; exit 0; fi
table=$(ps -A -o pid= -o ppid= 2>/dev/null || ps -o pid= -o ppid=)
all=$root; frontier=$root
while [ -n "$frontier" ]; do
  next=""; for p in $frontier; do kids=$(printf '%s\n' "$table" | awk -v p="$p" '$2==p {print $1}'); next="$next $kids"; done
  frontier=$(echo $next); all="$all $frontier"
done
if [ "$sig" = KILL ]; then
  for p in $(cat "$R/tree" 2>/dev/null); do
    case " $all " in *" $p "*) continue ;; esac
    printf '%s\n' "$table" | awk -v p="$p" '$1==p {f=1} END {exit !f}' && all="$all $p"
  done
else
  echo $all > "$R/tree"
fi
n=0; for p in $all; do kill -"$sig" "$p" 2>/dev/null && n=$((n+1)); done; echo "$n"
