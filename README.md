# imgforge-coreml

Pipeline de conversión de Real-ESRGAN a Core ML, ejecutado en runners macOS de GitHub Actions.
Produce el `RealESRGAN.mlmodelc` que consume `NeuralUpscaler` en la app ImgForge (iOS).

## Qué hace

1. Descarga los pesos oficiales de Real-ESRGAN (`.pth`), con caché entre ejecuciones.
2. Traza el `RRDBNet` con PyTorch a una entrada fija de `tile × tile`.
3. Convierte a `.mlpackage` con `coremltools`, declarando entrada y salida como **imágenes**
   para que Core ML acepte `CVPixelBuffer` sin conversión manual en Swift.
4. Compila a `.mlmodelc` con `xcrun coremlcompiler` y genera la interfaz Swift.
5. Corre un smoke test: carga el modelo, infiere sobre una imagen de prueba y valida
   la forma y el rango de la salida.
6. Sube todo como artifact.

## Cómo correrlo

GitHub → **Actions** → *Convert Real-ESRGAN to Core ML* → **Run workflow**.

| Entrada    | Opciones                                                        | Default             |
|------------|-----------------------------------------------------------------|---------------------|
| `variant`  | `realesrgan-x4plus`, `realesrgan-x4plus-anime`, `realesrgan-x2plus` | `realesrgan-x4plus` |
| `tile`     | 64–1024                                                         | `512`               |
| `compute`  | `float16`, `float32`                                            | `float16`           |

Al terminar, descarga `RealESRGAN-CoreML-<variant>.zip`, descomprime y arrastra
`RealESRGAN.mlmodelc` a Xcode con *Copy items if needed*.

## Dos detalles que importan

- **El tile debe coincidir.** Si conviertes a 512, `NeuralUpscaler.tile` en Swift
  debe ser 512. El modelo tiene forma fija; una baldosa de otro tamaño falla en runtime.
- **Peso.** `x4plus` en float16 ronda los 64 MB. Decide antes si va en el bundle
  o se descarga a demanda con `MLModelCollection`.

## Integración en Swift

`NeuralUpscaler` busca `RealESRGAN.mlmodelc` por nombre en el bundle. Si no está,
`isAvailable` devuelve `false` y el motor clásico (Lanczos + unsharp) toma el relevo
sin que la capa de UI se entere.

```swift
// Motor .auto: neural si el modelo está y la imagen cabe; clásico si no.
let out = try Upscaler.run(image, options: .init(scale: 4, engine: .auto))
```

## Local, sin Actions

```bash
pip install torch torchvision coremltools "numpy<2" basicsr-fixed Pillow
curl -fsSL -o weights/realesrgan-x4plus.pth \
  https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth

python scripts/convert_esrgan.py \
  --weights weights/realesrgan-x4plus.pth \
  --variant realesrgan-x4plus \
  --tile 512 --out build/RealESRGAN.mlpackage --verbose

xcrun coremlcompiler compile build/RealESRGAN.mlpackage build/
python scripts/smoke_test.py --model build/RealESRGAN.mlpackage
```

La compilación a `.mlmodelc` requiere Xcode, así que ese paso solo corre en macOS.

## Licencias

Real-ESRGAN es BSD-3-Clause (Xintao Wang et al.). Los pesos se descargan de los
releases oficiales en tiempo de build; este repositorio no los redistribuye.
