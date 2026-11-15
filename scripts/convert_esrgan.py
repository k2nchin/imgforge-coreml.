#!/usr/bin/env python3
"""
convert_esrgan.py — Real-ESRGAN (.pth) -> Core ML (.mlpackage)

Traza el RRDBNet con una entrada fija y lo convierte con coremltools.
Entrada y salida se declaran como imagenes para que Core ML acepte
CVPixelBuffer directo y no haya conversion manual en Swift.
"""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

LOG = logging.getLogger("convert")

# RRDBNet es la red de Real-ESRGAN clasica. SRVGGNetCompact es la red
# compacta de los modelos "general", mucho mas pequena y pensada para
# degradaciones reales de fotografia, no sinteticas.
ARCHS = {
    "realesrgan-x4plus":       dict(kind="rrdb",    num_block=23, scale=4),
    "realesrgan-x4plus-anime": dict(kind="rrdb",    num_block=6,  scale=4),
    "realesrgan-x2plus":       dict(kind="rrdb",    num_block=23, scale=2),
    "realesr-general-x4v3":    dict(kind="compact", num_conv=32,  scale=4),
    "realesr-animevideov3":    dict(kind="compact", num_conv=16,  scale=4),
}


def parse_args():
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("--weights", required=True, type=Path)
    p.add_argument("--variant", required=True, choices=sorted(ARCHS))
    p.add_argument("--tile", type=int, default=512)
    p.add_argument("--precision", choices=["float16", "float32"], default="float16")
    p.add_argument("--out", required=True, type=Path)
    p.add_argument("--deployment", default="iOS17",
                   help="target minimo: iOS16 | iOS17 | iOS18")
    p.add_argument("--verbose", action="store_true")
    return p.parse_args()


def build_net(cfg):
    from basicsr.archs.rrdbnet_arch import RRDBNet

    if cfg["kind"] == "rrdb":
        LOG.info("Arquitectura RRDBNet: num_block=%d scale=%d",
                 cfg["num_block"], cfg["scale"])
        return RRDBNet(
            num_in_ch=3, num_out_ch=3, num_feat=64,
            num_block=cfg["num_block"], num_grow_ch=32, scale=cfg["scale"],
        )

    from basicsr.archs.srvgg_arch import SRVGGNetCompact

    LOG.info("Arquitectura SRVGGNetCompact: num_conv=%d scale=%d",
             cfg["num_conv"], cfg["scale"])
    return SRVGGNetCompact(
        num_in_ch=3, num_out_ch=3, num_feat=64,
        num_conv=cfg["num_conv"], upscale=cfg["scale"], act_type="prelu",
    )


def load_model(weights: Path, variant: str):
    import torch

    cfg = ARCHS[variant]
    net = build_net(cfg)

    LOG.info("Cargando pesos: %s", weights)
    blob = torch.load(weights, map_location="cpu", weights_only=True)
    state = blob.get("params_ema") or blob.get("params") or blob
    missing, unexpected = net.load_state_dict(state, strict=False)
    if missing:
        LOG.warning("Claves faltantes: %d", len(missing))
    if unexpected:
        LOG.warning("Claves sobrantes: %d", len(unexpected))

    net.eval()
    for p in net.parameters():
        p.requires_grad_(False)
    return net, cfg["scale"]


def wrap(net):
    """
    coremltools exige scale=1.0 en una salida ImageType, asi que la
    desnormalizacion 0-1 -> 0-255 va dentro del grafo. El clamp evita
    que los valores fuera de rango se envuelvan al convertir a uint8.
    """
    import torch

    class Denormalized(torch.nn.Module):
        def __init__(self, inner):
            super().__init__()
            self.inner = inner

        def forward(self, x):
            return torch.clamp(self.inner(x), 0.0, 1.0) * 255.0

    m = Denormalized(net)
    m.eval()
    return m


def main() -> int:
    args = parse_args()
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%H:%M:%S",
    )

    if not args.weights.exists():
        LOG.error("No existe: %s", args.weights)
        return 1
    if args.tile < 64 or args.tile > 1024:
        LOG.error("--tile fuera de rango razonable (64-1024): %d", args.tile)
        return 1

    import torch
    import coremltools as ct

    net, scale = load_model(args.weights, args.variant)
    model = wrap(net)

    example = torch.rand(1, 3, args.tile, args.tile)
    LOG.info("Trazando con entrada %s", tuple(example.shape))
    try:
        with torch.no_grad():
            traced = torch.jit.trace(model, example, strict=False)
        traced.eval()
    except Exception:
        LOG.exception("El trazado fallo")
        return 2

    target = getattr(ct.target, args.deployment)
    precision = (ct.precision.FLOAT16 if args.precision == "float16"
                 else ct.precision.FLOAT32)

    LOG.info("Convirtiendo (%s, %s)", args.deployment, args.precision)
    try:
        mlmodel = ct.convert(
            traced,
            convert_to="mlprogram",
            minimum_deployment_target=target,
            compute_precision=precision,
            compute_units=ct.ComputeUnit.ALL,
            inputs=[ct.ImageType(
                name="input",
                shape=(1, 3, args.tile, args.tile),
                scale=1 / 255.0,
                color_layout=ct.colorlayout.RGB,
            )],
            outputs=[ct.ImageType(
                name="output",
                color_layout=ct.colorlayout.RGB,
            )],
        )
    except Exception:
        LOG.exception("La conversion fallo")
        return 3

    mlmodel.short_description = (
        f"Real-ESRGAN {args.variant}, super-resolucion {scale}x"
    )
    mlmodel.author = "Convertido con coremltools desde Real-ESRGAN (BSD-3-Clause)"
    mlmodel.version = "1.0"
    mlmodel.input_description["input"] = f"Imagen RGB de {args.tile}x{args.tile}"
    mlmodel.output_description["output"] = (
        f"Imagen RGB de {args.tile * scale}x{args.tile * scale}"
    )
    mlmodel.user_defined_metadata["scale"] = str(scale)
    mlmodel.user_defined_metadata["tile"] = str(args.tile)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(args.out))

    size = sum(f.stat().st_size for f in args.out.rglob("*") if f.is_file())
    LOG.info("Escrito: %s (%.1f MB)", args.out, size / 1e6)
    print(args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
