#!/bin/sh
# Fake lpac for tests. State file $LPAC_STATE: one profile per line  iccid|state|name|nick|provider
# Every invocation is appended to $LPAC_STATE.log. When a profile is enabled and
# $LPAC_FAKE_MODEM_ICCID_FILE is set, the ICCID (plus a trailing F like AT+QCCID) is written there.
S=${LPAC_STATE:?LPAC_STATE}
[ -f "$S" ] || : > "$S"
printf '%s\n' "$*" >> "$S.log"

ok()  { printf '{"type":"lpa","payload":{"code":0,"message":"success","data":%s}}\n' "${1:-null}"; }
err() { printf '{"type":"lpa","payload":{"code":-1,"message":"%s","data":""}}\n' "$1"; exit 1; }

set_state() {  # iccid newstate
	awk -F'|' -v OFS='|' -v i="$1" -v s="$2" '$1 == i { $2 = s } { print }' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
}
have_iccid() { awk -F'|' -v i="$1" '$1 == i { f = 1 } END { exit !f }' "$S"; }

case "$1 $2" in
	"chip info")
		ok '{"eidValue":"89044045900000000000000912484375","EuiccConfiguredAddresses":{"defaultDpAddress":"smdp-plus-0.eu.cd.rsp.kigen.com","rootDsAddress":"lpa.ds.gsma.com"},"EUICCInfo2":{"svn":"2.3.0","euiccFirmwareVer":"37.4.3","extCardResource":{"installedApplication":10,"freeNonVolatileMemory":1485632,"freeVolatileMemory":31387}}}' ;;
	"profile list")
		data=$(awk -F'|' 'BEGIN { printf "[" } NR > 1 { printf "," }
			{ nick = ($4 == "" ? "null" : "\"" $4 "\""); printf "{\"iccid\":\"%s\",\"isdpAid\":\"a000000559101000\",\"profileState\":\"%s\",\"profileNickname\":%s,\"serviceProviderName\":\"%s\",\"profileName\":\"%s\",\"profileClass\":\"operational\"}", $1, $2, nick, $5, $3 }
			END { printf "]" }' "$S")
		ok "$data" ;;
	"profile enable")
		have_iccid "$3" || err "es10c_enable_profile"
		awk -F'|' -v OFS='|' '{ $2 = "disabled"; print }' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
		set_state "$3" enabled
		[ -n "${LPAC_FAKE_MODEM_ICCID_FILE:-}" ] && printf '%sF\n' "$3" > "$LPAC_FAKE_MODEM_ICCID_FILE"
		ok ;;
	"profile disable")
		have_iccid "$3" || err "es10c_disable_profile"
		set_state "$3" disabled; ok ;;
	"profile delete")
		have_iccid "$3" || err "es10c_delete_profile"
		awk -F'|' -v i="$3" '$1 == i && $2 == "enabled" { exit 1 }' "$S" || err "es10c_delete_profile: profile enabled"
		awk -F'|' -v i="$3" '$1 != i' "$S" > "$S.tmp" && mv "$S.tmp" "$S"; ok ;;
	"profile nickname")
		have_iccid "$3" || err "es10c_set_nickname"
		awk -F'|' -v OFS='|' -v i="$3" -v n="$4" '$1 == i { $4 = n } { print }' "$S" > "$S.tmp" && mv "$S.tmp" "$S"; ok ;;
	"profile download")
		code=; shift 2
		while [ $# -gt 0 ]; do case $1 in -a) code=$2; shift ;; -s|-m|-c|-i) shift ;; esac; shift; done
		[ -n "$code" ] || err "es9p_initiate_authentication: no activation code"
		printf '8949000000000000001|disabled|Downloaded|%s|NewTel\n' "${code#LPA:1\$}" >> "$S"; ok ;;
	*) err "unknown command $1 $2" ;;
esac
