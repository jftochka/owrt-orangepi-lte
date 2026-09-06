#!/bin/sh
# Runs ON THE ROUTER (pipe it: tools/rt - < tools/02-install.sh).
# Installs LuCI, the QMI modem stack, AT tools, TUI deps, tailscale and the 4IceG modem apps.
set -e

echo "== apk update"
apk update

echo "== web UI"
apk add luci luci-ssl

echo "== EG25-G QMI stack"
apk add kmod-usb-net-qmi-wwan kmod-usb-serial-option uqmi luci-proto-qmi

echo "== AT / SMS / TUI / web terminal"
apk add sms-tool socat whiptail ttyd luci-app-ttyd

echo "== tailscale"
apk add tailscale kmod-tun luci-app-tailscale-community

echo "== eSIM (lpac), jq, GNU timeout/sleep (BusyBox lacks timeout and fractional sleep)"
apk add lpac jq coreutils-timeout coreutils-sleep

echo "== 4IceG modem apps (unsigned, from GitHub releases)"
# luci-app-modemband is not here: its `modemband` dependency is missing from the 25.12.1
# feeds, so both come from the 4IceG signed apk repository instead (tools/05-modemband.sh).
mkdir -p /tmp/4iceg && cd /tmp/4iceg
for u in \
	https://github.com/4IceG/luci-app-3ginfo-lite/releases/download/1.0.77-r20260215/luci-app-3ginfo-lite-1.0.77-r20260215.apk \
	https://github.com/4IceG/luci-app-sms-tool-js/releases/download/2.0.42-r20260831/luci-app-sms-tool-js-2.0.42-r20260831.apk \
	; do
	f=${u##*/}
	[ -s "$f" ] || wget -q -O "$f" "$u" || { echo "download failed: $u"; rm -f "$f"; }
done
ls -la /tmp/4iceg
for f in /tmp/4iceg/*.apk; do
	[ -s "$f" ] || continue
	apk add --allow-untrusted "$f" || echo "WARN: $f did not install (missing dependency?)"
done

echo "== device nodes"
ls -la /dev/ttyUSB* /dev/cdc-wdm* 2>/dev/null || echo "no modem device nodes yet (driver just loaded, replug or wait)"
echo "== done"
