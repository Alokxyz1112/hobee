On-device upscale models for Hobee. Only the Fast model ships inside the APK, the others download once from
https://github.com/Alokxyz1112/hobee/releases/tag/models-v2 and are checked with SHA-256.

All files are ONNX opset 17, float32, input "input" 1x3xHxW RGB in 0..1, output "output" 1x3x4Hx4W.
They are straight conversions of the authors' official .pth weights (torch.onnx.export, weights unchanged).

- 4xLSDIRCompactC.onnx (bundled, Fast). By Philip Hofmann (Phhofm). CC BY 4.0, see LICENSE-CC-BY-4.0.txt.
  sha256 ce6d871a99446db063613c8edf1fe3a096507da8b7095323ed10453654390190
- 4xNomosWebPhoto_RealPLKSR.onnx (download, Ultra). By Philip Hofmann (Phhofm). CC BY 4.0.
  sha256 550ec2c879439e707717f6c8250b82908d19fa3ab4f75f26c1713f685c8ef371
- RealESRGAN_x4plus_anime_6B.onnx (download, Art). Real-ESRGAN by Xintao Wang et al. BSD 3-Clause, see
  LICENSE-Real-ESRGAN.txt. sha256 d0c0ba25911cdc60151a1bdb33b4cc3d7beb86317b6d1540a290d78e0a0d8255

See ATTRIBUTION.md for links.
