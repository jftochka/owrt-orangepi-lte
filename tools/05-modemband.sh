#!/bin/sh
# Runs ON THE ROUTER (pipe it: tools/rt - < tools/05-modemband.sh).
# Installs modemband and luci-app-modemband from the 4IceG signed apk repository.
#
# Why: the OpenWrt 25.12.1 feeds carry no `modemband` package, so the luci-app-modemband
# apk from GitHub releases fails with "modemband (no such package)" (SFT-141). The upstream
# source is obsy/modemband (shell only, depends on sms-tool); 4IceG publishes prebuilt,
# signed apks for both packages in Modem-extras-apk/myapk together with packages.adb and
# the public key, i.e. a proper apk repository. Idempotent: safe to run again.
set -e

REPO_URL=https://github.com/4IceG/Modem-extras-apk/raw/refs/heads/main/myapk
LIST=/etc/apk/repositories.d/4iceg.list
KEY=/etc/apk/keys/IceG-apkpub.pem

echo "== 4IceG apk repository"
if [ -f "$LIST" ] && grep -qF "$REPO_URL/packages.adb" "$LIST"; then
	echo "repository list already present: $LIST"
else
	printf '%s\n' "$REPO_URL/packages.adb" > "$LIST"
	echo "wrote $LIST"
fi
if [ -s "$KEY" ]; then
	echo "signing key already present: $KEY"
else
	wget -q -O "$KEY" "$REPO_URL/IceG-apkpub.pem"
	echo "fetched $KEY"
fi

echo "== apk update"
apk update

echo "== modemband + luci-app-modemband"
apk add modemband luci-app-modemband

echo "== installed"
apk list --installed modemband luci-app-modemband
ls -la /usr/bin/modemband.sh /usr/share/modemband/2c7c0125

echo "== EG25-G band list (talks to /dev/ttyUSB2 through sms_tool, like luci-app-sms-tool-js)"
modemband.sh getbands || echo "getbands failed: modem absent or /dev/ttyUSB2 busy"
echo "== done"
