#!/bin/zsh
# Luoto — a fork of Atoll (DynamicIsland)
# Copyright (C) 2026 amidamaru940 and Luoto contributors
# Licensed under the GNU General Public License v3.0 or later; see LICENSE.
#
# The lid-closed helper under a real launchd, in the user's own domain: a debug
# build, a throwaway folder and a fake pmset, so no root and no change to the Mac.
# The job is removed at the end. Checks what the unit tests cannot: launchd starts
# the helper on a change in the folder, and brings it back after kill -9.
#
# Usage: scripts/check-lid-guard-launchd.sh <the debug helper in Luoto.app/Contents/Helpers>
set -u
H="$1"
ROOT="$(mktemp -d)"
LABEL="io.github.amidamaru940.luoto.lidguard.check.$$"
PLIST="$ROOT/job.plist"
mkdir -p "$ROOT/session" "$ROOT/support" "$ROOT/sim" "$ROOT/Luoto.app"
: > "$ROOT/plist"; : > "$ROOT/helper"
cat > "$ROOT/fake-pmset" <<EOF
#!/bin/sh
echo "\$(/bin/date +%s) \$*" >> '$ROOT/pmset.log'
case "\$*" in
  "-a disablesleep 1") echo 1 > '$ROOT/sim/flag' ;;
  "-a disablesleep 0") echo 0 > '$ROOT/sim/flag' ;;
esac
EOF
chmod 755 "$ROOT/fake-pmset"
/usr/bin/plutil -create xml1 "$PLIST"
/usr/bin/plutil -insert Label -string "$LABEL" "$PLIST"
/usr/bin/plutil -insert ProgramArguments -json "[\"$H\",\"$ROOT/Luoto.app\",\"--test-root\",\"$ROOT\"]" "$PLIST"
/usr/bin/plutil -insert RunAtLoad -bool true "$PLIST"
/usr/bin/plutil -insert WatchPaths -json "[\"$ROOT/session\"]" "$PLIST"
/usr/bin/plutil -insert KeepAlive -json '{"Crashed":true,"SuccessfulExit":false}' "$PLIST"
cleanup() { launchctl bootout "gui/$UID/$LABEL" 2>/dev/null; rm -rf "$ROOT"; true; }
trap cleanup EXIT
now() { /usr/bin/perl -MTime::HiRes=time -e 'printf "%.2f\n", time'; }
wait_for() { # file value limit
  local start=$(now)
  while :; do
    [[ "$(cat "$1" 2>/dev/null | tr -d '[:space:]')" == "$2" ]] && { echo "$(( $(now) - start ))"; return 0; }
    (( $(now) - start > $3 )) && { echo "TIMEOUT"; return 1; }
    sleep 0.05
  done
}
pid() { pgrep -f -- "--test-root $ROOT" | head -1; }
echo "bootstrap: $(launchctl bootstrap "gui/$UID" "$PLIST" 2>&1; echo rc=$?)"
sleep 1
echo "1 no lease: at load it exits; running=$([[ -n "$(pid)" ]] && echo yes || echo no); status=$(cat "$ROOT/support/status" 2>/dev/null)"
sleep 3
printf '' > "$ROOT/session/.t"; mv "$ROOT/session/.t" "$ROOT/session/lease"
echo "2 lease via rename: flag on after $(wait_for "$ROOT/sim/flag" 1 15) s; running=$([[ -n "$(pid)" ]] && echo yes || echo no)"
P=$(pid); kill -9 "$P" 2>/dev/null
sleep 12
P2=$(pid)
echo "3 kill -9 of $P with the lease fresh: running again=$([[ -n "$P2" && "$P2" != "$P" ]] && echo yes || echo no) flag=$(cat "$ROOT/sim/flag")"
printf '' > "$ROOT/session/.t"; mv "$ROOT/session/.t" "$ROOT/session/lease"
rm "$ROOT/session/lease"
echo "4 lease removed: flag off after $(wait_for "$ROOT/sim/flag" 0 15) s"
sleep 1
echo "  running=$([[ -n "$(pid)" ]] && echo yes || echo no) status=$(cat "$ROOT/support/status")"
sleep 0.5
printf '' > "$ROOT/session/.t"; mv "$ROOT/session/.t" "$ROOT/session/lease"
echo "5 new session right after: flag on after $(wait_for "$ROOT/sim/flag" 1 15) s"
: > "$ROOT/session/uninstall"
sleep 4
echo "6 uninstall: plist gone=$([[ ! -e "$ROOT/plist" ]] && echo yes || echo no) helper gone=$([[ ! -e "$ROOT/helper" ]] && echo yes || echo no) support gone=$([[ ! -e "$ROOT/support" ]] && echo yes || echo no) flag=$(cat "$ROOT/sim/flag")"
echo "calls:"; cut -d' ' -f2- "$ROOT/pmset.log"
