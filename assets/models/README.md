ONNX conversions of the official Real-ESRGAN weights for Hobee's on-device image upscaling.

Real-ESRGAN by Xintao Wang, Liangbin Xie, Chao Dong, Ying Shan. https://github.com/xinntao/Real-ESRGAN
License: BSD-3-Clause (code and released weights). Copyright (c) 2021, Xintao Wang. All rights reserved.

Files (opset 17, float32, input "input" 1x3xHxW in 0..1 RGB, output "output" 1x3x4Hx4W):
- RealESRGAN_x4plus.onnx from RealESRGAN_x4plus.pth (v0.1.0). sha256 aeda30ebfe7519d087071902b8198bbdfc08a5ba8457969fc8c453c3010bc57c
- RealESRGAN_x4plus_anime_6B.onnx from RealESRGAN_x4plus_anime_6B.pth (v0.2.2.4). sha256 d0c0ba25911cdc60151a1bdb33b4cc3d7beb86317b6d1540a290d78e0a0d8255
- realesr-general-x4v3.onnx from realesr-general-x4v3.pth (v0.2.5.0), also bundled in the APK. sha256 03b4330dd80f9ecb39c9ff9c784e43349851cb8e011f883c645c0b0a8b31e284

Converted with torch.onnx.export, weights unchanged.
