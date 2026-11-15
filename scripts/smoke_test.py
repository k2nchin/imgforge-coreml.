#!/usr/bin/env python3
"""Verifica que el modelo convertido carga y produce una salida con la forma correcta."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--model", required=True, type=Path)
    args = ap.parse_args()

    import coremltools as ct
    from PIL import Image

    if not args.model.exists():
        print(f"ERROR: no existe {args.model}", file=sys.stderr)
        return 1

    model = ct.models.MLModel(str(args.model))
    spec = model.get_spec()

    desc = spec.description.input[0].type.imageType
    tile = int(desc.width)
    scale = int(model.user_defined_metadata.get("scale", 4))
    print(f"Entrada {tile}x{tile} - escala {scale}x")

    probe = Image.new("RGB", (tile, tile), (120, 80, 200))
    out = model.predict({"input": probe})["output"]

    expect = (tile * scale, tile * scale)
    if out.size != expect:
        print(f"ERROR: salida {out.size}, esperada {expect}", file=sys.stderr)
        return 2

    extrema = out.convert("L").getextrema()
    if extrema[0] == extrema[1] == 0:
        print("ERROR: salida completamente negra", file=sys.stderr)
        return 3

    print(f"OK - salida {out.size} - rango {extrema}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
