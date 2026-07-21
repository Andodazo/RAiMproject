//全体メッセージの管理と必要な情報をファイルごとに分けている
// lib/providers/chat_provider.dart  (v3 - 永続接続対応)
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
import 'package:raim_prototype/services/audio_play_queue.dart';
import 'package:raim_prototype/services/unity_communicator.dart';
import 'package:provider/provider.dart';

class ChatProvider extends ChangeNotifier implements ReassembleHandler {
  // ============================================================
  // 外部サービス
  // ============================================================
  // LLMService はサーバー通信、UnityCommunicator はUnityへの感情送信、
  // AudioPlayQueue は audio_chunk の順次再生を担当する。

  final LLMService _llmService;
  final UnityCommunicator _unityBridge;
  // サーバーから届いた audio_chunk を順番に再生するキュー
  final AudioPlayQueue _audioQueue = AudioPlayQueue();
  //messagesとは描画する会話をまとめたもの

  // ============================================================
  // チャット画面の状態
  // ============================================================
  // _messages は画面に表示する会話履歴。
  // _isLoading はAI返答待ち状態。
  // _currentStreamingMessage は text_chunk を追記中のAIメッセージ。
  final List<Message> _messages = [];
  bool _isLoading = false;
  Message? _currentStreamingMessage;

  /// 接続状態（RaimServerService 使用時のみ意味を持つ）
  /// OllamaService / MockLLMService の場合は常に connected 扱い
  // ============================================================
  // ツール実行・接続状態
  // ============================================================
  // _toolStatus は検索中などの表示文。
  // _connectionState はRAiMサーバーとの接続状態。
  String? _toolStatus;
  RaimConnectionState _connectionState = RaimConnectionState.connected;
  StreamSubscription<RaimConnectionState>? _stateSubscription;
  //ここは使わない
  ChatProvider(this._llmService, this._unityBridge) {
    _bindConnectionState();
  }
  //メッセージの中身を編集されないようにするため。(読み取り専用)
  List<Message> get messages => List.unmodifiable(_messages);
  bool get isLoading => _isLoading;
  String? get toolStatus => _toolStatus;
  RaimConnectionState get connectionState => _connectionState;

  /// 「寝てる」状態か（UI で立ち絵切替などに使用予定）
  bool get isOffline => _connectionState == RaimConnectionState.offline;
  void _bindConnectionState() {
    // RaimServerService の場合のみ接続状態を購読
    //websocketだから変更箇所をリアルタイムで確認するため
    if (_llmService is RaimServerService) {
      final service = _llmService;
      _connectionState = service.state;
      _stateSubscription = service.stateStream.listen((newState) {
        _connectionState = newState;
        notifyListeners();
      });
    }
  }
  //返答完了時の後片付け
  void _handleChatEnd(LLMResponse response) {
    // tool_call では検索などの外部処理中であることが通知される
    // description があればそれを表示し、無ければデフォルト文を表示する
    if (_currentStreamingMessage != null) {
    _currentStreamingMessage = _currentStreamingMessage!.copyWith(
      emotion: response.emotion,
      intensity: response.intensity,
      emotions: response.emotions,
      overallIntensity: response.overallIntensity,
    );
    // 会話履歴内のAIメッセージも更新する
    _messages[_messages.length - 1] = _currentStreamingMessage!;
  }
    // chat_end で届いた最終感情を Unity にも反映する
    _unityBridge.sendEmotions(
      emotions: response.emotions,
      overallIntensity: response.overallIntensity,
    );
    // ストリーミング中メッセージを終了扱いにする
    _currentStreamingMessage = null;
    // 検索中表示を消す
    _toolStatus = null;
    // AI返答待ち状態を解除する
    _isLoading = false;
    notifyListeners();
  }
  //調べていますを表示する処理
  void _handleToolCall(LLMResponse response) {
    // tool_call では検索などの外部処理中であることが通知される
    // description があればそれを表示し、無ければデフォルト文を表示する
    _toolStatus = response.description ?? '調べています...';
    notifyListeners();
  }
  //音声Base64を再生キューに入れる処理
  void _handleAudioChunk(LLMResponse response) {
     // audio が空の場合は再生できないため、何もせず終了する
    if (response.audioBase64 == null || response.audioBase64!.isEmpty) {
      print('[ChatProvider] audio_chunk 受信: audio が空です');
      return;
    }

    // 音声データは長いので、ログには中身ではなく長さだけ出す
    print(
      '[ChatProvider] audio_chunk を再生キューに追加: '
      'chunkId=${response.chunkId}, '
      'format=${response.format ?? 'wav'}, '
      'audioLength=${response.audioBase64!.length}',
    );

    // Base64音声を AudioPlayQueue に渡す
    // AudioPlayQueue 側でデコードして、届いた順番に再生する
    _audioQueue.enqueue(
      base64Audio: response.audioBase64!,
      format: response.format ?? 'wav',
    );
  }

// ============================================================
// 旧形式 chat 処理
// ============================================================
// v2.2以前の "chat" 形式が来た場合の互換処理。
// 古いサーバー応答でも動くように残しておく。
  void _handleLegacyChat(LLMResponse response) {
    _messages.add(Message(
      text: response.text,
      role: MessageRole.assistant,
      timestamp: DateTime.now(),
      emotion: response.emotion,
      intensity: response.intensity,
      emotions: response.emotions,
      overallIntensity: response.overallIntensity,
    ));

    _unityBridge.sendEmotions(
      emotions: response.emotions,
      overallIntensity: response.overallIntensity,
    );

    notifyListeners();
  }

  // ============================================================
  // bubble_break 処理
  // ============================================================
  // サーバーから「ここで吹き出しを分ける」という通知が来たときの処理。
  // 現在追記中のAIメッセージを終了扱いにして、
  // 次の text_chunk が来たら新しい吹き出しを作らせる。

  void _handleBubbleBreak(LLMResponse response) {
    print('[ChatProvider] bubble_break 受信: 次の text_chunk は新規吹き出しにする');
    // 現在のストリーミング吹き出しを区切る
    _currentStreamingMessage = null;
    // notifyListeners は不要（UI 変化なし）
  }
  //分割された文章を吹き出しに追加していく処理
  void _handleTextChunk(LLMResponse response) {
  // 本来の is_filler 判定
  // 追加: 確認用に「調べ」を含む文も filler 扱いにする
  /*final isTestFiller =
      response.isFiller || response.text.contains('調べ');

  if (isTestFiller) {
    print('[ChatProvider] filler扱いなのでUIに表示しません: ${response.text}');
    return;
  }*/
  // is_filler=true の text_chunk は待機用メッセージ
  // 例: 「少し待って？」など。チャット欄には表示しない
  if (response.isFiller) {
    print('[ChatProvider] filler text_chunk はUIに表示しません: ${response.text}');
    return;
  }

  // tool_call の結果本文が届き始めたら、検索中表示を消す。
  // chat_end を待つと、答えが表示された後も
  // 「Tokyoの天気を調べています」が残ることがあるため。
  if (_toolStatus != null) {
    _toolStatus = null;
  }

  // まだAIの吹き出しが作られていない場合は、
  // 最初の text_chunk で新しいAIメッセージを作る
  if (_currentStreamingMessage == null) {
    _currentStreamingMessage = Message(
      role: MessageRole.assistant,
      text: response.text,
      timestamp: DateTime.now(),
      emotion: response.emotion,
      intensity: response.intensity,
      emotions: response.emotions,
      overallIntensity: response.overallIntensity,
    );
    // 作成したAIメッセージを会話履歴に追加する
    _messages.add(_currentStreamingMessage!);
  // すでにAIの吹き出しがある場合は、
  // 後続の text_chunk を既存の文章の後ろに追加する
  } else {
    _currentStreamingMessage = _currentStreamingMessage!.copyWith(
      text: _currentStreamingMessage!.text + response.text,
    );
     // List内の最後のAIメッセージを、追記後の内容に差し替える
    _messages[_messages.length - 1] = _currentStreamingMessage!;
  }

  notifyListeners();
}
  // ============================================================
  // error 処理
  // ============================================================
  // サーバーから error が届いた場合、エラーメッセージをチャット欄に表示する。
  // 途中のストリーミング状態や検索中表示もここで解除する。
  void _handleError(LLMResponse response) {
    _messages.add(Message(
      text: response.text.isNotEmpty ? response.text : 'エラーが発生しました',
      role: MessageRole.assistant,
      timestamp: DateTime.now(),
      emotion: 'sad',
      intensity: 0.5,
      emotions: const {'sad': 1.0},
      overallIntensity: 0.5,
    ));

    _isLoading = false;
    _currentStreamingMessage = null;
    _toolStatus = null;
    notifyListeners();
  }
 //最初に届く感情情報をUnityへ送る処理
 void _handleMetadata(LLMResponse response) {
  // metadata では本文はまだ来ていないため、チャット欄には何も追加しない
  // 先に届いた emotions / overallIntensity を Unity に送って表情へ反映する
    _unityBridge.sendEmotions(
      emotions: response.emotions,
      overallIntensity: response.overallIntensity,
    );

    // 前回の検索中表示が残らないように消す
    _toolStatus = null;
    // 画面側へ状態変更を通知する
    notifyListeners();
  }
  // ============================================================
  // Hot Reload 時のリセット処理
  // ============================================================
  // flutter run 中に r を押して Hot Reload したとき、
  // 通常は Provider の状態が残る。
  // 開発中は吹き出しを空にしたいため、ここで会話履歴などを初期化する。
  @override
  void reassemble() {
    _messages.clear();
    _currentStreamingMessage = null;
    _toolStatus = null;
    _isLoading = false;

    // 再生中・待機中の音声も止める
    unawaited(_audioQueue.reset());

    notifyListeners();
  }

  //メモリ圧迫の対策
  @override
  void dispose() {
    _stateSubscription?.cancel();
    // ChatProvider が破棄されるとき、音声プレイヤーも破棄する
    unawaited(_audioQueue.dispose());
    super.dispose();
  }
//{List<String>? images}の追加
  Future<void> sendUserMessage(String text, {List<String>? images, List<String>? filePaths}) async {
    // 新しい送信を始める前に、前回の音声・途中メッセージ・検索中表示をリセットする
    await _audioQueue.reset();
    _currentStreamingMessage = null;
    _toolStatus = null;
    // ─── 履歴への追加処理を追加 ───
    final userMessage = Message(
      text: text,
      role: MessageRole.user,
      timestamp: DateTime.now(),
      selectedImagePaths: filePaths, //受け取ったファイルパスをメッセージに記憶
    );
    _messages.add(userMessage);
    notifyListeners();
    // ────────────────────────────

    //サーバーが受け取るための画像配列を準備（中身がnullならからの配列に）
    //  修正：サーバーの仕様に合わせ、Base64文字列を [ { "data": "...", "media_type": "image/jpeg" } ] の構造に変換
    //image
    final List<Map<String, String>> targetImages = [];
    if (images != null) {
      for (final base64Data in images) {
        targetImages.add({
          'data': base64Data,
          'media_type': 'image/jpeg',//JPEG指定（一般的なカメラ・ギャラリー画像はこれで通る）
        });
      }
    }
    // ロード中状態に切り替える
    _isLoading = true;
    // ロード中状態に変わったことを画面側に知らせて、再描画させる
    notifyListeners();
    //直近の会話履歴を送る
    try {
      //20のmessageまで履歴に残す
      final recentHistory = _messages.length > 21
          ? _messages.sublist(_messages.length - 21, _messages.length - 1)
          : _messages.sublist(0, _messages.length - 1);
      //chatがかえってきているかの有無
      bool chatReceived = false;
      // 引数の images にtargetImages を渡します
      // AIに text・履歴・画像を送る
      // v2.2では返答が複数回に分かれて届くため、await for で順番に受け取る
      await for (final response in _llmService.sendMessage(
        text,
        history: recentHistory,
        images: targetImages,
      )) {

        _handleResponse(response);
        // チャット返答が来たか記録する
        if (response.isChat || response.isTextChunk || response.isChatEnd) {
          chatReceived = true;
        }
      }
      //もしfalseだったら
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
      //成功・失敗に関わらず必ず実行される後処理
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // ============================================================
  // サーバー応答の振り分け
  // ============================================================
  // RAiM v2.2では metadata / text_chunk / audio_chunk / tool_call / chat_end が届く。
  // ここで type を見て、それぞれ専用の処理へ渡す。
  void _handleResponse(LLMResponse response) {
    // metadata: 返答本文より先に届く感情・シーン情報
    if (response.isMetadata) {
      _handleMetadata(response);
    // text_chunk: AIの返答テキストが分割されて届く
    } else if (response.isTextChunk) {
      _handleTextChunk(response);
    // audio_chunk: サーバーで生成された音声データが届く
    } else if (response.isAudioChunk) {
      _handleAudioChunk(response);
    // tool_call: 検索などの外部処理が始まった通知
    } else if (response.isToolCall) {
      _handleToolCall(response);
    // chat_end: 1回分のAI返答が完了した通知
    }  else if (response.isBubbleBreak) {   // ← v2.3 追加
      _handleBubbleBreak(response); 
    } else if (response.isChatEnd) {
      _handleChatEnd(response);
    // chat: 古い形式の通常返答
    } else if (response.isChat) {
      _handleLegacyChat(response);
    // error: サーバー側エラー通知
    } else if (response.isError) {
      _handleError(response);
    // 想定していない type は落とさずログだけ出す
    } else {
      print('[ChatProvider] 未対応のメッセージ type: ${response.type}');
    }
  }
}