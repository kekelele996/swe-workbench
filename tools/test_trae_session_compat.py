#!/usr/bin/env python3
"""Regression coverage for Trae CN 3.4.11's 15-digit session identity."""

import importlib.util
from pathlib import Path
import unittest


TOOLS = Path(__file__).resolve().parent
SHORT_TOKEN = (
    "a" * 15
    + ":"
    + "b" * 32
    + "_"
    + "c" * 24
    + "."
    + "d" * 24
    + "."
    + "e" * 24
    + ":TRAE CN.3.4.11.no_sid.no_ppe.T(2026/11/1 20:45:39)"
)


def load_tool(name):
    spec = importlib.util.spec_from_file_location(name, TOOLS / f"{name}.py")
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {name}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TraeSessionCompatTests(unittest.TestCase):
    def test_capture_accepts_15_digit_identity(self):
        capture = load_tool("capture_trae_session")
        self.assertIsNotNone(capture.TOKEN.fullmatch(SHORT_TOKEN))
        self.assertIsNone(capture.TOKEN.fullmatch("a" * 14 + SHORT_TOKEN[15:]))

    def test_export_redaction_accepts_15_digit_identity(self):
        collector = load_tool("collect_trae_export")
        self.assertEqual(collector.SESSION_TOKEN.sub("[session redacted]", SHORT_TOKEN), "[session redacted]")

    def test_terminal_redaction_accepts_15_digit_identity(self):
        evidence = load_tool("native_terminal_evidence")
        self.assertEqual(evidence.redact(SHORT_TOKEN), "[REDACTED TRAE TOKEN]")


if __name__ == "__main__":
    unittest.main()
