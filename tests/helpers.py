"""Shared helpers for the Nanachi tests: locating the firmware image and building small synthetic data."""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(ROOT, "tools"))

# The generic TJC / Nextion .tft library lives at the workspace root.
sys.path.insert(0, os.path.join(ROOT, "..", "TFTTool"))

import TFTTool as T  # noqa: E402,F401
