#!/usr/bin/env python3
"""Run the desktop Ting harness test suite."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path


def main():
    harness_dir = Path(__file__).resolve().parent
    if str(harness_dir) not in sys.path:
        sys.path.insert(0, str(harness_dir))

    suite = unittest.defaultTestLoader.discover(str(harness_dir), pattern="test_*.py")
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if result.wasSuccessful():
        print("PASS: {} tests".format(result.testsRun))
        return 0
    print(
        "FAIL: {} tests, {} failures, {} errors".format(
            result.testsRun,
            len(result.failures),
            len(result.errors),
        )
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
