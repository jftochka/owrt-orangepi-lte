#!/usr/bin/env python3
"""Tests for tools/quectel_usb_at.py: AT over the EG25-G's USB bulk endpoints without a kernel driver.

Run: python3 -m unittest tools/tests/test_quectel_usb_at.py
The USB layer is not exercised; a fake port scripts what the modem would answer.
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import quectel_usb_at as q  # noqa: E402


class FakePort(q.AtPort):
    """Scripted modem: every write appends the next canned answer to the read queue."""

    def __init__(self, answers):
        self.answers = list(answers)
        self.written = []
        self.queue = b""

    def write(self, data):
        self.written.append(data)
        if self.answers:
            self.queue += self.answers.pop(0)

    def read(self, timeout_ms):
        chunk, self.queue = self.queue[:64], self.queue[64:]
        if not chunk:
            raise q.ReadTimeout()
        return chunk


class Endpoint:
    def __init__(self, address, attributes):
        self.bEndpointAddress = address
        self.bmAttributes = attributes


class AtCommandTest(unittest.TestCase):
    def test_ok_response_strips_echo_and_blank_lines(self):
        port = FakePort([b"AT+CPIN?\r\r\n+CPIN: READY\r\n\r\nOK\r\n"])
        self.assertEqual(q.at_command(port, "AT+CPIN?", timeout=1.0), "+CPIN: READY\nOK")
        self.assertEqual(port.written, [b"AT+CPIN?\r"])

    def test_cme_error_is_a_final_result(self):
        port = FakePort([b"\r\n+CME ERROR: 10\r\n"])
        self.assertEqual(q.at_command(port, "AT+QCCID", timeout=1.0), "+CME ERROR: 10")

    def test_multiline_information_response(self):
        port = FakePort([b"\r\nQuectel\r\nEG25\r\nRevision: EG25GGBR07A08M2G\r\n\r\nOK\r\n"])
        self.assertEqual(q.at_command(port, "ATI", timeout=1.0),
                         "Quectel\nEG25\nRevision: EG25GGBR07A08M2G\nOK")

    def test_response_split_over_several_reads(self):
        port = FakePort([b"\r\n+QCCID: 8948010010087197546F\r\n\r\n" + b"OK\r\n"])
        self.assertEqual(q.at_command(port, "AT+QCCID", timeout=1.0), "+QCCID: 8948010010087197546F\nOK")

    def test_silence_raises_at_timeout(self):
        port = FakePort([b""])
        with self.assertRaises(q.AtTimeout):
            q.at_command(port, "AT", timeout=0.2)

    def test_final_result_detection(self):
        for line in ("OK", "ERROR", "+CME ERROR: 13", "+CMS ERROR: 500", "NO CARRIER"):
            self.assertTrue(q.is_final(line), line)
        for line in ("+CPIN: READY", "AT+CPIN?", "", "+QCCID: 1"):
            self.assertFalse(q.is_final(line), line)


class EndpointSelectionTest(unittest.TestCase):
    def test_picks_bulk_in_and_out_and_ignores_interrupt(self):
        eps = [Endpoint(0x83, 0x03), Endpoint(0x84, 0x02), Endpoint(0x03, 0x02)]
        self.assertEqual(q.pick_bulk_endpoints(eps), (0x84, 0x03))

    def test_missing_bulk_endpoint_is_an_error(self):
        with self.assertRaises(q.UsbLayout):
            q.pick_bulk_endpoints([Endpoint(0x83, 0x03), Endpoint(0x84, 0x02)])


if __name__ == "__main__":
    unittest.main()
