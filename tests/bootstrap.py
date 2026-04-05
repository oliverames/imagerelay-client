from __future__ import annotations

import os
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SRC_ROOT = PROJECT_ROOT / "src"

if str(SRC_ROOT) not in sys.path:
    sys.path.insert(0, str(SRC_ROOT))

current_pythonpath = os.environ.get("PYTHONPATH", "")
pythonpath_entries = [entry for entry in current_pythonpath.split(os.pathsep) if entry]
if str(SRC_ROOT) not in pythonpath_entries:
    os.environ["PYTHONPATH"] = os.pathsep.join([str(SRC_ROOT), *pythonpath_entries])
