import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';

class CameraService {
  // file_picker は事前の初期化インスタンスが不要なため、非常にシンプルになる

  Future<Map<String, String>?> selectAndProcessImage() async {
    try {
      print('[CameraService] アルバム（ファイルピッカー）を起動します');
      
      // 端末のギャラリーから画像ファイル（jpg, png等）を1枚だけ選択させる
      final FilePickerResult? result = await FilePicker.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );

      // ユーザーが画像を選んだ場合、そのファイルのパスを返す
      if (result != null && result.files.single.path != null) {
        final String path = result.files.single.path!;
        final File file = File(path);

        print('[CameraService]画像ファイルをバイトデータに変換中...');
        List<int> imageBytes = await file.readAsBytes();
        
        //Base64に変換
        String base64String = base64Encode(imageBytes);
        print('[CameraService]Base64変換完了（文字数: ${base64String.length}）');

        return {
          'path': path,
          'base64': base64String,
        };
      }
    } catch (e) {
      print('[CameraService] 画像選択・変換エラー: $e');
    }
    return null; // キャンセルされた場合など
  }
}