#!/usr/bin/env python3
"""Build public archives without pairing configuration or diagnostic logs."""
from pathlib import Path
from configure import package
ROOT=Path(__file__).resolve().parents[1]
output=ROOT/'build/release'
output.mkdir(parents=True,exist_ok=True)
package(output/'MonitorSwitch-Windows-0.10.0-test1.zip')
print(output/'MonitorSwitch-Windows-0.10.0-test1.zip')
