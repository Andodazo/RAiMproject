import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/models/avatar_mode.dart';
import 'package:raim_prototype/services/embed_unity_bridge.dart';
import 'package:raim_prototype/services/unity_ready_signal.dart';
import 'package:raim_prototype/services/windows_unity_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('モバイルは準備前の最後の選択を感情より先に送り、再通知しても重複しない', () async {
    UnityReadySignal.reset();
    const channel = MethodChannel('com.learntoflutter/flutter_embed_unity');
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
    });
    final bridge = EmbedUnityBridge();
    try {
      bridge.setAvatarMode(AvatarMode.twoD);
      bridge.setAvatarMode(AvatarMode.threeD);
      bridge.setAvatarMode(AvatarMode.twoD);
      bridge.sendEmotions(emotions: {'happy': 1}, overallIntensity: 0.7);
      expect(calls, isEmpty);
      UnityReadySignal.handleMessage('{"type":"unity.ready"}');
      await Future<void>.delayed(Duration.zero);
      expect(calls.map((c) => (c.arguments as List)[1]), [
        'ReceiveAvatarMode',
        'ReceiveEmotions',
      ]);
      expect(
        jsonDecode((calls.first.arguments as List)[2] as String)['mode'],
        '2d',
      );
      bridge.setAvatarMode(AvatarMode.twoD);
      expect(calls, hasLength(2));
      bridge.setAvatarMode(AvatarMode.threeD);
      await Future<void>.delayed(Duration.zero);
      expect(
        jsonDecode((calls.last.arguments as List)[2] as String)['mode'],
        '3d',
      );
    } finally {
      await bridge.stop();
      messenger.setMockMethodCallHandler(channel, null);
      UnityReadySignal.reset();
    }
  });

  test('Windowsは認証後に最後の選択を先に送り、再接続でも保持する', () async {
    final temp = await Directory.systemTemp.createTemp(
      'raim-avatar-bridge-test-',
    );
    final tokenFile = File('${temp.path}/bridge_token');
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    final bridge = WindowsUnityBridge(port: port, autoLaunchUnity: false);
    // 実際のRAiMの認証ファイルには触れず、テスト内の一時ファイルへ隔離する。
    await IOOverrides.runZoned(
      () async {
        WebSocket? socket;
        StreamIterator<dynamic>? incoming;
        Future<Map<String, dynamic>> next() async {
          expect(
            await incoming!.moveNext().timeout(const Duration(seconds: 5)),
            isTrue,
          );
          return jsonDecode(incoming!.current as String)
              as Map<String, dynamic>;
        }

        Future<void> connect() async {
          socket = await WebSocket.connect('ws://localhost:$port');
          incoming = StreamIterator(socket!);
          socket!.add(
            jsonEncode({
              'type': 'auth',
              'token': await tokenFile.readAsString(),
            }),
          );
          expect((await next())['type'], 'auth.ok');
          expect((await next())['type'], 'device_time');
        }

        try {
          bridge.setAvatarMode(AvatarMode.twoD);
          bridge.setAvatarMode(AvatarMode.threeD);
          bridge.setAvatarMode(AvatarMode.twoD);
          bridge.sendEmotions(emotions: {'happy': 1}, overallIntensity: 0.7);
          await bridge.start();
          await connect();
          expect((await next())['mode'], '2d');
          expect((await next())['type'], 'emotions');
          bridge.setAvatarMode(AvatarMode.threeD);
          expect((await next())['mode'], '3d');
          await socket!.close();
          await incoming!.cancel();
          await connect();
          expect((await next())['mode'], '3d');
        } finally {
          await socket?.close();
          await incoming?.cancel();
          await bridge.stop();
        }
      },
      createFile: (path) {
        if (!path.endsWith('bridge_token'))
          throw StateError('Unexpected file in bridge test');
        return tokenFile;
      },
    );
    final tempRoot = await Directory.systemTemp.resolveSymbolicLinks();
    final resolved = await temp.resolveSymbolicLinks();
    expect(resolved.startsWith('$tempRoot${Platform.pathSeparator}raim-avatar-bridge-test-'), isTrue);
    await temp.delete(recursive: true);
  });
}
