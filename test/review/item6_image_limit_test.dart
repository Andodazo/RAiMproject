// 課題6: アプリでは画像を10枚まで選べたが、サーバーは4枚までなので、
//        5枚以上はアップロードしたあとで断られていた
//
//   flutter test test/review/item6_image_limit_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/config/raim_config.dart';
import 'package:raim_prototype/models/image_attachment.dart';
import 'package:raim_prototype/models/message.dart';
import 'package:raim_prototype/providers/camera_provider.dart';
import 'package:raim_prototype/providers/chat_provider.dart';
import 'package:raim_prototype/services/aws_image_service.dart';

import 'support/fakes.dart';

/// サーバー（Edge Lambda の MAX_IMAGE_COUNT の既定値）と同じ枚数
const int serverLimit = 4;

List<PendingImage> images(int count) => [
      for (var i = 0; i < count; i++)
        PendingImage(
          localPath: 'test-image-$i.jpg',
          uploadPath: 'test-image-$i-upload.jpg',
          contentType: 'image/jpeg',
          extension: 'jpg',
          sizeBytes: 1000,
        ),
    ];

void main() {
  test('上限は1か所（RaimConfig.maxImageCount）にあり、サーバーと同じ4枚', () {
    expect(RaimConfig.maxImageCount, serverLimit);
  });

  test('画像を選ぶ画面の上限も同じ値を使っている', () {
    expect(CameraProvider.maxImageCount, RaimConfig.maxImageCount);
  });

  test('5枚はアップロードする前に断る（AwsImageService）', () async {
    final service = AwsImageService();
    await expectLater(
      service.uploadImages(
        idToken: 'dummy',
        images: images(serverLimit + 1),
        userSub: 'user',
        requestId: 'request',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('5枚で送ろうとしたら、サーバーに送らずに4枚までと知らせる（ChatProvider）', () async {
    final llm = ScriptedLlm(const []);
    final chat = ChatProvider(llm, FakeUnity(), audioQueue: FakeAudioQueue());
    addTearDown(chat.dispose);

    await chat.sendUserMessage('見て', pendingImages: images(serverLimit + 1));

    expect(llm.calls, 0, reason: '上限を超えているのにサーバーへ送った');
    final last = chat.messages.last;
    expect(last.role, MessageRole.assistant);
    expect(last.text, contains('$serverLimit'), reason: '何枚までなのかを知らせていない');
    expect(chat.isLoading, isFalse);
  });
}
