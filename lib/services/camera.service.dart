// lib/services/camera_service.dart
import 'package:file_picker/file_picker.dart';

class CameraService {
  Future<String?> captureImage() async {
    try {
      print('[CameraService] アルバムを起動します');
      
      // 端末のギャラリーから画像ファイル（jpg, png等）を1枚だけ選択させる
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );

      // ユーザーが画像を選んだ場合、そのファイルのパスを返す
      if (result != null && result.files.single.path != null) {
        return result.files.single.path;
      }
    } catch (e) {
      print('[CameraService] 画像選択エラー: $e');
    }
    return null; // キャンセルされた場合など
  }
}