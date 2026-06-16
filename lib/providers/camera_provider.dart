import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:raim_prototype/services/camera_service.dart';

class CameraProvider extends ChangeNotifier {
  final CameraService _cameraService = CameraService();
  // ★ 変更：単一のパス/Base64 ではなく、リストで管理する
  List<String> _selectedImagePaths = [];
  List<String> _base64ImagesData = [];

  List<String> get selectedImagePaths => _selectedImagePaths;
  bool get hasImage => _selectedImagePaths.isNotEmpty;

  //chat_provider等と連携するために利用するリスト型ゲッター
  List<String>? get selectedImagesBase64 =>
      _base64ImagesData.isNotEmpty ? _base64ImagesData : null;

  /// 画像を取得してキープする（カメラかギャラリーかを引数で指定）
  Future<void> pickAndStoreImage(ImageSource source) async {
    // ★ サービス側に source を横流しする
    final results= await _cameraService.selectAndProcessImages(source);
    if (results != null && results.isNotEmpty) {
      // 新しく選択された画像をリストに追加（上書きする場合は = [] に)
      _selectedImagePaths = results.map((e) => e['path']!).toList();
      _base64ImagesData = results.map((e) => e['base64']!).toList();
      notifyListeners(); // 画面に「画像が選ばれたよ！」と通知してプレビュー表示させる
    }
  }

  /// 指定されたインデックスの画像だけを削除する
  void removeImageAt(int index) {
    if (index >= 0 && index < _selectedImagePaths.length) {
      _selectedImagePaths.removeAt(index);
      _base64ImagesData.removeAt(index);
      notifyListeners(); // 画面を再描画してプレビューから消す
    }
  }

  /// 送信が終わったら画像をクリアする
  void clearImage() {
    _selectedImagePaths.clear();
    _base64ImagesData.clear();
    notifyListeners(); // 画面からプレビューを消す
  }
}