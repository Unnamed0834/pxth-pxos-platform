import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def load_script(name, filename=None):
    path = ROOT / "scripts" / (filename or name)
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
