"""
matlab_bridge.py
Singleton wrapper around the MATLAB Engine for Python so Flask doesn't
pay MATLAB's ~20-30s startup cost on every request.

ONE-TIME SETUP (Windows, from your conda env on D:):
    cd "C:\\Program Files\\MATLAB\\R2026a\\extern\\engines\\python"
    python -m pip install .

Then set these two environment variables before running Flask (or edit
the defaults below):
    MATLAB_SRC_DIR   folder containing runDRPipelineProduction.m and all
                      the Module 1-4 .m files (e.g. your matlab/ folder)
    DR_MODEL_PATH    path to drClassifier.mat once it's trained.
                      If this file doesn't exist yet, the pipeline just
                      runs in real_no_cnn mode automatically - nothing
                      else needs to change.
"""

import atexit
import json
import os
import threading

import matlab.engine

MATLAB_SRC_DIR = os.environ.get(
    "MATLAB_SRC_DIR",
    os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "matlab")),
)
MODEL_PATH = os.environ.get("DR_MODEL_PATH", "drClassifier.mat")


class MatlabBridge:
    _instance = None
    _lock = threading.Lock()

    def __new__(cls):
        if cls._instance is None:
            with cls._lock:
                if cls._instance is None:
                    cls._instance = super().__new__(cls)
                    cls._instance._start_engine()
        return cls._instance

    def _start_engine(self):
        print("[matlab_bridge] Starting MATLAB engine (this can take 20-30s)...")
        self.eng = matlab.engine.start_matlab()
        self.eng.addpath(MATLAB_SRC_DIR, nargout=0)
        self.call_lock = threading.Lock()  # MATLAB Engine calls aren't thread-safe
        print(f"[matlab_bridge] Ready. MATLAB source dir: {MATLAB_SRC_DIR}")
        atexit.register(self.shutdown)

    def run_pipeline(self, image_path: str, output_dir: str) -> dict:
        """Run the full DRishti pipeline on one image and return a plain dict
        read back from report.json (avoids fragile MATLAB-struct parsing
        over the engine bridge).

        Never raises just because the CNN isn't trained yet - that's
        handled inside runDRPipelineProduction.m by falling back to
        real_no_cnn. This can still raise for a bad image path or a
        genuine MATLAB error; callers should catch that and show a
        friendly message.
        """
        os.makedirs(output_dir, exist_ok=True)
        with self.call_lock:
            self.eng.runDRPipelineProduction(
                image_path,
                "OutputDir", output_dir,
                "ModelPath", MODEL_PATH,
                nargout=0,
            )
        json_path = os.path.join(output_dir, "report.json")
        with open(json_path, "r") as f:
            return json.load(f)

    def shutdown(self):
        try:
            self.eng.quit()
        except Exception:
            pass


def get_bridge() -> "MatlabBridge":
    return MatlabBridge()
