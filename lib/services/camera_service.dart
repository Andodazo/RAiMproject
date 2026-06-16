import 'dart:convert';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'dart:typed_data';

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

    if (pickedFiles.isEmpty) return null;

    final List<Map<String, String>> resultList = [];

    for (final xFile in pickedFiles) {
      final file = File(xFile.path);

      // 1. 画像ファイルをバイトデータとして読み込み、デコードする
      final imageBytes = await file.readAsBytes();
      final originalImage = img.decodeImage(imageBytes);

      if (originalImage == null) continue;

      // 2. 長辺が 1024px を超えている場合はリサイズ（仕様書 4.3 のロジック）
      img.Image resizedImage = originalImage;
      if (originalImage.width > 1024 || originalImage.height > 1024) {
        if (originalImage.width > originalImage.height) {
          resizedImage = img.copyResize(originalImage, width: 1024);
        } else {
          resizedImage = img.copyResize(originalImage, height: 1024);
        }
      }

      // 3. JPEG quality 85 で圧縮してバイト配列に変換
      final compressedBytes = Uint8List.fromList(img.encodeJpg(resizedImage, quality: 85));

      // 4. 圧縮後のバイトデータを Base64 にエンコード
      final base64str = base64Encode(compressedBytes);

      resultList.add({
        'path': xFile.path,
        'base64': base64str,
      });
    }
    return resultList;
  }
}