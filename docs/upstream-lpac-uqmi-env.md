# Draft: openwrt/packages issue for the lpac uqmi driver (SFT-142)

Ready to paste into a new issue at https://github.com/openwrt/packages/issues. Not filed yet.

---

**Title:** lpac: uqmi APDU driver reads `LPAC_QMI_DEV` while the wrapper exports
`LPAC_APDU_QMI_DEVICE`, and it opens its UIM client on a hardcoded `/dev/cdc-wdm0`

**Package:** utils/lpac 2.3.0-r1 (openwrt-25.12), OpenWrt 25.12.1, aarch64_cortex-a53
(xunlong_orangepi-zero3), Quectel EG25-G in QMI mode, uqmi 2025.07.30~7914da43-r2.

**Problem**

With the package default `apdu_backend=uqmi`, every command fails:

```
# lpac chip info
sh: syntax error: unexpected "("
{"type":"lpa","payload":{"code":-1,"message":"euicc_init","data":""}}
```

**1. The wrapper and the driver use different variable names**

`patches/0001-driver-add-uqmi-backend.patch` reads the device path and the debug flag with

```c
devpath = getenv("LPAC_QMI_DEV");
char *debug_str = getenv("LPAC_QMI_DEBUG");
```

while `files/lpac.sh` (installed as `/usr/bin/lpac`) exports

```sh
export LPAC_APDU_QMI_DEVICE="$UQMI_DEV"
export LPAC_APDU_UQMI_DEBUG="$UQMI_DEBUG"
```

`devpath` is therefore NULL and the driver builds `uqmi -s -d (null) --get-client-id uim`
with `snprintf`, which the shell rejects (`unexpected "("`), so `euicc_init` fails before any
QMI traffic.

**Check**

Setting the variable the driver expects gets past the error and reaches the modem:

```
# LPAC_APDU=uqmi LPAC_QMI_DEV=/dev/cdc-wdm0 LPAC_QMI_DEBUG=1 /usr/lib/lpac chip info
UQMI_DEBUG_TX: uqmi -s -d /dev/cdc-wdm0 --get-client-id uim
UQMI_DEBUG_RX: 2
UQMI_DEBUG_TX: --set-client-id uim,2 --keep-client-id uim --uim-slot 1 --uim-channel-open A0000005591010FFFFFFFF8900000100
...
```

**2. `uqmi_open_client()` passes a full command line where an argument list is expected**

`uqmi_execute_command()` prefixes every command with `uqmi -s -d <devpath>`:

```c
snprintf(final_command, sizeof(final_command), "uqmi -s -d %s %s", devpath, command);
```

but the connect path hands it another complete command line, with the device hardcoded:

```c
ret = uqmi_execute_command("uqmi -s -d /dev/cdc-wdm0 --get-client-id uim", buffer, sizeof(buffer));
```

so the process actually run is

```
uqmi -s -d <devpath> uqmi -s -d /dev/cdc-wdm0 --get-client-id uim
```

This only works because option parsing permutes the arguments, the later `-d` wins and the
stray `uqmi` operand is ignored. Two consequences:

* on a system where the QMI device is not `/dev/cdc-wdm0` (a second modem, `cdc-wdm1`), the
  UIM client is opened on `/dev/cdc-wdm0` while every later command uses `devpath` - the
  client id does not belong to the device it is used on;
* the debug output prints `command`, not `final_command`, so the doubled line never shows up
  in `LPAC_QMI_DEBUG=1` output.

The intended call is `uqmi_execute_command("--get-client-id uim", buffer, sizeof(buffer))`.

**3. Smaller issues in the same file**

* `devpath` is interpolated into a `popen()` command line without quoting; any device path
  containing shell metacharacters (or the `(null)` above) is handed to `/bin/sh` as syntax.
* `apdu_interface_connect()` declares `const char *device;` and never uses it.
* `apdu_interface_connect()` does not check `devpath` for NULL before using it.

**Fix**

For 1, either export `LPAC_QMI_DEV` / `LPAC_QMI_DEBUG` in `files/lpac.sh` for the uqmi backend,
or make the patch read `LPAC_APDU_QMI_DEVICE` / `LPAC_APDU_UQMI_DEBUG` like the other backends
(the AT backend uses `LPAC_APDU_AT_DEVICE`, MBIM uses `LPAC_APDU_MBIM_DEVICE`). Exporting both
names in the wrapper is the smallest change. For 2, drop the `uqmi -s -d /dev/cdc-wdm0` prefix
from the string passed by `uqmi_open_client()`. For 3, refuse to run when `devpath` is NULL and
reject a device path that is not a plain path.

**Workaround in the meantime**

Call `/usr/lib/lpac` directly (not the `/usr/bin/lpac` wrapper, which re-exports the UCI
section) with both spellings set:

```sh
LPAC_APDU=uqmi LPAC_APDU_QMI_DEVICE=/dev/cdc-wdm0 LPAC_QMI_DEV=/dev/cdc-wdm0 /usr/lib/lpac chip info
```
