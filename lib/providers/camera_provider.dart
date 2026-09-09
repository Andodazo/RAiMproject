//カメラ、画像の状態管理
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:raim_prototype/models/image_attachment.dart';
import 'package:raim_prototype/services/camera_service.dart';


class CameraProvider extends ChangeNotifier {
  /// 一度に添付できる画像の枚数上限。
  ///
  /// ギャラリーから数十枚選ばれた場合でも、Coreの上限と一致させる。
  static const int maxImageCount = 10;

  final CameraService _cameraService = CameraService();
  final List<PendingImage> _selectedImages = [];

  List<PendingImage> get selectedImages => List.unmodifiable(_selectedImages);
  List<String> get selectedImagePaths =>
      List.unmodifiable(_selectedImages.map((image) => image.localPath));
  bool get hasImage => _selectedImages.isNotEmpty;

  /// 画像を取得してキープする（カメラかギャラリーかを引数で指定）
  Future<void> pickAndStoreImage(ImageSource source) async {
    // ★ サービス側に source を横流しする
    final results= await _cameraService.selectAndProcessImages(source);
    //選ぶ画面から戻ってないかつ画像が0件ではないかの判断
    if (results != null && results.isNotEmpty) {
      // 既存の選択に追加する。
      // 以前はコメントに「追加」と書きながら実際は代入で上書きしており、
      // 2回目の選択で1回目に選んだ画像が消えていた。
      final remaining = maxImageCount - _selectedImages.length;
      if (remaining <= 0) {
        return;
      }

      final accepted = results.take(remaining).toList();
      _selectedImages.addAll(accepted);
      for (final unused in results.skip(remaining)) {
        _deleteUploadFile(unused.uploadPath);
      }

      notifyListeners(); // 画面に「画像が選ばれたよ！」と通知してプレビュー表示させる
    }
  }

  /// 指定されたインデックスの画像だけを削除する
  void removeImageAt(int index) {
    if (index >= 0 && index < _selectedImages.length) {
      final removed = _selectedImages.removeAt(index);
      _deleteUploadFile(removed.uploadPath);
      notifyListeners(); // 画面を再描画してプレビューから消す
    }
  }

  /// 選択状態をクリアする。
  ///
  /// 送信開始直後は、アップロード処理が一時ファイルを読むため
  /// [deleteTemporaryFiles]をfalseにする（アップロード側が後で削除する）。
  void clearImage({bool deleteTemporaryFiles = true}) {
    if (deleteTemporaryFiles) {
      for (final image in _selectedImages) {
        _deleteUploadFile(image.uploadPath);
      }
    }
    _selectedImages.clear();
    notifyListeners(); // 画面からプレビューを消す
  }

  void _deleteUploadFile(String path) {
    // アップロードサービス側でも成功・失敗後に削除する。
    // ここでは選択解除時の一時ファイルだけを掃除する。
    unawaited(() async {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }());
  }
}
