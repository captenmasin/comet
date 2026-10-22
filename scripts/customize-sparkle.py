#!/usr/bin/env python3
"""Adjust the copied Sparkle prompt before the framework is signed."""
from pathlib import Path
import plistlib
import sys

path = Path(sys.argv[1]) / "Versions/B/Resources/Base.lproj/Sparkle.strings"
strings = plistlib.loads(path.read_bytes())
updated = {key: value.replace("available—you have", "available. You have") for key, value in strings.items()}
if updated == strings:
    raise SystemExit("Sparkle's expected update prompt was not found.")
path.write_bytes(plistlib.dumps(updated, fmt=plistlib.FMT_BINARY))
