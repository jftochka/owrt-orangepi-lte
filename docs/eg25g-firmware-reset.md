# EG25-G: reset and reflash options (research, 2026-09-06)

Context: after a power loss the modem lost NV settings (USB mode fell back to ECM, IMEI read as
000000000000000) and stopped reading any card in its SIM holder. Firmware on the board:
`EG25GGBR07A08M2G_01.002.01.002` (`AT+QGMR`), boot loader `SBLR07EG25G01_1`, USB 2c7c:0125,
four `option` ports (ttyUSB0 = DM/diag, ttyUSB2/3 = AT). The modem is a micro-USB board with
the SIM holder on it.

## What each "reset" actually covers

| Step | Command / tool | Resets | Keeps | Done here |
| --- | --- | --- | --- | --- |
| AT profile | `AT&F` | AT parameters (echo, S-registers, some `AT+Q...` settings listed in the AT manual as "restorable with AT&F") | NV, EFS, IMEI, firmware | no (harmless, useless for SIM detection) |
| NV restore | `AT+QPRTPARA=3` then `AT+CFUN=1,1` (`=4` shows backup/restore counts, `=1` makes a new backup) | NV items from the module's own backup: brought the factory IMEI 867698046226489 back | EFS files, firmware | yes, 2026-09-06 |
| Modem restart | `AT+CFUN=1,1` (or `AT+CFUN=0` / `AT+CFUN=1`) | runtime state, re-reads the SIM | everything | many times |
| Hardware reset | RESET_N low 150-460 ms (Hardware Design, "Reset the module"); on a USB board this is a power cycle | runtime state | everything | yes (board power cycles) |
| Firmware reflash, update package | QFirehose in EDL mode with a stock package (`update/firehose/prog_nand_firehose_9x07.mbn`, `rawprogram_nand_p4K_b256K_update.xml`, `partition_nand.xml`, images) | boot, modem and system images | EFS (user NV items, calibration references), per Quectel forum "some settings are preserved after flashing"; the community recovery packages do not wipe EFS | no |
| Full factory image with EFS erase | only in Quectel's factory production packages, not in the recovery packages | everything including calibration data if present in the package | - | no, and not recommended |

Conclusion for the SIM problem: the module's SIM state machine works (it powers the holder at
1.8 V, then 3.0 V, gets no answer and reports "SIM not inserted" for two different cards, on both
`AT+QDSIM` interfaces, with `sim/onchip 0`, `sim/clk_freq 0`, forced `AT+QSIMVOL` 1 and 2).
The Quectel forum case with the same symptom set (EG25-GC, USIM_VDD 1.8 V then 3.0 V then 0 V,
no ATR, every AT command tried including `AT+QPRTPARA` and `AT&F`) ends with the carrier board's
SIM socket/wiring as the fault, not the module. A reflash therefore has a low chance of fixing it;
the holder (bent or shorted spring contact, debris, broken trace) has a high one.

## Reflash procedure on this router, if wanted

1. Packages (4IceG signed repository is already configured, see tools/05-modemband.sh):
   `apk add qfirehose luci-app-qfirehose` (qfirehose 1.5.1, LuCI app 2.1.0).
2. Firmware package: stock recovery packages are mirrored at
   https://github.com/Biktorgj/quectel_eg25_recovery (PinePhone community), one branch per version:
   `EG25GGBR07A08M2G_01.002.01.002` (the version on this board: a same-version flash is the
   "firmware reset"), `_01.003.01.003`, `_30.004.30.004`, `_30.007.30.007`, `_30.200.30.200`,
   `_30.202.30.202`, `_30.203.30.203`, `_30.206.30.206`, plus older A07 builds. The official
   route is a request on forums.quectel.com or to the module vendor.
   Put the package under `/tmp` (1.9 GB tmpfs; the overlay has 30 MB free). It must contain
   `update/firehose/`.
3. Flash: LuCI > Modem > QFirehose, choose the package directory and the modem's USB port, Flash;
   or on the shell `qfirehose -f /tmp/<package>`. QFirehose switches the modem to EDL through the
   DM port itself, flashes, and the modem reboots after about 30 s.
4. Afterwards: the hotplug guard re-applies QMI mode if the modem comes back in ECM mode;
   check `simei usbmode`, `AT+QGMR`, `AT+GSN`, `AT+CPIN?`.

Risks: if QFirehose fails half-way the modem may stay in EDL and need the EDL test points,
which are not reachable on a sealed USB board; the flash also reverts the USB composition and
may reset `AT+QCFG` items. Stop ModemManager-like services first (none on this router; the AT
bridge and netifd's qmi handler should be stopped: `/etc/init.d/atbridge stop; ifdown wwan`).

## Sources

- Biktorgj/quectel_eg25_recovery: README, branches, install.sh (QFirehose -f, no EFS wipe)
- Quectel forum 23017 "Reset various settings to factory state for EG25-G" (settings persist across flashes, no factory-reset command given)
- Quectel forum 58620 "EG25-GC Mini PCIe SIM not detected - USIM_VDD drops to 0V after 1.8V/3.0V attempt" (same symptom; carrier board SIM wiring/socket)
- Quectel forum 27257 "Latest firmware for EG25G (EG25GGBR07A08M2G)"
- Quectel "LTE&5G QFirehose Linux&Android User Guide"
- 4IceG/luci-app-qfirehose README (Modem > QFirehose)
