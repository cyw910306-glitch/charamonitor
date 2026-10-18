import sys, json, importlib
from lib import *
import os
OUT = os.environ.get("OUT", "qa/originals") + "/"
os.makedirs(OUT, exist_ok=True)
for name in sys.argv[1:]:
    m = importlib.import_module(name)
    validate(name, m.data, getattr(m, "HOP_OK", ()))
    sheet(m.data, OUT + f"sheet-{name}.png")
    strips(m.data, OUT + f"strip-{name}.png")
    json.dump(m.data, open(OUT + f"{name}.json", "w"), indent=1)
    print(name, "ok")
