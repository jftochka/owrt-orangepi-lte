#!/bin/sh
# simei test suite.
# Runs on a host (macOS/Linux: uses tests/uci-shim) and on OpenWrt (real uci). Needs socat.
#   sh simei/tests/run.sh            (TEST_SH=dash or TEST_SH="busybox ash" to run the script under
#                                     another shell, TEST_PORT to change the port)
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SIMEI=${SIMEI:-$ROOT/usr/sbin/simei}
ATBRIDGE=$ROOT/etc/init.d/atbridge
HOTPLUG=$ROOT/etc/hotplug.d/tty/90-simei
# installed on a router (tests under /usr/lib/simei/tests): test the installed files
if [ ! -f "$SIMEI" ] && [ -x /usr/sbin/simei ]; then
	SIMEI=/usr/sbin/simei; ATBRIDGE=/etc/init.d/atbridge; HOTPLUG=/etc/hotplug.d/tty/90-simei
fi
SH=${TEST_SH:-sh}
PORT=${TEST_PORT:-5001}
T=$(mktemp -d "${TMPDIR:-/tmp}/simei-test.XXXXXX")

command -v socat >/dev/null 2>&1 || { echo "socat is required"; exit 1; }
command -v uci >/dev/null 2>&1 || PATH="$HERE/uci-shim:$PATH"
export PATH

# --- fixtures ---------------------------------------------------------------
export SIMEI_UCI_DIR="$T/uci"
mkdir -p "$SIMEI_UCI_DIR" "$T/sysfs" "$T/bin"
printf "config global 'global'\n\toption at_host '127.0.0.1'\n\toption at_port '%s'\n\n" "$PORT" > "$SIMEI_UCI_DIR/simei"
export SIMEI_AT_HOST=127.0.0.1 SIMEI_AT_PORT=$PORT SIMEI_FACTORY_FILE="$T/factory"
export SIMEI_UI=text SIMEI_SYSFS="$T/sysfs" SIMEI_APPLY_TIMEOUT=10 SIMEI_NO_ANSI=1
unset SIMEI_QMI_DEV

STATE="$T/modem"; mkdir -p "$STATE"
echo 490154203237518 > "$STATE/imei"
echo 8938001111111111111 > "$STATE/iccid"
echo 20 > "$STATE/csq"

# fake uqmi: signal info for the live dashboard, UIM client ids and card state for the eSIM
# preflight (UQMI_FAKE_NO_CLIENT / UQMI_FAKE_SIM_STATE simulate a modem that cannot serve them)
cat > "$T/bin/uqmi" <<'EOF'
#!/bin/sh
case " $* " in
	*--get-client-id*)     [ "${UQMI_FAKE_NO_CLIENT:-0}" = 1 ] || echo 2 ;;
	*--release-client-id*) ;;
	*--uim-get-sim-state*)
		if [ -n "${UQMI_FAKE_SIM_STATE:-}" ]; then printf '%s\n' "$UQMI_FAKE_SIM_STATE"
		else echo '{"card_state":"present","application_state":"ready"}'; fi ;;
	*--uim-channel-open*)  echo '{"channel_id":1}' ;;
	*) echo '{"type":"lte","rssi":-65,"rsrq":-9,"rsrp":-95,"snr":12.4}' ;;
esac
EOF
chmod +x "$T/bin/uqmi"
PATH="$T/bin:$PATH"

socat "TCP-LISTEN:$PORT,reuseaddr,fork,bind=127.0.0.1" SYSTEM:"sh '$HERE/fake_modem.sh' '$STATE'" &
FAKE=$!
trap 'kill $FAKE 2>/dev/null; rm -rf "$T"' EXIT INT TERM
sleep 1

# --- harness ----------------------------------------------------------------
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       | /'; }
# expect NAME "pattern" "text"  -> text must contain a line matching the ERE
expect() { if printf '%s\n' "$3" | grep -qE "$2"; then ok "$1"; else bad "$1" "$3"; fi; }
reject() { if printf '%s\n' "$3" | grep -qE "$2"; then bad "$1" "$3"; else ok "$1"; fi; }
# $SH is split on purpose so TEST_SH can name an interpreter with arguments, e.g. "busybox ash"
# (the shell the router actually runs simei with)
run() { $SH "$SIMEI" "$@" 2>&1; }

# 1. syntax
if sh -n "$SIMEI"; then ok "sh -n simei"; else bad "sh -n simei"; fi
if command -v dash >/dev/null 2>&1; then
	if dash -n "$SIMEI"; then ok "dash -n simei"; else bad "dash -n simei"; fi
fi
if sh -n "$ATBRIDGE"; then ok "sh -n atbridge"; else bad "sh -n atbridge"; fi
if sh -n "$HOTPLUG"; then ok "sh -n hotplug"; else bad "sh -n hotplug"; fi

# 2. luhn
out=$(run luhn 49015420323751); expect "luhn: 14 digits -> check digit appended" '^490154203237518$' "$out"
if run luhn 490154203237518 >/dev/null; then ok "luhn: valid 15-digit IMEI accepted"; else bad "luhn: valid IMEI rejected"; fi
if run luhn 490154203237519 >/dev/null; then bad "luhn: wrong check digit accepted"; else ok "luhn: wrong check digit rejected"; fi
if run luhn 12345 >/dev/null; then bad "luhn: short input accepted"; else ok "luhn: short input rejected"; fi

# 3. raw AT and status
out=$(run at AT+GSN); expect "at: AT+GSN returns IMEI" '^490154203237518$' "$out"; expect "at: final OK present" '^OK$' "$out"
out=$(run status --raw)
expect "status: imei"  '^imei=490154203237518$' "$out"
expect "status: iccid" '^iccid=8938001111111111111$' "$out"
expect "status: rssi from CSQ 20" '^rssi_dbm=-73$' "$out"
expect "status: operator" '^operator=FakeTel$' "$out"
expect "status: LTE" '^act=LTE$' "$out"
expect "status: no profile yet" '^profile=$' "$out"
out=$(run status); expect "status: pretty output" '^IMEI *: *490154203237518$' "$out"

# 4. register / list / add
out=$(run register "Main SIM"); expect "register: creates sim1" 'sim1' "$out"
out=$(run list)
expect "list: sim1 with iccid and imei" 'sim1 .*Main SIM.*8938001111111111111.*490154203237518' "$out"
if run register "Again" >/dev/null 2>&1; then bad "register: duplicate ICCID accepted"; else ok "register: duplicate ICCID rejected"; fi
out=$(run add "Second SIM" 8938002222222222222); expect "add: creates sim2" 'sim2' "$out"
out=$(run status --raw); expect "status: profile matched by ICCID" '^profile=sim1$' "$out"; expect "status: imei match" '^imei_match=yes$' "$out"

# 5. move / swap
out=$(run move sim1 sim2)
expect "move: sim2 got the IMEI" '^imei=490154203237518$' "$(printf 'imei=%s\n' "$(uci -c "$SIMEI_UCI_DIR" -q get simei.sim2.imei)")"
expect "move: sim1 IMEI cleared" '^imei=$' "$(printf 'imei=%s\n' "$(uci -c "$SIMEI_UCI_DIR" -q get simei.sim1.imei)")"
run swap sim1 sim2 >/dev/null
expect "swap: sim1 has IMEI again" '^imei=490154203237518$' "$(printf 'imei=%s\n' "$(uci -c "$SIMEI_UCI_DIR" -q get simei.sim1.imei)")"
if run move sim9 sim1 >/dev/null 2>&1; then bad "move: unknown profile accepted"; else ok "move: unknown profile rejected"; fi

# 6. apply
NEW=$(run luhn 35693803564380)
run set sim2 imei "$NEW" >/dev/null
echo 8938002222222222222 > "$STATE/iccid"                # "insert" the second SIM
: > "$STATE/log"
out=$(run apply --yes); rc=$?
if [ $rc -eq 0 ]; then ok "apply: exit 0"; else bad "apply: exit $rc" "$out"; fi
expect "apply: modem IMEI rewritten" "^$NEW\$" "$(cat "$STATE/imei")"
expect "apply: EGMR write sent" "^AT\\+EGMR=1,7,\"$NEW\"\$" "$(cat "$STATE/log")"
expect "apply: modem restarted" '^AT\+CFUN=1,1$' "$(cat "$STATE/log")"
expect "apply: verified" 'verified' "$out"
expect "apply: factory IMEI backed up" '^490154203237518$' "$(cat "$T/factory")"
: > "$STATE/log"
out=$(run apply --yes); rc=$?
expect "apply: nothing to do when IMEI matches" 'nothing to do' "$out"
reject "apply: no EGMR when nothing to do" 'EGMR=1' "$(cat "$STATE/log")"
uci -c "$SIMEI_UCI_DIR" set simei.sim2.imei=000000000000001
: > "$STATE/log"
out=$(run apply --yes); rc=$?
if [ $rc -eq 2 ]; then ok "apply: invalid IMEI refused with exit 2"; else bad "apply: invalid IMEI exit $rc" "$out"; fi
reject "apply: no EGMR for invalid IMEI" 'EGMR=1' "$(cat "$STATE/log")"
out=$(run apply); rc=$?
if [ $rc -ne 0 ]; then ok "apply: without --yes and no tty refuses"; else bad "apply: wrote without confirmation" "$out"; fi
echo 8938009999999999999 > "$STATE/iccid"
out=$(run apply --yes); rc=$?
if [ $rc -eq 3 ]; then ok "apply: unknown SIM -> exit 3"; else bad "apply: unknown SIM exit $rc" "$out"; fi
echo 8938002222222222222 > "$STATE/iccid"
run set sim2 imei "$NEW" >/dev/null

# 7. set validation
if run set sim1 imei 123 >/dev/null 2>&1; then bad "set: bad IMEI accepted"; else ok "set: bad IMEI rejected"; fi
out=$(run set sim1 name "Renamed"); out=$(run list); expect "set: rename" 'sim1 .*Renamed' "$out"
run delete sim2 >/dev/null; out=$(run list); reject "delete: sim2 gone" 'sim2' "$out"

# 8. live --once
echo 1000 > "$T/sysfs/rx_bytes"; echo 500 > "$T/sysfs/tx_bytes"
echo 126000 > "$T/sysfs/rx_bytes"; echo 63000 > "$T/sysfs/tx_bytes"
out=$(SIMEI_LIVE_PREV="1000 500" SIMEI_LIVE_INTERVAL=1 run live --once)
expect "live: downlink 1.0 Mbit/s" '1\.0 Mbit/s' "$out"
expect "live: uplink 500 kbit/s" '500 kbit/s' "$out"
expect "live: RSRP from uqmi" 'RSRP *-95' "$out"
expect "live: IMEI shown" "$(cat "$STATE/imei")" "$out"

# 9. text TUI smoke test
out=$(printf 'exit\n' | run); rc=$?
if [ $rc -eq 0 ]; then ok "tui: exit"; else bad "tui: exit rc=$rc" "$out"; fi
expect "tui: menu shows live entry" 'live' "$out"
out=$(printf 'status\n\nexit\n' | run)
expect "tui: status screen shows IMEI" "IMEI *: *$(cat "$STATE/imei")" "$out"

echo
# 10. eSIM via the fake lpac
export SIMEI_LPAC="$HERE/fake_lpac.sh" LPAC_STATE="$T/esim" LPAC_FAKE_MODEM_ICCID_FILE="$STATE/iccid"
export SIMEI_ESIM_BACKEND=at SIMEI_ESIM_TTY="$T/no-such-tty"
printf '8948010010087197546|enabled|DENT|Main|DENT\n8948020000000000001|disabled|Play|TelB|Play\n' > "$T/esim"
echo "8948010010087197546F" > "$STATE/iccid"
out=$(run esim info); expect "esim info: EID" 'EID *: *89044045900000000000000912484375' "$out"
out=$(run esim list)
expect "esim list: DENT enabled" '^8948010010087197546 +enabled +DENT' "$out"
expect "esim list: Play disabled" '^8948020000000000001 +disabled +Play' "$out"
out=$(run status --raw); expect "status: ICCID normalised (trailing F dropped)" '^iccid=8948010010087197546$' "$out"
run add "DENT" 8948010010087197546 "$(cat "$STATE/imei")" >/dev/null
P2=$(run luhn 86123456789012)
run add "Play" 8948020000000000001 "$P2" >/dev/null
out=$(run esim list); expect "esim list: IMEI column from simei profile" "^8948020000000000001 .* $P2\$" "$out"
: > "$STATE/log"; : > "$T/esim.log"
out=$(run switch 8948020000000000001 --yes); rc=$?
if [ $rc -eq 0 ]; then ok "switch: exit 0"; else bad "switch: exit $rc" "$out"; fi
expect "switch: lpac enable called" '^profile enable 8948020000000000001' "$(cat "$T/esim.log")"
expect "switch: Play now enabled" '^8948020000000000001\|enabled' "$(cat "$T/esim")"
expect "switch: DENT now disabled" '^8948010010087197546\|disabled' "$(cat "$T/esim")"
expect "switch: modem restarted" '^AT\+CFUN=1,1$' "$(cat "$STATE/log")"
expect "switch: IMEI written for the new SIM" "^$P2\$" "$(cat "$STATE/imei")"
out=$(run switch Play --yes 2>&1); rc=$?
if [ $rc -ne 0 ]; then ok "switch: unknown profile name rejected"; else bad "switch: accepted a non-profile name" "$out"; fi
out=$(run switch sim3 --yes); expect "switch by profile id: already enabled" 'already enabled' "$out"; expect "switch: IMEI unchanged" 'nothing to do' "$out"
run esim nickname 8948020000000000001 "Work" >/dev/null; out=$(run esim list); expect "esim nickname" '^8948020000000000001 +enabled +Play +Work' "$out"
if run esim delete 8948020000000000001 --yes >/dev/null 2>&1; then bad "esim delete: deleted an enabled profile"; else ok "esim delete: refuses an enabled profile"; fi
out=$(run esim disable 8948020000000000001); expect "esim disable" 'disabled' "$out"
out=$(run esim delete 8948020000000000001 --yes); expect "esim delete" 'deleted' "$out"
reject "esim delete: gone from the eUICC" '8948020000000000001' "$(cat "$T/esim")"
out=$(run esim download 'LPA:1$smdp.example$ABC-123'); expect "esim download: listed afterwards" '8949000000000000001 +disabled' "$out"
expect "esim download: lpac arguments" 'profile download -a LPA:1\$smdp.example\$ABC-123' "$(cat "$T/esim.log")"
if run esim download 'not-a-code' >/dev/null 2>&1; then bad "esim download: bad code accepted"; else ok "esim download: bad code rejected"; fi
if run switch 8948099999999999999 --yes >/dev/null 2>&1; then bad "switch: unknown ICCID accepted"; else ok "switch: unknown ICCID rejected"; fi
out=$(printf 'esim\nback\nexit\n' | run); expect "tui: esim menu lists profiles" '8948010010087197546' "$out"

# 10b. uqmi eSIM backend (SFT-142). /dev/null stands in for the QMI device: the preflight only
# needs a character device, and the fake uqmi answers whatever is asked of it.
export SIMEI_ESIM_RETRY_DELAY=0 SIMEI_LPAC_LOCK="$T/lpac.lock"
: > "$T/esim.log"
out=$(SIMEI_ESIM_BACKEND=uqmi SIMEI_QMI_DEV=/dev/null run esim info)
elog=$(cat "$T/esim.log")
expect "esim uqmi: EID read" 'EID *: *89044045900000000000000912484375' "$out"
expect "esim uqmi: backend line names the QMI device" 'LPA backend *: *uqmi \(/dev/null\)' "$out"
expect "esim uqmi: LPAC_QMI_DEV set (the name the driver reads)" 'LPAC_QMI_DEV=/dev/null' "$elog"
expect "esim uqmi: LPAC_APDU_QMI_DEVICE set (the name the wrapper exports)" 'LPAC_APDU_QMI_DEVICE=/dev/null' "$elog"

# the debug flag reaches both spellings, and the driver's debug output must not break the result
: > "$T/esim.log"
out=$(SIMEI_ESIM_BACKEND=uqmi SIMEI_QMI_DEV=/dev/null SIMEI_ESIM_DEBUG=1 run esim info)
elog=$(cat "$T/esim.log")
expect "esim uqmi: LPAC_QMI_DEBUG set" 'LPAC_QMI_DEBUG=1' "$elog"
expect "esim uqmi: LPAC_APDU_UQMI_DEBUG set" 'LPAC_APDU_UQMI_DEBUG=1' "$elog"
expect "esim uqmi: driver debug lines do not break the JSON result" 'EID *: *89044045900000000000000912484375' "$out"

# 10c. preflight: name the failing step instead of letting lpac report a bare euicc_init
: > "$T/esim.log"
out=$(SIMEI_ESIM_BACKEND=uqmi SIMEI_QMI_DEV=/dev/no-such-wdm run esim info 2>&1); rc=$?
if [ $rc -ne 0 ]; then ok "esim preflight: missing QMI device fails"; else bad "esim preflight: missing device accepted" "$out"; fi
expect "esim preflight: missing device named" 'not a character device' "$out"
expect "esim preflight: points at the doctor" 'simei esim doctor' "$out"
reject "esim preflight: lpac not called without a device" 'chip info' "$(cat "$T/esim.log")"
out=$(SIMEI_ESIM_BACKEND=uqmi SIMEI_QMI_DEV='/dev/cdc-wdm0; reboot' run esim info 2>&1)
expect "esim preflight: shell-unsafe device path refused" 'not a plain path' "$out"
out=$(UQMI_FAKE_NO_CLIENT=1 SIMEI_ESIM_BACKEND=uqmi SIMEI_QMI_DEV=/dev/null run esim info 2>&1)
expect "esim preflight: no UIM client id named" 'no UIM client id' "$out"
out=$(PATH="$HERE/uci-shim:/usr/bin:/bin" SIMEI_ESIM_BACKEND=uqmi SIMEI_QMI_DEV=/dev/null run esim info 2>&1)
expect "esim preflight: missing uqmi named" 'uqmi is not installed' "$out"

# 10d. transient euicc_init is retried once; a real eUICC answer is reported as it is
echo 1 > "$T/lpac-fail"; : > "$T/esim.log"
out=$(LPAC_FAIL_COUNT_FILE="$T/lpac-fail" SIMEI_ESIM_BACKEND=uqmi SIMEI_QMI_DEV=/dev/null run esim info)
expect "esim retry: succeeds on the second attempt" 'EID *: *89044045900000000000000912484375' "$out"
expect "esim retry: lpac called twice" '^2$' "$(grep -c '^chip info' "$T/esim.log")"
echo 5 > "$T/lpac-fail"; : > "$T/esim.log"
out=$(LPAC_FAIL_COUNT_FILE="$T/lpac-fail" SIMEI_ESIM_BACKEND=uqmi SIMEI_QMI_DEV=/dev/null run esim info 2>&1); rc=$?
if [ $rc -ne 0 ]; then ok "esim retry: gives up after the configured retries"; else bad "esim retry: reported success" "$out"; fi
expect "esim retry: bounded at one retry" '^2$' "$(grep -c '^chip info' "$T/esim.log")"
expect "esim retry: euicc_init reported" 'euicc_init' "$out"
: > "$T/esim.log"
out=$(run esim disable 8948099999999999999 2>&1)
expect "esim retry: an eUICC error is not retried" '^1$' "$(grep -c '^profile disable' "$T/esim.log")"

# 10e. auto backend: uqmi first, AT when the uqmi path cannot serve the request
: > "$T/esim.log"
out=$(SIMEI_ESIM_BACKEND=auto SIMEI_QMI_DEV=/dev/no-such-wdm run esim info)
expect "esim auto: falls back when the uqmi preflight fails" 'EID *: *89044045900000000000000912484375' "$out"
expect "esim auto: the fallback ran on AT" 'LPAC_APDU=at' "$(cat "$T/esim.log")"
: > "$T/esim.log"
out=$(LPAC_FAIL_BACKENDS=uqmi SIMEI_ESIM_BACKEND=auto SIMEI_QMI_DEV=/dev/null run esim info)
elog=$(cat "$T/esim.log")
expect "esim auto: falls back on euicc_init" 'EID *: *89044045900000000000000912484375' "$out"
expect "esim auto: uqmi is tried first" 'LPAC_APDU=uqmi' "$elog"
expect "esim auto: AT served the result" 'LPAC_APDU=at' "$elog"

# 10f. one eSIM operation at a time (the eUICC has a single channel)
mkdir -p "$T/lpac.lock"; echo $$ > "$T/lpac.lock/pid"
out=$(SIMEI_LPAC_LOCK_WAIT=0 run esim info 2>&1); rc=$?
if [ $rc -ne 0 ]; then ok "esim lock: a held lock stops a second run"; else bad "esim lock: ran anyway" "$out"; fi
expect "esim lock: says what is holding it" 'another eSIM operation' "$out"
sh -c 'exit 0' & dead=$!; wait $dead 2>/dev/null
echo "$dead" > "$T/lpac.lock/pid"
out=$(SIMEI_LPAC_LOCK_WAIT=0 run esim info 2>&1)
expect "esim lock: a lock from a dead run is cleared" 'EID *: *89044045900000000000000912484375' "$out"
if [ -d "$T/lpac.lock" ]; then bad "esim lock: lock left behind after the run"; else ok "esim lock: released after the run"; fi

# 10g. doctor: walks the same path step by step and exits non-zero when a step fails
out=$(SIMEI_ESIM_BACKEND=uqmi SIMEI_QMI_DEV=/dev/null run esim doctor); rc=$?
if [ $rc -eq 0 ]; then ok "esim doctor: exit 0 on a healthy path"; else bad "esim doctor: exit $rc" "$out"; fi
expect "esim doctor: client id probe" 'ok +UIM client id +2' "$out"
expect "esim doctor: card state" 'ok +UIM card state' "$out"
expect "esim doctor: chip info EID" 'ok +lpac chip info +EID 89044045900000000000000912484375' "$out"
expect "esim doctor: healthy summary" 'eSIM path is healthy' "$out"
out=$(SIMEI_ESIM_BACKEND=uqmi SIMEI_QMI_DEV=/dev/no-such-wdm run esim doctor); rc=$?
if [ $rc -ne 0 ]; then ok "esim doctor: exit non-zero when a check fails"; else bad "esim doctor: reported healthy" "$out"; fi
expect "esim doctor: names the missing QMI device" 'FAIL +QMI device' "$out"
expect "esim doctor: says the uqmi path was not attempted" 'uqmi APDU path was not attempted' "$out"
expect "esim doctor: names the AT fallback" 'esim_backend=at' "$out"
out=$(LPAC_FAIL_BACKENDS=uqmi SIMEI_ESIM_BACKEND=uqmi SIMEI_QMI_DEV=/dev/null run esim doctor); rc=$?
if [ $rc -ne 0 ]; then ok "esim doctor: exit non-zero on euicc_init"; else bad "esim doctor: reported healthy" "$out"; fi
expect "esim doctor: lists the euicc_init causes" 'euicc_init means lpac never opened' "$out"
out=$(UQMI_FAKE_SIM_STATE='{}' SIMEI_ESIM_BACKEND=uqmi SIMEI_QMI_DEV=/dev/null run esim doctor)
expect "esim doctor: empty UIM card state flagged" 'FAIL +UIM card state' "$out"
expect "esim doctor: points at the no-SIM cause" 'no SIM/eUICC' "$out"
out=$(UQMI_FAKE_NO_CLIENT=1 SIMEI_ESIM_BACKEND=uqmi SIMEI_QMI_DEV=/dev/null run esim doctor)
expect "esim doctor: missing client id flagged" 'FAIL +UIM client id' "$out"
out=$(SIMEI_ESIM_BACKEND=uqmi SIMEI_QMI_DEV=/dev/null run esim doctor --debug)
expect "esim doctor --debug: raw lpac output" 'raw lpac output \(uqmi backend\)' "$out"
expect "esim doctor --debug: driver debug lines shown" 'UQMI_DEBUG_TX' "$out"
out=$(SIMEI_ESIM_BACKEND=at run esim doctor)
expect "esim doctor: AT backend checks the AT port" 'FAIL +AT port' "$out"
out=$(SIMEI_ESIM_BACKEND=nonsense SIMEI_QMI_DEV=/dev/null run esim doctor)
expect "esim doctor: unknown backend flagged" 'FAIL +backend' "$out"
unset SIMEI_ESIM_RETRY_DELAY SIMEI_LPAC_LOCK

# 11. blank (all-zero) IMEI: Luhn-valid but must be rejected and never stored
if run luhn 000000000000000 >/dev/null 2>&1; then bad "luhn: all-zero IMEI accepted"; else ok "luhn: all-zero IMEI rejected"; fi
echo 000000000000000 > "$STATE/imei"; echo 8948030000000000003 > "$STATE/iccid"; rm -f "$T/factory"
out=$(run status); expect "status: blank IMEI flagged" 'IMEI *: *000000000000000 .*blank' "$out"
out=$(run register "Blank" 2>&1); expect "register: blank IMEI not stored" 'not stored' "$out"
p=$(uci -c "$SIMEI_UCI_DIR" -q show simei | sed -n "s/^simei\.\([^.]*\)\.iccid='8948030000000000003'$/\1/p")
expect "register: profile created without IMEI" '^imei=$' "imei=$(uci -c "$SIMEI_UCI_DIR" -q get "simei.$p.imei")"
Z=$(run luhn 35209900176148)
run set "$p" imei "$Z" >/dev/null; : > "$STATE/log"
out=$(run apply --yes); rc=$?
if [ $rc -eq 0 ]; then ok "apply: from blank IMEI to a real one"; else bad "apply: from blank IMEI rc=$rc" "$out"; fi
if [ -f "$T/factory" ]; then bad "apply: all-zero IMEI saved as factory backup"; else ok "apply: no factory backup of a blank IMEI"; fi
expect "apply: modem now has the assigned IMEI" "^$Z\$" "$(cat "$STATE/imei")"

# 12. USB mode guard (SFT-239): the EG25-G can come back in ECM mode after a power loss
echo 1 > "$STATE/usbnet"; : > "$STATE/log"
out=$(run usbmode); rc=$?
expect "usbmode: reports ECM" '^usbnet=1 \(ecm\)$' "$out"
if [ $rc -eq 1 ]; then ok "usbmode: exit 1 when not QMI"; else bad "usbmode: exit $rc when not QMI" "$out"; fi
reject "usbmode: query leaves the mode alone" 'QCFG="usbnet",0' "$(cat "$STATE/log")"
out=$(run usbmode --fix); rc=$?
if [ $rc -eq 0 ]; then ok "usbmode --fix: exit 0"; else bad "usbmode --fix: exit $rc" "$out"; fi
expect "usbmode --fix: usbnet set to 0" '^0$' "$(cat "$STATE/usbnet")"
expect "usbmode --fix: QCFG write sent" '^AT\+QCFG="usbnet",0$' "$(cat "$STATE/log")"
expect "usbmode --fix: modem restarted" '^AT\+CFUN=1,1$' "$(cat "$STATE/log")"
expect "usbmode --fix: reports the switch" 'switched to QMI' "$out"
: > "$STATE/log"
out=$(run usbmode --fix); rc=$?
expect "usbmode --fix: no-op when already QMI" 'already QMI' "$out"
reject "usbmode --fix: no restart when already QMI" 'CFUN=1,1' "$(cat "$STATE/log")"
out=$(run usbmode); rc=$?
expect "usbmode: reports QMI" '^usbnet=0 \(qmi\)$' "$out"
if [ $rc -eq 0 ]; then ok "usbmode: exit 0 when QMI"; else bad "usbmode: exit $rc when QMI" "$out"; fi

# 12b. hotplug: the guard runs when the AT port appears, before the optional auto-apply
printf '#!/bin/sh\nexec %s "%s" "$@"\n' "$SH" "$SIMEI" > "$T/bin/simei-bin"; chmod +x "$T/bin/simei-bin"
echo 1 > "$STATE/usbnet"; : > "$STATE/log"
ACTION=add DEVNAME=ttyUSB2 SIMEI_BIN="$T/bin/simei-bin" SIMEI_HOTPLUG_DELAY=0 sh "$HOTPLUG"; sleep 3
expect "hotplug: switches ECM to QMI" '^0$' "$(cat "$STATE/usbnet")"
expect "hotplug: restarts the modem" '^AT\+CFUN=1,1$' "$(cat "$STATE/log")"
: > "$STATE/log"
ACTION=add DEVNAME=ttyUSB2 SIMEI_BIN="$T/bin/simei-bin" SIMEI_HOTPLUG_DELAY=0 sh "$HOTPLUG"; sleep 3
reject "hotplug: no restart when already QMI" 'CFUN=1,1' "$(cat "$STATE/log")"
: > "$STATE/log"
ACTION=add DEVNAME=ttyUSB9 SIMEI_BIN="$T/bin/simei-bin" SIMEI_HOTPLUG_DELAY=0 sh "$HOTPLUG"; sleep 1
reject "hotplug: other ttys ignored" 'AT' "$(cat "$STATE/log")"
ACTION=remove DEVNAME=ttyUSB2 SIMEI_BIN="$T/bin/simei-bin" SIMEI_HOTPLUG_DELAY=0 sh "$HOTPLUG"; sleep 1
reject "hotplug: remove events ignored" 'AT' "$(cat "$STATE/log")"

echo "passed: $pass  failed: $fail"
[ $fail -eq 0 ]
