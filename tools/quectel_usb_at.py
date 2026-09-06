#!/usr/bin/env python3
"""AT commands to a Quectel EG25-G over USB without a kernel driver.

macOS has no driver for the module's vendor-class serial interfaces, but a user-space program
may claim any interface no kernel driver owns. The AT port is interface 2 of the QMI
composition (0 DM, 1 NMEA, 2 AT, 3 modem/PPP, 4 QMI; the same order the Linux option driver
uses for ttyUSB0..3): one bulk IN and one bulk OUT endpoint, plus an interrupt endpoint that is
not needed. Like the Linux usb_wwan driver, DTR/RTS are asserted with a CDC
SET_CONTROL_LINE_STATE request before talking.

Usage (pyusb lives in the ~/.venvs/quectel venv, libusb comes from Homebrew):
    ~/.venvs/quectel/bin/python tools/quectel_usb_at.py 'AT+CPIN?' 'AT+QCCID'
    ~/.venvs/quectel/bin/python tools/quectel_usb_at.py --list          # interfaces and endpoints
Options: --iface N (default 2), --timeout SECONDS (default 5), --vid/--pid (default 2c7c:0125).
Tests: python3 -m unittest tools/tests/test_quectel_usb_at.py
"""
import argparse
import sys
import time

VID, PID = 0x2C7C, 0x0125
AT_INTERFACE = 2


class AtError(Exception):
    pass


class AtTimeout(AtError):
    pass


class UsbLayout(AtError):
    pass


class ReadTimeout(Exception):
    """A read returned nothing within its timeout (normal between response chunks)."""


class AtPort:
    def write(self, data):
        raise NotImplementedError

    def read(self, timeout_ms):
        raise NotImplementedError

    def close(self):
        pass


def is_final(line):
    """True for a final result code line of an AT response."""
    line = line.strip()
    if line in ("OK", "ERROR", "NO CARRIER", "COMMAND NOT SUPPORT"):
        return True
    return line.startswith("+CME ERROR") or line.startswith("+CMS ERROR")


def at_command(port, cmd, timeout=5.0):
    """Send one AT command, return the response lines (echo and blank lines dropped) joined by
    newlines, the final result code last. Raises AtTimeout when no final result arrives."""
    port.write(cmd.encode("ascii") + b"\r")
    buf = b""
    deadline = time.monotonic() + timeout
    while True:
        try:
            buf += port.read(200)
        except ReadTimeout:
            pass
        lines = buf.replace(b"\r", b"").split(b"\n")[:-1]  # the last element is partial or empty
        text = [l.decode("utf-8", "replace").strip() for l in lines]
        text = [l for l in text if l and l != cmd]
        if text and is_final(text[-1]):
            return "\n".join(text)
        if time.monotonic() > deadline:
            raise AtTimeout("no final result for %r within %.1fs; received %r" % (cmd, timeout, text))


def pick_bulk_endpoints(endpoints):
    """(bulk IN address, bulk OUT address) of an interface; interrupt endpoints are ignored."""
    ep_in = ep_out = None
    for ep in endpoints:
        if ep.bmAttributes & 0x03 != 0x02:
            continue
        if ep.bEndpointAddress & 0x80:
            ep_in = ep_in or ep.bEndpointAddress
        else:
            ep_out = ep_out or ep.bEndpointAddress
    if ep_in is None or ep_out is None:
        raise UsbLayout("interface has no bulk IN/OUT pair (in=%r out=%r)" % (ep_in, ep_out))
    return ep_in, ep_out


class UsbAtPort(AtPort):
    def __init__(self, iface=AT_INTERFACE, vid=VID, pid=PID):
        import usb.core
        import usb.util
        self.usb_core, self.usb_util = usb.core, usb.util
        dev = usb.core.find(idVendor=vid, idProduct=pid)
        if dev is None:
            raise UsbLayout("no USB device %04x:%04x" % (vid, pid))
        try:
            cfg = dev.get_active_configuration()
        except usb.core.USBError:
            dev.set_configuration()
            cfg = dev.get_active_configuration()
        try:
            intf = cfg[(iface, 0)]
        except (KeyError, IndexError):
            raise UsbLayout("device has no interface %d" % iface)
        self.ep_in, self.ep_out = pick_bulk_endpoints(list(intf))
        usb.util.claim_interface(dev, iface)
        try:  # DTR|RTS, as usb_wwan_send_setup() does in Linux
            dev.ctrl_transfer(0x21, 0x22, 0x03, iface, None, 1000)
        except usb.core.USBError:
            pass
        self.dev, self.iface = dev, iface

    def write(self, data):
        self.dev.write(self.ep_out, data, 2000)

    def read(self, timeout_ms):
        try:
            return bytes(self.dev.read(self.ep_in, 4096, timeout_ms))
        except self.usb_core.USBTimeoutError:
            raise ReadTimeout()

    def close(self):
        try:
            self.usb_util.release_interface(self.dev, self.iface)
        finally:
            self.usb_util.dispose_resources(self.dev)


def list_device(vid, pid):
    import usb.core
    dev = usb.core.find(idVendor=vid, idProduct=pid)
    if dev is None:
        print("no USB device %04x:%04x" % (vid, pid))
        return 1
    print("%04x:%04x %s %s" % (vid, pid, dev.manufacturer, dev.product))
    for cfg in dev:
        print("configuration %d" % cfg.bConfigurationValue)
        for intf in cfg:
            eps = ", ".join("%s 0x%02x" % ({2: "bulk", 3: "intr"}.get(ep.bmAttributes & 3, "ep"),
                                             ep.bEndpointAddress) for ep in intf)
            print("  interface %d class 0x%02x/0x%02x/0x%02x: %s" % (
                intf.bInterfaceNumber, intf.bInterfaceClass, intf.bInterfaceSubClass,
                intf.bInterfaceProtocol, eps))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="AT over USB to a Quectel EG25-G (no kernel driver needed)")
    ap.add_argument("commands", nargs="*", help="AT commands, e.g. 'AT+CPIN?'")
    ap.add_argument("--iface", type=int, default=AT_INTERFACE)
    ap.add_argument("--timeout", type=float, default=5.0)
    ap.add_argument("--vid", type=lambda s: int(s, 16), default=VID)
    ap.add_argument("--pid", type=lambda s: int(s, 16), default=PID)
    ap.add_argument("--list", action="store_true", help="print interfaces and endpoints, then exit")
    args = ap.parse_args(argv)
    if args.list:
        return list_device(args.vid, args.pid)
    if not args.commands:
        ap.error("give at least one AT command or --list")
    try:
        port = UsbAtPort(args.iface, args.vid, args.pid)
    except AtError as e:
        print("quectel_usb_at: %s" % e, file=sys.stderr)
        return 2
    rc = 0
    try:
        for cmd in args.commands:
            try:
                print(at_command(port, cmd, args.timeout))
            except AtTimeout as e:
                print("quectel_usb_at: %s" % e, file=sys.stderr)
                rc = 1
    finally:
        port.close()
    return rc


if __name__ == "__main__":
    sys.exit(main())
