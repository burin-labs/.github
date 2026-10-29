"""Count files under the given roots that hold the token, its git header, or the control marker.

Needles come from env (GH_TOKEN, CENSUS_CONTROL); only counts and paths are printed, never a value.
Usage: python3 -I census-ci.py <root>...
"""
import base64
import os
import pathlib
import sys

token = os.environ["GH_TOKEN"].encode()
control = os.environ["CENSUS_CONTROL"].encode()
needles = {
    "token": token,
    "header": base64.b64encode(b"x-access-token:" + token),
    "control": control,
}
assert all(needles.values()), "an empty needle would match everything"
files, hits = 0, {k: [] for k in needles}
for root in sys.argv[1:]:
    for p in pathlib.Path(root).rglob("*"):
        try:
            if p.is_symlink() or not p.is_file():
                continue
            data = p.read_bytes()
        except OSError:
            continue
        files += 1
        for k, v in needles.items():
            if v in data:
                hits[k].append(str(p))
print(f"census: {files} files under {sys.argv[1:]}")
for k, v in hits.items():
    print(f"census {k}: {len(v)} file(s)")
    for path in v[:20]:
        print(f"  {path}")
if hits["token"] or hits["header"]:
    sys.exit(1)
