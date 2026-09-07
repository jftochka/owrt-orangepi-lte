#!/bin/sh
# SFT-142 retest: collect the evidence for the lpac uqmi APDU path on the router.
# Read-only - it changes no configuration; the only side effect is a UIM client id that is
# allocated and released again. Run it once the eUICC is readable (SFT-140):
#
#   tools/rt - < tools/06-esim-uqmi-verify.sh
#
# Green run = "simei esim doctor" passes on the uqmi backend; then the backend can be switched:
#   uci set simei.global.esim_backend=uqmi   # or auto, to keep AT as the fallback
#   uci commit simei
set -u

QMI_DEV=$(uci -q get simei.global.qmi_dev); QMI_DEV=${QMI_DEV:-/dev/cdc-wdm0}
LPAC_BIN=/usr/lib/lpac
rc=0

sec() { printf '\n== %s\n' "$1"; }

sec "versions and configuration"
simei version 2>/dev/null || true
apk list --installed lpac uqmi 2>/dev/null | sed -n '1,4p' || true
uci show simei.global 2>/dev/null || true
uci show lpac 2>/dev/null || true
ls -l /dev/cdc-wdm* /dev/ttyUSB* 2>/dev/null || true

sec "modem and SIM (AT)"
simei usbmode || true
for c in 'AT+CPIN?' 'AT+QSIMSTAT?' 'AT+QCCID' 'AT+CEREG?'; do
	printf '%s -> ' "$c"; simei at "$c" 2>&1 | tr '\n' ' '; printf '\n'
done

sec "uqmi UIM state"
uqmi -d "$QMI_DEV" --uim-get-sim-state 2>&1 || true
uqmi -d "$QMI_DEV" --uim-get-card-status 2>&1 | head -n 20 || true

sec "uqmi UIM client and ISD-R channel (the step lpac fails at)"
cid=$(uqmi -s -d "$QMI_DEV" --get-client-id uim 2>&1 | tr -dc '0-9')
if [ -n "$cid" ]; then
	echo "client id: $cid"
	uqmi -s -d "$QMI_DEV" --set-client-id "uim,$cid" --keep-client-id uim \
		--uim-slot 1 --uim-channel-open A0000005591010FFFFFFFF8900000100 2>&1 || true
	uqmi -s -d "$QMI_DEV" --set-client-id "uim,$cid" --release-client-id uim >/dev/null 2>&1
else
	echo "no client id from $QMI_DEV"; rc=1
fi

sec "lpac on the uqmi backend, both variable spellings, driver debug on"
LPAC_APDU=uqmi LPAC_APDU_QMI_DEVICE="$QMI_DEV" LPAC_QMI_DEV="$QMI_DEV" \
	LPAC_APDU_UQMI_DEBUG=1 LPAC_QMI_DEBUG=1 LPAC_HTTP=curl \
	timeout 60 "$LPAC_BIN" chip info 2>&1 | head -n 40 || true

sec "simei esim doctor - configured backend"
simei esim doctor || rc=1

sec "simei esim doctor - uqmi backend"
SIMEI_ESIM_BACKEND=uqmi simei esim doctor --debug || rc=1

sec "result"
if [ "$rc" -eq 0 ]; then
	echo "uqmi APDU path answered; SFT-142 can be closed after switching esim_backend"
else
	echo "uqmi APDU path still failing - keep esim_backend=at and attach this output to SFT-142"
fi
exit "$rc"
