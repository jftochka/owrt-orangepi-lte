#!/bin/sh
# Fake Quectel EG25-G AT command responder, one instance per connection:
#   socat TCP-LISTEN:5001,reuseaddr,fork SYSTEM:"sh fake_modem.sh /path/to/state"
#
# State directory files (created with defaults when missing):
#   imei iccid imsi cpin csq oper reboots   and   log (every received command, appended)
# Behaves like the real modem: echoes the command, answers with <CR><LF>...<CR><LF>OK<CR><LF>.

S=${1:?state dir}
mkdir -p "$S"

getf() { if [ -f "$S/$1" ]; then cat "$S/$1"; else printf '%s\n' "$2"; fi; }
info() { printf '\r\n%s\r\n' "$1"; }
final() { printf '\r\n%s\r\n' "$1"; }

handle() {
	cmd=$1
	printf '%s\n' "$cmd" >> "$S/log"
	printf '%s\r' "$cmd"                      # echo, like ATE1
	c=$(printf '%s' "$cmd" | tr 'a-z' 'A-Z')
	case $c in
		AT|ATE0|ATE1|"AT+CFUN=1"|"AT+CFUN=1,0")
			final OK ;;
		AT+GSN)
			info "$(getf imei 490154203237518)"; final OK ;;
		"AT+EGMR=0,7")
			info "+EGMR: \"$(getf imei 490154203237518)\""; final OK ;;
		"AT+EGMR=1,7,"*)
			v=${c#AT+EGMR=1,7,}; v=${v#\"}; v=${v%\"}
			case $v in
				*[!0-9]*|'') final ERROR ;;
				*) if [ ${#v} -eq 15 ]; then printf '%s\n' "$v" > "$S/imei"; final OK; else final ERROR; fi ;;
			esac ;;
		AT+QCCID)
			info "+QCCID: $(getf iccid 8938001234567890123)"; final OK ;;
		AT+CIMI)
			info "$(getf imsi 255031234567890)"; final OK ;;
		"AT+CPIN?")
			p=$(getf cpin READY)
			if [ "$p" = NOSIM ]; then final "+CME ERROR: 10"; else info "+CPIN: $p"; final OK; fi ;;
		AT+CSQ)
			info "+CSQ: $(getf csq 20),99"; final OK ;;
		"AT+COPS?")
			info "+COPS: 0,0,\"$(getf oper FakeTel)\",7"; final OK ;;
		"AT+CEREG?")
			info "+CEREG: 0,1"; final OK ;;
		"AT+CFUN=1,1")
			n=$(getf reboots 0); printf '%s\n' "$((n + 1))" > "$S/reboots"; final OK ;;
		*)
			final ERROR ;;
	esac
}

# Byte-wise reader: AT commands are terminated by <CR>, which `read` cannot split on.
if command -v hexdump >/dev/null 2>&1; then
	readbyte() { dd bs=1 count=1 2>/dev/null | hexdump -v -e '1/1 "%02x"'; }
else
	readbyte() { dd bs=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n\t'; }
fi

line=
while :; do
	h=$(readbyte)
	[ -z "$h" ] && exit 0
	case $h in
		0d) handle "$line"; line= ;;
		0a) ;;
		*) line="$line$(printf "\\$(printf '%03o' "0x$h")")" ;;
	esac
done
