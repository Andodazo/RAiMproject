//カメラ、画像の状態管理
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:raim_prototype/services/camera_service.dart';


class CameraProvider extends ChangeNotifier {
  final CameraService _cameraService = CameraService();
  // ★ 変更：単一のパス/Base64 ではなく、リストで管理する
  List<String> _selectedImagePaths = [];//端末で複数保持ための処理
  List<String> _base64ImagesData = [];//画像をテキストにする処理
  //OSコマンドインジェクションのケア
  List<String> get selectedImagePaths => _selectedImagePaths;//画面側から画像のパスを安全に取得するため
  bool get hasImage => _selectedImagePaths.isNotEmpty;//画像をそもそも持っているかどうか

  //chat_provider等と連携するために利用するリスト型ゲッター
  //画像があれば一緒に送る、なければ画像項目を送らない
  List<String>? get selectedImagesBase64 =>
      _base64ImagesData.isNotEmpty ? _base64ImagesData : null;

  /// 画像を取得してキープする（カメラかギャラリーかを引数で指定）
  Future<void> pickAndStoreImage(ImageSource source) async {
    // ★ サービス側に source を横流しする
    final results= await _cameraService.selectAndProcessImages(source);
    //選ぶ画面から戻ってないかつ画像が0件ではないかの判断
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