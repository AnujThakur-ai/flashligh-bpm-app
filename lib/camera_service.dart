import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

class CameraService {
  CameraController? _controller;

  CameraController? get controller => _controller;
  bool get isInitialized => _controller?.value.isInitialized ?? false;

  Future<void> start(void Function(CameraImage image) onImage) async {
    final permission = await Permission.camera.request();
    if (!permission.isGranted) {
      throw StateError(
        permission.isPermanentlyDenied
            ? 'Camera permission is permanently denied. Enable it in Settings.'
            : 'Camera permission is required to measure heart rate.',
      );
    }

    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      throw StateError('No camera is available on this device.');
    }
    final rearCamera = cameras.where(
      (camera) => camera.lensDirection == CameraLensDirection.back,
    );
    if (rearCamera.isEmpty) {
      throw StateError('A rear camera is required for heart-rate measurement.');
    }

    final controller = CameraController(
      rearCamera.first,
      ResolutionPreset.low,
      enableAudio: false,
      imageFormatGroup:
          Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.yuv420,
    );
    _controller = controller;
    try {
      await controller.initialize();
      await controller.setFlashMode(FlashMode.torch);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await controller.setExposureMode(ExposureMode.locked);
      await controller.setFocusMode(FocusMode.locked);
      await controller.startImageStream(onImage);
    } on Object {
      await dispose();
      rethrow;
    }
  }

  Future<void> dispose() async {
    final controller = _controller;
    _controller = null;
    if (controller == null) return;

    if (controller.value.isInitialized && controller.value.isStreamingImages) {
      try {
        await controller.stopImageStream();
      } on CameraException catch (error, stackTrace) {
        debugPrint('Unable to stop the camera stream: $error\n$stackTrace');
      }
    }
    if (controller.value.isInitialized) {
      try {
        await controller.setFlashMode(FlashMode.off);
      } on CameraException catch (error, stackTrace) {
        debugPrint('Unable to turn off the torch: $error\n$stackTrace');
      }
    }
    await controller.dispose();
  }
}
