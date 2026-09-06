# Draft: openwrt/packages issue for the lpac uqmi driver (SFT-142)

Ready to paste into a new issue at https://github.com/openwrt/packages/issues. Not filed yet.

---

**Title:** lpac: uqmi APDU driver reads LPAC_QMI_DEV, but the lpac wrapper exports LPAC_APDU_QMI_DEVICE (euicc_init always fails)

**Package:** utils/lpac 2.3.0-r1 (openwrt-25.12), OpenWrt 25.12.1, aarch64_cortex-a53 (xunlong_orangepi-zero3), Quectel EG25-G in QMI mode, uqmi 2025.07.30~7914da43-r2.

**Problem**

With the package default `apdu_backend=uqmi`, every command fails:

```
# lpac chip info
sh: syntax error: unexpected "("
{"type":"lpa","payload":{"code":-1,"message":"euicc_init","data":""}}
```

**Cause**

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

**Fix**

Either export `LPAC_QMI_DEV` / `LPAC_QMI_DEBUG` in `files/lpac.sh` for the uqmi backend, or
make the patch read `LPAC_APDU_QMI_DEVICE` / `LPAC_APDU_UQMI_DEBUG` like the other backends
(the AT backend uses `LPAC_APDU_AT_DEVICE`, MBIM uses `LPAC_APDU_MBIM_DEVICE`). Exporting both
names in the wrapper is the smallest change.
