import 'package:flutter/material.dart';
import 'package:raim_prototype/services/camera_service.dart';

class CameraProvider extends ChangeNotifier {
  final CameraService _cameraService = CameraService();

  String? _selectedImagePath;
  String? _base64ImageData;

  String? get selectedImagePath => _selectedImagePath;
  String? get base64ImageData => _base64ImageData;
  bool get hasImage => _selectedImagePath != null;

  Object? get selectedImageBase64 => null;

  /// ギャラリーを開いて画像をキープする
  Future<void> pickAndStoreImage() async {
    final result = await _cameraService.selectAndProcessImage();
    if (result != null) {
      _selectedImagePath = result['path'];
      _base64ImageData = result['base64'];
      notifyListeners(); // 画面に「画像が選ばれたよ！」と通知してプレビュー表示させる
    }
  }

  /// 送信が終わったら画像をクリアする
  void clearImage() {
    _selectedImagePath = null;
    _base64ImageData = null;
    notifyListeners(); // 画面からプレビューを消す
  }
}