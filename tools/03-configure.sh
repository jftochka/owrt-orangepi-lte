#!/bin/sh
# Runs ON THE ROUTER (tools/rt - < tools/03-configure.sh), after 02-install.sh and after the
# simei tree was pushed to / (tools/rt push simei/. /).
# Configures: wwan (QMI), firewall, LuCI/uhttpd, ttyd web TUI, 4IceG apps' AT port, atbridge, tailscale.
set -e
APN=${APN:-internet}

echo "== wwan (QMI) interface"
uci -q delete network.wwan || true
uci set network.wwan=interface
uci set network.wwan.proto='qmi'
uci set network.wwan.device='/dev/cdc-wdm0'
uci set network.wwan.apn="$APN"
uci set network.wwan.auth='none'
uci set network.wwan.pdptype='ipv4'
uci set network.wwan.metric='20'   # home LAN preferred while the board is a DHCP client there
uci set network.lan.metric='10'
uci set network.lan.hostname='orangepi-lte'
uci commit network

echo "== firewall: wwan in zone wan, tailscale in zone lan"
wan_zone=$(uci show firewall | sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='wan'$/\1/p" | head -1)
lan_zone=$(uci show firewall | sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='lan'$/\1/p" | head -1)
uci -q del_list "firewall.$wan_zone.network=wwan" || true
uci add_list "firewall.$wan_zone.network=wwan"
uci -q delete network.tailscale || true
uci set network.tailscale=interface
uci set network.tailscale.proto='none'
uci set network.tailscale.device='tailscale0'
uci commit network
uci -q del_list "firewall.$lan_zone.network=tailscale" || true
uci add_list "firewall.$lan_zone.network=tailscale"
uci commit firewall

echo "== uhttpd: keep plain http reachable (the web TUI iframe needs the same scheme)"
uci set uhttpd.main.redirect_https='0'
uci commit uhttpd

echo "== ttyd: web TUI (7681 -> simei) and web shell (7682); bound to all interfaces (a DHCP address change would
strand an interface-bound instance), the firewall keeps them LAN-only"
uci -q delete ttyd.simei || true
uci set ttyd.simei=ttyd
uci set ttyd.simei.port='7681'
uci set ttyd.simei.command='/usr/sbin/simei'
uci set ttyd.simei.ssl='0'
uci set ttyd.simei.writable='1'
uci -q delete ttyd.shell || true
uci set ttyd.shell=ttyd
uci set ttyd.shell.port='7682'
uci set ttyd.shell.command='/bin/login -f root'
uci set ttyd.shell.ssl='0'
uci set ttyd.shell.writable='1'
# the package's default anonymous instance would also grab a port; disable it
for s in $(uci show ttyd | sed -n "s/^ttyd\.\(@ttyd\[[0-9]*\]\)=ttyd$/\1/p"); do uci set "ttyd.$s.enable=0" || true; done
uci commit ttyd

echo "== 4IceG apps: AT port /dev/ttyUSB2"
if [ -f /etc/config/3ginfo ]; then
	uci set 3ginfo.@3ginfo[0].device='/dev/ttyUSB2' 2>/dev/null || true
	uci commit 3ginfo
fi
if [ -f /etc/config/sms_tool_js ]; then
	uci set sms_tool_js.@sms_tool_js[0].readport='/dev/ttyUSB2' 2>/dev/null || true
	uci set sms_tool_js.@sms_tool_js[0].sendport='/dev/ttyUSB2' 2>/dev/null || true
	uci set sms_tool_js.@sms_tool_js[0].ussdport='/dev/ttyUSB2' 2>/dev/null || true
	uci set sms_tool_js.@sms_tool_js[0].atport='/dev/ttyUSB2' 2>/dev/null || true
	uci commit sms_tool_js
fi
if [ -f /etc/config/modemband ]; then
	uci set modemband.@modemband[0].set_port='/dev/ttyUSB2' 2>/dev/null || true
	uci commit modemband
fi

echo "== simei / atbridge"
chown -R root:root /usr/sbin/simei /etc/init.d/atbridge /etc/hotplug.d/tty/90-simei /etc/config/simei /usr/share/luci/menu.d/luci-app-simei.json /usr/share/rpcd/acl.d/luci-app-simei.json /www/luci-static/resources/view/simei /tests 2>/dev/null || true
chmod +x /usr/sbin/simei /etc/init.d/atbridge /etc/hotplug.d/tty/90-simei /tests/run.sh /tests/fake_modem.sh /tests/uci-shim/uci 2>/dev/null || true
[ -d /usr/lib/simei ] || mkdir -p /usr/lib/simei
[ -d /tests ] && { rm -rf /usr/lib/simei/tests; mv /tests /usr/lib/simei/tests; }
/etc/init.d/atbridge enable
/etc/init.d/atbridge restart

echo "== services"
/etc/init.d/firewall reload >/dev/null 2>&1 || true
/etc/init.d/network reload
/etc/init.d/ttyd enable; /etc/init.d/ttyd restart
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
/etc/init.d/tailscale enable; /etc/init.d/tailscale start || true
sleep 4
ifup wwan || true

echo "== state"
ls -la /dev/ttyUSB* /dev/cdc-wdm* 2>/dev/null || true
netstat -ltn 2>/dev/null | grep -E ':(80|443|5000|7681|7682) ' || true
echo "== done"

echo "== lpac: AT backend on the modem's second AT port (the uqmi backend of lpac 2.3.0 fails on this build)"
uci set lpac.global.apdu_backend='at'
uci set lpac.at.device='/dev/ttyUSB3'
uci commit lpac
