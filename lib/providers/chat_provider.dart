// lib/providers/chat_provider.dart  (v3 - 永続接続対応)
//
// 変更点:
// - RaimServerService の stateStream を購読して UI に接続状態を伝える
// - connectionState プロパティを公開（UI が状態を見て表示分岐可能）
// - 既存の Stream ベース sendMessage はそのまま

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:raim_prototype/models/message.dart';
import 'package:raim_prototype/models/llm_response.dart';
import 'package:raim_prototype/services/llm_service.dart';
import 'package:raim_prototype/services/raim_server_service.dart';
import 'package:raim_prototype/services/unity_communicator.dart';
import 'package:raim_prototype/services/tts_service.dart';

class ChatProvider extends ChangeNotifier {
  final LLMService _llmService;
  final UnityCommunicator _unityBridge;
  final TTSService _ttsService = TTSService();

  final List<Message> _messages = [];
  bool _isLoading = false;

  /// 接続状態（RaimServerService 使用時のみ意味を持つ）
  /// OllamaService / MockLLMService の場合は常に connected 扱い
  RaimConnectionState _connectionState = RaimConnectionState.connected;
  StreamSubscription<RaimConnectionState>? _stateSubscription;

  ChatProvider(this._llmService, this._unityBridge) {
    _ttsService.initialize();
    _bindConnectionState();
  }

  List<Message> get messages => List.unmodifiable(_messages);
  bool get isLoading => _isLoading;
  RaimConnectionState get connectionState => _connectionState;

  /// 「寝てる」状態か（UI で立ち絵切替などに使用予定）
  bool get isOffline => _connectionState == RaimConnectionState.offline;

  void _bindConnectionState() {
    // RaimServerService の場合のみ接続状態を購読
    if (_llmService is RaimServerService) {
      final service = _llmService;
      _connectionState = service.state;
      _stateSubscription = service.stateStream.listen((newState) {
        _connectionState = newState;
        notifyListeners();
      });
    }
  }

  @override
  void dispose() {
    _stateSubscription?.cancel();
    super.dispose();
  }
//{List<String>? images}の追加
  Future<void> sendUserMessage(String text, {List<String>? images}) async {
    //サーバーが受け取るための画像配列を準備（中身がnullならからの配列に）
    //  修正：サーバーの仕様に合わせ、Base64文字列を [ { "data": "...", "media_type": "image/jpeg" } ] の構造に変換
    final List<Map<String, String>> targetImages = [];
    if (images != null) {
      for (final base64Data in images) {
        targetImages.add({
          'data': base64Data,
          'media_type': 'image/jpeg',//JPEG指定（一般的なカメラ・ギャラリー画像はこれで通る）
        });
      }
    }

    _messages.add(Message(
      text: text,
      role: MessageRole.user,
      timestamp: DateTime.now(),// 💡 もし将来、画面上の吹き出し（Messageモデル）にも画像を表示したくなったら
                                // ここに imagePath: ... などを渡せるようMessageモデル側を拡張してください。
    ));
    notifyListeners();

    _isLoading = true;
    notifyListeners();

    try {
      final recentHistory = _messages.length > 21
          ? _messages.sublist(_messages.length - 21, _messages.length - 1)
          : _messages.sublist(0, _messages.length - 1);

      bool chatReceived = false;
      // 引数の images にtargetImages を渡します
      await for (final response in _llmService.sendMessage(
        text,
        history: recentHistory,
        images: targetImages,
      )) {
        _handleResponse(response);
        if (response.isChat) chatReceived = true;
      }

      if (!chatReceived) {
        _messages.add(Message(
          text: 'えっと……ごめん、上手く言葉が出なかったみたい。もう一度話しかけて？',
          role: MessageRole.assistant,
          timestamp: DateTime.now(),
          emotion: 'sad',
          intensity: 0.5,
        ));
      }
    } catch (e) {
      _messages.add(Message(
        text: "エラーが発生しました: $e",
        role: MessageRole.assistant,
        timestamp: DateTime.now(),
        emotion: 'sad',
        intensity: 0.5,
      ));
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void _handleResponse(LLMResponse response) {
    if (response.isFillerAudio) {
      _unityBridge.sendEmotion(
        text: response.text,
        emotion: response.emotion,
        intensity: response.intensity,
      );
      _ttsService.speak(response.text);
    } else if (response.isChat) {
      _messages.add(Message(
        text: response.text,
        role: MessageRole.assistant,
        timestamp: DateTime.now(),
        emotion: response.emotion,
        intensity: response.intensity,
      ));
      _unityBridge.sendEmotion(
        text: response.text,
        emotion: response.emotion,
        intensity: response.intensity,
      );
      _ttsService.speak(response.text);
      notifyListeners();
    } else {
      // 未知のtype（tool_call / proactive_message / error など）
      // ignore: avoid_print
      print('[ChatProvider] 未対応のメッセージ type: ${response.type}');
    }
  }
}