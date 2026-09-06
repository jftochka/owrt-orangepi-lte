# OrangePi Zero3 LTE router (OpenWrt 25.12.1, Quectel EG25-G, eUICC)

Bring-up tooling, the `simei` SIM / eSIM / IMEI manager (TUI + CLI + web TUI) and its
tests for an OrangePi Zero3 running the official OpenWrt 25.12.1 image with a Quectel
EG25-G LTE modem. The modem carries a Kigen eUICC (embedded SIM) instead of a removable
SIM; eSIM profiles are managed with `lpac`.

Changing an IMEI is illegal in some countries. This tool writes whatever IMEI you assign
to a SIM profile into your own modem; the responsibility is yours.

## What is on the board

| Component | Where |
|---|---|
| LuCI web UI | `http://<router-ip>/` (also https), login `root`, empty password until you set one |
| Web TUI (simei in the browser) | LuCI > Modem > SIM / IMEI (TUI), or `http://<router-ip>:7681/` |
| Web shell | `http://<router-ip>:7682/` |
| ssh | `ssh root@<router-ip>` (keys of the Mac and of the phone are installed), `ssh root@orangepi-lte` over Tailscale |
| Raw AT port over TCP | `socat - TCP:<router-ip>:5000` then type `AT+GSN` (service `atbridge`, /dev/ttyUSB2) |
| Modem pages (4IceG) | LuCI > Modem > 3ginfo-lite (signal, band, cell), SMS tool (SMS, USSD, AT) |
| LTE WAN | interface `wwan`, proto qmi, `/dev/cdc-wdm0`, APN `internet`, metric 20 (LAN metric 10) |
| Tailscale | node `orangepi-lte`, Tailscale SSH enabled |

The board joins the home LAN as a DHCP client (`br-lan`, hostname `orangepi-lte`); the
current address is in `tools/router.env` after bootstrap. `tools/rt` and `tools/serial.sh`
are the two ways to reach it from the Mac.

## simei

`simei` keeps one profile per SIM (keyed by ICCID) with the IMEI that must be used with
that SIM, and writes the IMEI into the modem (`AT+EGMR=1,7`) when that SIM is active. With
the eUICC, "changing the SIM" means enabling another eSIM profile; `simei switch` does both
steps.

```
simei                          TUI (whiptail; plain menus on a dumb console)
simei status [--raw]           IMEI, ICCID, IMSI, SIM state, signal, operator, registration, matched profile
simei live [--once]            live dashboard: bandwidth (1 s), signal (uqmi), no AT round trips
simei list                     SIM profiles (id, name, ICCID, IMEI, APN)
simei register [name]          create a profile for the SIM the modem sees now
simei add <name> <iccid> [imei] [apn]
simei set <profile> name|imei|apn|iccid <value>      14-digit IMEI gets its check digit appended
simei delete <profile>
simei move <from> <to>         hand the IMEI of one SIM profile to another
simei swap <a> <b>             exchange the IMEIs of two profiles
simei apply [--yes] [--dry-run]  write the active SIM's profile IMEI into the modem, restart it, verify
simei switch <iccid|profile> [--yes]  enable that eSIM profile, restart the modem, apply its IMEI
simei esim [list]              eSIM profiles on the eUICC with the IMEI assigned to each
simei esim info                EID, free memory, default SM-DP+
simei esim enable|disable <iccid>
simei esim delete <iccid> [--yes]
simei esim nickname <iccid> <name>
simei esim download 'LPA:1$smdp$matching-id' [confirmation-code]
simei at "AT+..."              raw AT command through the bridge
simei luhn <14|15 digits>      compute or verify an IMEI check digit
simei restart modem|wwan|bridge
```

Typical flows:

- First SIM: `simei register "DENT"` (the profile is created; if the modem's IMEI is blank
  or invalid it is not stored), then `simei set sim1 imei 35xxxxxxxxxxxxx`, then
  `simei apply`.
- Second eSIM: `simei esim download 'LPA:1$...'`, `simei add "Work" <iccid> <imei>`, then
  `simei switch <iccid>` whenever you want to use it. Switching back: `simei switch sim1`.
- Move the IMEI to another SIM: `simei move sim1 sim2` then `simei switch sim2`.

Exit codes of `apply` / `switch`: 0 ok or nothing to do, 1 cancelled or usage, 2 IMEI fails the
check, 3 no SIM / no profile / no IMEI assigned, 4 modem refused or did not come back, 5 modem or
lpac unreachable. The original IMEI is saved once to `/etc/simei.factory-imei` (never a blank one).

Configuration: `/etc/config/simei` (`global`: `at_host`, `at_port`, `tty`, `qmi_dev`,
`wwan_iface`, `wwan_dev`, `esim_backend` at|uqmi, `esim_tty`, `auto_apply`; one `profile`
section per SIM). `auto_apply 1` makes `/etc/hotplug.d/tty/90-simei` run `simei apply --yes`
whenever the modem's AT port re-appears.

Modem facts used here: `AT+EGMR=0,7` / `AT+GSN` read the IMEI, `AT+EGMR=1,7,"<imei>"` writes
it, `AT+CFUN=1,1` restarts the modem, `AT+QCCID` returns the ICCID with a trailing filler `F`
(stripped), `AT+QCFG="usbnet",0` puts the EG25-G into QMI mode (it was in ECM mode, 1).
lpac talks to the eUICC over the second AT port `/dev/ttyUSB3` (echo off first).

## Tools (run on the Mac)

```
tools/serial.sh console | run [-w SEC] "cmd" | status     socat serial console (picocom must be closed)
tools/01-bootstrap-net.sh   over serial: br-lan -> DHCP client, install ssh keys, write tools/router.env
tools/rt "cmd" | rt - < script | rt push DIR DEST | rt shell   ssh helper (tar over ssh for push)
tools/rt - < tools/02-install.sh     packages (luci, luci-ssl, qmi stack, sms-tool, socat, whiptail,
                                     ttyd, tailscale, lpac, jq, coreutils-timeout/sleep, 4IceG apps)
tools/rt push simei /                install / update simei on the board
tools/rt - < tools/03-configure.sh   wwan, firewall, ttyd (7681 simei, 7682 shell), lpac, atbridge
tools/rt - < tools/04-tailscale.sh   tailscale up --ssh (prints the login URL once)
```

Keys: the Mac key `~/.ssh/id_ed25519.pub` and the phone key `~/.ssh/orangepi_phone_ed25519`
(private key to import into the phone's ssh client; public part `.pub`) are in
`/etc/dropbear/authorized_keys` on the board.

## Tests

```
sh simei/tests/run.sh                 on the Mac (needs socat and jq; uses tests/uci-shim)
TEST_SH=dash sh simei/tests/run.sh    same under dash
ssh root@<router-ip> 'sh /usr/lib/simei/tests/run.sh'   on the board (real uci)
```

`fake_modem.sh` emulates the EG25-G AT responses (IMEI read/write, CFUN restart, CCID, CSQ,
COPS, CEREG); `fake_lpac.sh` emulates lpac and records the environment it is called with.
82 checks cover Luhn, status parsing, profiles, move/swap, apply (incl. refusal paths and the
blank-IMEI case), the live dashboard frame, the eSIM commands and the lpac backend environment,
`switch`, and the text TUI.

## Known limits

- `modemband` is not in the 25.12 feeds; `modemband` and `luci-app-modemband` come from the
  4IceG signed apk repository instead (`tools/05-modemband.sh`). Band locking also works with
  `AT+QCFG="band",...` from `simei at` or the SMS tool's AT page.
- lpac 2.3.0's uqmi backend fails (`euicc_init`) through the stock wrapper: the OpenWrt feed's
  uqmi driver reads `LPAC_QMI_DEV`, which `/usr/bin/lpac` never sets. simei exports it, but the
  AT backend stays the default until the uqmi path is verified with a readable eUICC (SFT-142).
- The LTE link with the current (blank) IMEI registers but did not pass traffic; LAN is the
  preferred default route until an IMEI is assigned and the link verified.
- The web TUI iframe needs LuCI over plain http (mixed content); the page shows a direct link
  when LuCI is opened over https.

## Project handoff

The [September 6 handoff](docs/handoff-2026-09-06.md) records the repository baseline,
last known device state, current Linear work queue, and verification limits.
