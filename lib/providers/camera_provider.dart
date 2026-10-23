//カメラ、画像の状態管理
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
// 修正: 画像枚数の上限を送信処理と共通の設定から参照する。
import 'package:raim_prototype/config/raim_config.dart';
import 'package:raim_prototype/models/image_attachment.dart';
import 'package:raim_prototype/services/camera_service.dart';


class CameraProvider extends ChangeNotifier {
  /// 一度に添付できる画像の枚数上限。
  ///
  /// ギャラリーから数十枚選ばれた場合でも、Coreの上限と一致させる。
  // 修正: アプリ内の選択上限とサーバーへ送る上限を同じ設定にそろえる。
  static const int maxImageCount = RaimConfig.maxImageCount;

  // 修正: 選択処理を差し替えられるようにし、通常利用では従来のサービスを使う。
  CameraProvider({CameraService? cameraService})
      : _cameraService = cameraService ?? CameraService();

  final CameraService _cameraService;
  final List<PendingImage> _selectedImages = [];

  // 修正: 選択解除・ログアウト・破棄より前に始まった画像選択を無効にする。
  int _selectionGeneration = 0;
  bool _disposed = false;

  List<PendingImage> get selectedImages => List.unmodifiable(_selectedImages);
  List<String> get selectedImagePaths =>
      List.unmodifiable(_selectedImages.map((image) => image.localPath));
  bool get hasImage => _selectedImages.isNotEmpty;

  /// 画像を取得してキープする（カメラかギャラリーかを引数で指定）
  // 修正: 上限で追加できなかった枚数を返し、画面側で利用者へ知らせられるようにする。
  Future<int> pickAndStoreImage(ImageSource source) async {
    if (_disposed) return 0;
    final generation = _selectionGeneration;
    final results = await _cameraService.selectAndProcessImages(source);
    if (results == null || results.isEmpty) return 0;

    // 修正: 古い選択結果は画面へ戻さず、一時ファイルだけを片付ける。
    if (_disposed || generation != _selectionGeneration) {
      for (final image in results) {
        _deleteUploadFile(image);
      }
      return 0;
    }

    // 修正: 空き枚数だけ追加し、すでに上限に達していても超過分をすべて片付ける。
    final remaining = _selectedImages.length < maxImageCount
        ? maxImageCount - _selectedImages.length
        : 0;
    final accepted = results.take(remaining).toList();
    _selectedImages.addAll(accepted);
    for (final unused in results.skip(remaining)) {
      _deleteUploadFile(unused);
    }

    if (accepted.isNotEmpty) notifyListeners();
    return results.length - accepted.length;
  }

  /// 指定されたインデックスの画像だけを削除する
  void removeImageAt(int index) {
    if (index >= 0 && index < _selectedImages.length) {
      final removed = _selectedImages.removeAt(index);
      // 修正: 元画像を残し、選択解除した画像のアップロード用一時ファイルだけを消す。
      _deleteUploadFile(removed);
      notifyListeners(); // 画面を再描画してプレビューから消す
    }
  }

  /// 選択状態をクリアする。
  ///
  /// 送信開始直後は、アップロード処理が一時ファイルを読むため
  /// [deleteTemporaryFiles]をfalseにする（アップロード側が後で削除する）。
  void clearImage({bool deleteTemporaryFiles = true}) {
    // 修正: 選択画面の完了が遅れても、消した画像が戻らないよう先に世代を進める。
    if (_disposed) return;
    _selectionGeneration++;
    if (deleteTemporaryFiles) {
      for (final image in _selectedImages) {
        _deleteUploadFile(image);
      }
    }
    _selectedImages.clear();
    notifyListeners(); // 画面からプレビューを消す
  }

  // 修正: 元画像と同じパスは削除せず、アップロード用一時ファイルだけを削除する。
  void _deleteUploadFile(PendingImage image) {
    // アップロードサービス側でも成功・失敗後に削除する。
    // ここでは選択解除時の一時ファイルだけを掃除する。
    unawaited(() async {
      try {
        final file = File(image.uploadPath);
        final uploadPath = file.absolute.uri.normalizePath().toFilePath();
        final originalPath =
            File(image.localPath).absolute.uri.normalizePath().toFilePath();
        final samePath = Platform.isWindows
            ? uploadPath.toLowerCase() == originalPath.toLowerCase()
            : uploadPath == originalPath;
        if (samePath) return;
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }());
  }

  // 修正: 破棄後の選択結果を無効にし、選択中のアップロード用一時ファイルも片付ける。
  @override
  void dispose() {
    _disposed = true;
    _selectionGeneration++;
    for (final image in _selectedImages) {
      _deleteUploadFile(image);
    }
    _selectedImages.clear();
    super.dispose();
  }
}
