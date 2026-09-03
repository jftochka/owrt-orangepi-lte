#!/bin/sh
# socat based helper for the OrangePi Zero3 serial console.
#
#   tools/serial.sh console            interactive console (exit with Ctrl-])
#   tools/serial.sh run [-w SEC] "cmd" run one shell command on the router, print its output
#   tools/serial.sh status             show who holds the port
#
# Environment: SERIAL_PORT (default /dev/cu.usbserial-BG03FZOC), SERIAL_BAUD (115200)

PORT=${SERIAL_PORT:-/dev/cu.usbserial-BG03FZOC}
BAUD=${SERIAL_BAUD:-115200}
SOCAT=${SOCAT:-socat}
# macOS socat wants ispeed/ospeed, Linux socat also accepts b115200
TTYOPTS="raw,echo=0,ispeed=$BAUD,ospeed=$BAUD,clocal=1,nonblock"

die() { printf 'serial.sh: %s\n' "$*" >&2; exit 1; }

holders() {
	ps -axo pid=,command= | grep -F "$PORT" | grep -vE 'grep|serial\.sh' | grep -v "$SOCAT"
}

check_free() {
	[ -e "$PORT" ] || die "$PORT does not exist (USB serial adapter unplugged?)"
	command -v "$SOCAT" >/dev/null 2>&1 || die "socat not found; run: brew install socat"
	h=$(holders)
	if [ -n "$h" ]; then
		printf 'serial.sh: %s is busy:\n%s\n' "$PORT" "$h" >&2
		die "close it first (picocom: press C-a then C-x)"
	fi
}

# run_cmd WAIT "command": the command is bracketed by two marker echoes; everything the
# router prints between the START and END marker lines is the command output. The echoed
# input line may be wrapped by the shell's line editor, so only exact marker lines count.
run_cmd() {
	wait=$1; shift
	cmd=$*
	id="$$$(date +%S)"
	fifo=$(mktemp -u "${TMPDIR:-/tmp}/serial.XXXXXX")
	mkfifo "$fifo" || die "mkfifo failed"
	(
		printf '\r'
		sleep 0.3
		printf 'echo S%s; %s; echo E%s\r' "$id" "$cmd" "$id"
		sleep "$wait"
	) > "$fifo" &
	wpid=$!
	"$SOCAT" -T "$wait" - "$PORT,$TTYOPTS" < "$fifo" 2>/dev/null \
		| LC_ALL=C tr -d '\r\000' \
		| LC_ALL=C awk -v s="S$id" -v e="E$id" '
			!on { if ($0 == s) on = 1; next }
			$0 == e { exit }
			{ print }'
	kill "$wpid" 2>/dev/null
	wait "$wpid" 2>/dev/null
	rm -f "$fifo"
}

case ${1:-} in
	console)
		check_free
		printf 'Connected to %s at %s baud. Ctrl-] exits.\n' "$PORT" "$BAUD" >&2
		exec "$SOCAT" -,raw,echo=0,escape=0x1d "$PORT,$TTYOPTS"
		;;
	run)
		shift
		wait=3
		if [ "${1:-}" = -w ]; then wait=$2; shift 2; fi
		[ $# -ge 1 ] || die "usage: serial.sh run [-w SEC] \"command\""
		check_free
		run_cmd "$wait" "$@"
		;;
	status)
		[ -e "$PORT" ] && echo "port: $PORT" || echo "port: $PORT (missing)"
		h=$(holders); [ -n "$h" ] && printf 'held by:\n%s\n' "$h" || echo "port is free"
		;;
	*)
		sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
		exit 64
		;;
esac
