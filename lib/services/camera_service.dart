//画像の「選択・撮影」と「送信用の軽量化・変換」の処理
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:raim_prototype/models/image_attachment.dart';
import 'package:uuid/uuid.dart';

/// これより大きい PNG は JPEG にする（processImageBytes）。
const int pngToJpegThreshold = 512 * 1024;

/// JPEG/PNGをデコード → 長辺1024pxへ縮小 → 同じ形式で再圧縮する。
/// ただし大きい PNG は JPEG にする（[pngToJpegThreshold]）。
///
/// compute() で別 isolate に渡すため、トップレベル関数にしている。
/// 12MP の写真だとデコードだけで数百ms〜数秒かかり、
/// main isolate で回すと選択直後に UI が固まる。
///
/// GIF/WebPは形式を変えず、元データを返す。
Uint8List processImageBytes(Uint8List imageBytes, String contentType) {
  // GIFはアニメーションを壊さないため再エンコードしない。
  // WebPも形式を変えないため元データを保持する。
  if (contentType == 'image/gif' || contentType == 'image/webp') {
    return imageBytes;
  }

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

  if (contentType == 'image/png') {
    final png = img.encodePng(resizedImage);
    if (png.length <= pngToJpegThreshold) return Uint8List.fromList(png);

    // スクリーンショットのような PNG は、縮小しても1〜2MB あることが多い。
    // 送れる合計は 2MB なので、2枚で上限に届いてしまう。大きいものは
    // JPEG にする（形式が変わるので、呼び出し側は結果の形式を見直すこと）。
    // 透明な部分が黒くならないよう、白い背景に重ねてから変換する。
    final background = img.Image(
      width: resizedImage.width,
      height: resizedImage.height,
    );
    img.fill(background, color: img.ColorRgb8(255, 255, 255));
    img.compositeImage(background, resizedImage);
    return Uint8List.fromList(img.encodeJpg(background, quality: 85));
  }
  return Uint8List.fromList(img.encodeJpg(resizedImage, quality: 85));
}

class CameraService {
  final ImagePicker _picker = ImagePicker();
  static const Uuid _uuid = Uuid();

  /// 画像を取得して、プレビュー用の元パスとS3用一時ファイルを返す。
  /// Base64や画像バイトは呼び出し元へ返さない。
  /// [source] に ImageSource.camera または ImageSource.gallery を指定する
  Future<List<PendingImage>?> selectAndProcessImages(ImageSource source) async {
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

    final List<PendingImage> resultList = [];
    for (final xFile in pickedFiles) {
      final imageBytes = await xFile.readAsBytes();
      final format = detectImageFormat(imageBytes);
      if (format == null) continue;

      // 重い処理なので別 isolate で回す（UIを止めないため）。
      final compressedBytes = await compute(
        _processImageInput,
        _ImageProcessingInput(
          bytes: imageBytes,
          contentType: format.contentType,
        ),
      );

      if (compressedBytes.isEmpty) continue;

      // 大きい PNG は JPEG に変わるので、結果から形式を決め直す
      final outFormat = detectImageFormat(compressedBytes) ?? format;

      final tempPath =
          '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'raim-upload-${_uuid.v4()}.${outFormat.extension}';
      await File(tempPath).writeAsBytes(compressedBytes, flush: true);
      resultList.add(PendingImage(
        localPath: xFile.path,
        uploadPath: tempPath,
        contentType: outFormat.contentType,
        extension: outFormat.extension,
        sizeBytes: compressedBytes.length,
      ));
    }
    return resultList;
  }
}

class _ImageProcessingInput {
  final Uint8List bytes;
  final String contentType;

  const _ImageProcessingInput({
    required this.bytes,
    required this.contentType,
  });
}

Uint8List _processImageInput(_ImageProcessingInput input) {
  return processImageBytes(input.bytes, input.contentType);
}

class ImageFormat {
  final String contentType;
  final String extension;

  const ImageFormat({
    required this.contentType,
    required this.extension,
  });
}

ImageFormat? detectImageFormat(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff) {
    return const ImageFormat(contentType: 'image/jpeg', extension: 'jpg');
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4e &&
      bytes[3] == 0x47 && bytes[4] == 0x0d && bytes[5] == 0x0a &&
      bytes[6] == 0x1a && bytes[7] == 0x0a) {
    return const ImageFormat(contentType: 'image/png', extension: 'png');
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 &&
      bytes[3] == 0x46 && bytes[8] == 0x57 && bytes[9] == 0x45 &&
      bytes[10] == 0x42 && bytes[11] == 0x50) {
    return const ImageFormat(contentType: 'image/webp', extension: 'webp');
  }
  if (bytes.length >= 6 && bytes[0] == 0x47 && bytes[1] == 0x49 &&
      bytes[2] == 0x46 && bytes[3] == 0x38 &&
      (bytes[4] == 0x37 || bytes[4] == 0x39) && bytes[5] == 0x61) {
    return const ImageFormat(contentType: 'image/gif', extension: 'gif');
  }
  return null;
}
