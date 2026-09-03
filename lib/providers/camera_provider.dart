//カメラ、画像の状態管理
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:raim_prototype/services/camera_service.dart';


class CameraProvider extends ChangeNotifier {
  /// 一度に添付できる画像の枚数上限。
  ///
  /// 上限が無いと、ギャラリーで数十枚選ばれたときに
  /// Base64 が肥大して送信も描画も詰まる。
  static const int maxImageCount = 4;

  final CameraService _cameraService = CameraService();
  // ★ 変更：単一のパス/Base64 ではなく、リストで管理する
  final List<String> _selectedImagePaths = [];//端末で複数保持ための処理
  final List<String> _base64ImagesData = [];//画像をテキストにする処理
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
      // 既存の選択に追加する。
      // 以前はコメントに「追加」と書きながら実際は代入で上書きしており、
      // 2回目の選択で1回目に選んだ画像が消えていた。
      final remaining = maxImageCount - _selectedImagePaths.length;
      if (remaining <= 0) {
        return;
      }

      final accepted = results.take(remaining).toList();
      _selectedImagePaths.addAll(accepted.map((e) => e['path']!));
      _base64ImagesData.addAll(accepted.map((e) => e['base64']!));

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