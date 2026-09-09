/// 送信前に端末へ保持する画像です。
///
/// [localPath] はチャット履歴のプレビュー用、[uploadPath] は
/// S3へアップロードする圧縮済みファイル用です。画像バイトやBase64は
/// Providerへ保持しません。
class PendingImage {
  final String localPath;
  final String uploadPath;
  final String contentType;
  final String extension;
  final int sizeBytes;

  const PendingImage({
    required this.localPath,
    required this.uploadPath,
    required this.contentType,
    required this.extension,
    required this.sizeBytes,
  });
}

/// S3 PutObject成功後にWebSocketへ渡す画像参照です。
class UploadedImage {
  final String key;
  final String contentType;
  final int sizeBytes;

  const UploadedImage({
    required this.key,
    required this.contentType,
    required this.sizeBytes,
  });

  Map<String, dynamic> toJson() => {
        'key': key,
        'contentType': contentType,
        'sizeBytes': sizeBytes,
      };
}
