//画像の「選択・撮影」と「送信用の軽量化・変換」の処理
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;

/// 画像1枚をデコード → 長辺1024pxへ縮小 → JPEG(品質85)へ再圧縮する。
///
/// compute() で別 isolate に渡すため、トップレベル関数にしている。
/// 12MP の写真だとデコードだけで数百ms〜数秒かかり、
/// main isolate で回すと選択直後に UI が固まる。
///
/// デコードできなかった場合は空を返す。
Uint8List processImageBytes(Uint8List imageBytes) {
  final originalImage = img.decodeImage(imageBytes);
  if (originalImage == null) return Uint8List(0);

  img.Image resizedImage = originalImage;
  if (originalImage.width > 1024 || originalImage.height > 1024) {
    if (originalImage.width > originalImage.height) {
      resizedImage = img.copyResize(originalImage, width: 1024);
    } else {
      resizedImage = img.copyResize(originalImage, height: 1024);
    }
  }

  return Uint8List.fromList(img.encodeJpg(resizedImage, quality: 85));
}

class CameraService {
  final ImagePicker _picker = ImagePicker();
  /// 画像を取得してパスとBase64データを返す
  /// [source] に ImageSource.camera または ImageSource.gallery を指定する
  Future<List<Map<String, String>>?> selectAndProcessImages(ImageSource source) async {
    List<XFile> pickedFiles = [];

    if (source == ImageSource.gallery) {
      //ギャラリーの場合は複数選択メソッドを呼ぶ
      pickedFiles = await _picker.pickMultiImage();
    } else {
      //カメラの場合は今まで通り一枚だけ撮影
      final file = await _picker.pickImage(source: source);
      if (file != null) {
        pickedFiles.add(file);
      }
    }
    //何もない場合は明確にnullになるように定義している
    if (pickedFiles.isEmpty) return null;

    //配列にすると複数画像送信可能。変数にすると一枚のみ
    final List<Map<String, String>> resultList = [];
    //全部の画像に対して処理を行うためのループ
    for (final xFile in pickedFiles) {
      final file = File(xFile.path);

      // 1〜3. 読み込み → デコード → 縮小 → JPEG 圧縮
      // 重い処理なので別 isolate で回す（UI を止めないため）
      final imageBytes = await file.readAsBytes();
      final compressedBytes = await compute(processImageBytes, imageBytes);

      if (compressedBytes.isEmpty) continue;

      // 4. 圧縮後のバイトデータを Base64 にエンコード
      final base64str = base64Encode(compressedBytes);
      //pathはクライアントサイドで画像を保持するため。base64をサーバー側に送信する
      resultList.add({
        'path': xFile.path,
        'base64': base64str,
      });
    }
    return resultList;
  }
}