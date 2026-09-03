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
import 'package:raim_prototype/models/conversation_thread.dart';
import 'package:raim_prototype/services/llm_service.dart';
import 'package:raim_prototype/services/raim_server_service.dart';
import 'package:raim_prototype/services/audio_play_queue.dart';
import 'package:raim_prototype/services/audio_chunk_assembler.dart';
import 'package:raim_prototype/services/unity_communicator.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:raim_prototype/providers/camera_provider.dart';
import 'package:raim_prototype/services/raim_log.dart';

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
  late final AudioChunkAssembler _audioAssembler;
  //messagesとは描画する会話をまとめたもの

  // ============================================================
  // チャット画面の状態
  // ============================================================
  // _messages は画面に表示する会話履歴。
  // _isLoading はAI返答待ち状態。
  // _currentStreamingMessage は text_chunk を追記中のAIメッセージ。
  final List<Message> _messages = [];

  // ─── 会話スレッド ───
  //
  // サーバーは会話を「スレッド」単位で保存している。
  // threadId を送ると同じスレッドに追記され、送らなければ
  // サーバー側が「現在アクティブなスレッド」を使う。

  /// 現在開いているスレッド。chat_end で受け取って保持する
  String? _currentThreadId;

  /// スレッド一覧（プルダウン表示用）
  List<ThreadSummary> _threads = [];

  /// 一覧・履歴の取得中か
  bool _isLoadingThreads = false;

  /// 一覧・履歴の取得に失敗したときの理由（UI 表示用）
  String? _threadError;

  // ─── 履歴の遡り ───
  //
  // サーバーは1回の応答で一定量しか返さない（WebSocket の送信上限のため）。
  // 続きを取るには、前回返ってきた startIndex を beforeIndex として送る。

  /// 次に遡るときの位置。null なら遡る先が無い
  int? _historyCursor;

  /// さらに古いメッセージが残っているか
  bool _hasMoreHistory = false;

  /// 遡り読み込み中か（重複実行の防止も兼ねる）
  bool _isLoadingOlder = false;
  bool _isLoading = false;
  Message? _currentStreamingMessage;
  bool _isUsingTool = false;
  // 追加: metadata受信中かどうかを管理する
  bool _isThinking = false;
  // 追加: 画面側で「考え中」状態を取得するためのGetter
  bool get isThinking => _isThinking;
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
    _audioAssembler = AudioChunkAssembler(
      onAudioReady: (audio) {
        // キューは1つの AudioPlayer で直列に鳴らすので、
        // 前の返答の言い残しと重なることはない。後ろに並ぶだけ。
        _audioQueue.enqueueBytes(bytes: audio.bytes, format: audio.format);
      },
    );
    _bindConnectionState();
  }
  //メッセージの中身を編集されないようにするため。(読み取り専用)
  List<Message> get messages => List.unmodifiable(_messages);
  String? get currentThreadId => _currentThreadId;
  List<ThreadSummary> get threads => List.unmodifiable(_threads);
  bool get isLoadingThreads => _isLoadingThreads;
  String? get threadError => _threadError;
  bool get hasMoreHistory => _hasMoreHistory;
  bool get isLoadingOlder => _isLoadingOlder;
  bool get isLoading => _isLoading;
  String? get toolStatus => _toolStatus;
  RaimConnectionState get connectionState => _connectionState;
  bool get isUsingTool => _isUsingTool;

  /// 「寝てる」状態か（UI で立ち絵切替などに使用予定）
  bool get isOffline => _connectionState == RaimConnectionState.offline;
  void _bindConnectionState() {
    // RaimServerService の場合のみ接続状態を購読
    //websocketだから変更箇所をリアルタイムで確認するため
    if (_llmService is RaimServerService) {
      final service = _llmService;
      _connectionState = service.state;
      _stateSubscription = service.stateStream.listen((newState) {
        final wasConnected = _connectionState == RaimConnectionState.connected;
        _connectionState = newState;
        if (newState != RaimConnectionState.connected) {
          _audioAssembler.reset();
          unawaited(_audioQueue.reset());
        }
        notifyListeners();

        // 接続できた時点で、前回の続きから始められるようにする。
        //
        // サーバー側は activeThreadId を覚えているので、何もしなくても
        // 会話自体は前のスレッドに続く。ただし画面は空のままなので、
        // ユーザーからは「忘れられた」ように見える。
        // そこで最後に使ったスレッドの履歴を読み込んで表示する。
        if (!wasConnected && newState == RaimConnectionState.connected) {
          _restoreLastThread();
        }
      });
    }
  }
  //返答完了時の後片付け
  void _handleChatEnd(LLMResponse response) {
    // 追加: 応答終了時に全ての待機状態を解除する
    _isThinking = false;
    _isUsingTool = false;

    // スレッド識別子を保持する。
    // 新規作成された場合もここで採番結果が分かるため、
    // 次回の送信でこれを送り返すと同じスレッドに追記される。
    if (response.threadId != null && response.threadId!.isNotEmpty) {
      if (_currentThreadId != response.threadId) {
        RaimLog.d('[ChatProvider] スレッド確定: ${response.threadId}');
      }
      _currentThreadId = response.threadId;
    }
    // tool_call では検索などの外部処理中であることが通知される
    // description があればそれを表示し、無ければデフォルト文を表示する
    if (_currentStreamingMessage != null) {
    _replaceStreamingMessage(
      _currentStreamingMessage!.copyWith(
        emotion: response.emotion,
        intensity: response.intensity,
        emotions: response.emotions,
        overallIntensity: response.overallIntensity,
      ),
    );
  }
    // Tool使用終了
    _isUsingTool = false;
    // Tool使用終了をUnityへ通知
    // currentStreamingMessage が null の場合でも必ず送信する
    _unityBridge.sendToolState(
      isUsingTool: false,
    );

    // chat_end で届いた最終感情をUnityへ反映する
    _unityBridge.sendEmotions(
      emotions: response.emotions,
      overallIntensity: response.overallIntensity,
    );

    // 追加: 吹き出しの消去タイマーを開始させる（Windows版のみ効く）
    _unityBridge.sendChatEnd(fullText: response.fullText);

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
     // Tool使用開始時は「考え中」表示を終了する
    _isThinking = false;
    // Toolの説明文を画面に表示する
     RaimLog.d('[ChatProvider] Tool使用開始');
     // tool_call では検索などの外部処理中であることが通知される
    // description があればそれを表示し、無ければデフォルト文を表示する

    // Tool使用中にする
    _isUsingTool = true;

    _toolStatus = response.description ?? '調べています...';
      // UnityへTool使用開始を通知
    _unityBridge.sendToolState(
      isUsingTool: true,
      description: response.description,
    );
    _isLoading = true;
    notifyListeners();
  }
  //音声Base64を再生キューに入れる処理
  void _handleAudioChunk(LLMResponse response) {
     // audio が空の場合は再生できないため、何もせず終了する
    if (response.audioBase64 == null || response.audioBase64!.isEmpty) {
      RaimLog.d('[ChatProvider] audio_chunk 受信: audio が空です');
      return;
    }

    // 音声データは長いので、ログには中身ではなく長さだけ出す
    RaimLog.d(
      '[ChatProvider] audio_chunk を再生キューに追加: '
      'chunkId=${response.chunkId}, '
      'format=${response.format ?? 'wav'}, '
      'audioLength=${response.audioBase64!.length}',
    );

    _audioAssembler.add(
      AudioChunkPart(
        chunkId: response.chunkId,
        audioBase64: response.audioBase64!,
        format: response.format ?? 'wav',
        partIndex: response.partIndex,
        partCount: response.partCount,
        isLast: response.isLast,
        isFirst: response.isFirst,
      ),
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
    RaimLog.d('[ChatProvider] bubble_break 受信: 次の text_chunk は新規吹き出しにする');
    // 現在のストリーミング吹き出しを区切る
    _currentStreamingMessage = null;
    _unityBridge.sendBubbleBreak();
    // notifyListeners は不要（UI 変化なし）
  }
  //分割された文章を吹き出しに追加していく処理
  void _handleTextChunk(LLMResponse response) {
  // 本来の is_filler 判定
  // 追加: 確認用に「調べ」を含む文も filler 扱いにする
  /*final isTestFiller =
      response.isFiller || response.text.contains('調べ');

  if (isTestFiller) {
    RaimLog.d('[ChatProvider] filler扱いなのでUIに表示しません '
        '${RaimLog.size(response.text)}');
    return;
  }*/
  // is_filler=true の text_chunk は待機用メッセージ
  // 例: 「少し待って？」など。チャット欄には表示しない
  if (response.isFiller) {
    RaimLog.d('[ChatProvider] filler text_chunk はUIに表示しません '
        '${RaimLog.size(response.text)}');
    return;
  }
  // 追加: 通常の本文が届いたら「考え中」表示を終了する
_isThinking = false;
// 追加: 本文が届いたためTool使用状態も終了する
_isUsingTool = false;
// 追加: 検索中の表示を終了する
_toolStatus = null;

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
    _replaceStreamingMessage(
      _currentStreamingMessage!.copyWith(
        text: _currentStreamingMessage!.text + response.text,
      ),
    );
  }
  _unityBridge.sendText(text: response.text);
  notifyListeners();
}
  // ============================================================
  // error 処理
  // ============================================================
  // サーバーから error が届いた場合、エラーメッセージをチャット欄に表示する。
  // 途中のストリーミング状態や検索中表示もここで解除する。
  void _handleError(LLMResponse response) {
     // 追加: エラー時も「考え中」表示を終了する
    _isThinking = false;
    _isUsingTool = false;
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
  // 追加: metadata受信時に「考え中」表示を開始する
  _isThinking = true;
  // metadata受信時点では、まだToolは使用していない
  _isUsingTool = false;
  // 前回のTool表示が残らないようにリセットする
  _toolStatus = null;
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

  // ==========================================================================
  // 会話スレッドの操作
  // ==========================================================================

  /// スレッド一覧を読み込む
  ///
  /// 「新しい会話」ボタンを押したときに呼ぶ。
  /// 失敗しても例外は投げず、一覧を空のままにする（会話は続けられる）。
  Future<void> loadThreads() async {
    final service = _llmService;
    if (service is! RaimServerService) {
      RaimLog.d('[ChatProvider] スレッド一覧は RaimServerService でのみ利用できます');
      return;
    }

    _isLoadingThreads = true;
    _threadError = null;
    notifyListeners();

    try {
      _threads = await service.fetchThreadList();
      RaimLog.d('[ChatProvider] スレッド一覧: ${_threads.length}件');
    } catch (e) {
      RaimLog.d('[ChatProvider] スレッド一覧の取得に失敗: $e');
      _threads = [];
      _threadError = '会話一覧を読み込めませんでした';
    } finally {
      _isLoadingThreads = false;
      notifyListeners();
    }
  }

  /// 過去のスレッドを開く
  ///
  /// 画面のメッセージを、そのスレッドの履歴で置き換える。
  /// サーバーは直近50件しか返さないため、それより古いやり取りは表示されない
  /// （ライム側の文脈としては引き継がれている）。
  Future<void> switchThread(String threadId) async {
    final service = _llmService;
    if (service is! RaimServerService) return;
    if (threadId.isEmpty || threadId == _currentThreadId) return;

    _audioAssembler.reset();
    await _audioQueue.reset();

    _isLoadingThreads = true;
    notifyListeners();

    try {
      final history = await service.fetchThreadHistory(threadId);

      _currentThreadId = threadId;
      _messages.clear();
      _currentStreamingMessage = null;

      if (history != null) {
        _historyCursor = history.hasMore ? history.startIndex : null;
        _hasMoreHistory = history.hasMore;

        _messages.addAll(history.messages.map(_toMessage));
        RaimLog.d(
          '[ChatProvider] スレッド切替: $threadId '
          '(${history.messages.length}/${history.totalMessages}件, '
          'hasMore=${history.hasMore})',
        );
      }
    } catch (e) {
      RaimLog.d('[ChatProvider] スレッド切替に失敗: $e');
      _threadError = '会話を開けませんでした';
    } finally {
      _isLoadingThreads = false;
      notifyListeners();
    }
  }

  /// スレッドを削除する
  ///
  /// 削除したのが今開いているスレッドだった場合は、
  /// 画面をクリアして新しい会話に切り替える
  /// （消したスレッドを開いたままにしておくと、次の発話が
  ///  存在しない threadId へ送られて復活してしまうため）。
  Future<void> deleteThread(String threadId) async {
    final service = _llmService;
    if (service is! RaimServerService) return;
    if (threadId.isEmpty) return;

    _isLoadingThreads = true;
    _threadError = null;
    notifyListeners();

    try {
      await service.deleteThread(threadId);

      _threads = _threads.where((t) => t.threadId != threadId).toList();

      if (_currentThreadId == threadId) {
        startNewThread();
      }

      RaimLog.d('[ChatProvider] スレッド削除: $threadId');
    } catch (e) {
      RaimLog.d('[ChatProvider] スレッド削除に失敗: $e');
      _threadError = '会話を削除できませんでした';
    } finally {
      _isLoadingThreads = false;
      notifyListeners();
    }
  }

  /// 起動直後に、最後に話していたスレッドを開く
  ///
  /// 一覧は更新が新しい順なので、先頭が直近のスレッドになる。
  /// すでにスレッドを開いている場合や、会話中の場合は何もしない。
  Future<void> _restoreLastThread() async {
    if (_currentThreadId != null) return;
    if (_messages.isNotEmpty) return;
    if (_isLoading) return;

    try {
      await loadThreads();

      if (_threads.isEmpty) return;
      if (_currentThreadId != null || _messages.isNotEmpty) return;

      await switchThread(_threads.first.threadId);
      // タイトルは会話内容から作られるためログに出さない
      RaimLog.d('[ChatProvider] 前回の会話を復元: ${_threads.first.threadId}');
    } catch (e) {
      // 復元に失敗しても新規会話として続けられるので、黙って諦める
      RaimLog.d('[ChatProvider] 前回の会話を復元できませんでした: $e');
    }
  }

  /// さらに古いメッセージを読み込む
  ///
  /// 画面を上へスクロールしきったときに呼ぶ。
  /// 取得したぶんはメッセージ一覧の先頭へ差し込む。
  Future<void> loadOlderMessages() async {
    final service = _llmService;
    if (service is! RaimServerService) return;

    final threadId = _currentThreadId;
    final cursor = _historyCursor;

    // 遡る先が無い、または読み込み中なら何もしない
    if (threadId == null || cursor == null || cursor <= 0) return;
    if (_isLoadingOlder) return;

    _isLoadingOlder = true;
    notifyListeners();

    try {
      final history = await service.fetchThreadHistory(
        threadId,
        beforeIndex: cursor,
      );

      if (history != null && history.messages.isNotEmpty) {
        final older = history.messages.map(_toMessage).toList();

        // 古い方を先頭へ差し込む
        _messages.insertAll(0, older);

        _historyCursor = history.hasMore ? history.startIndex : null;
        _hasMoreHistory = history.hasMore;

        RaimLog.d(
          '[ChatProvider] 過去メッセージを追加: ${older.length}件 '
          '(startIndex=${history.startIndex}, hasMore=${history.hasMore})',
        );
      } else {
        _historyCursor = null;
        _hasMoreHistory = false;
      }
    } catch (e) {
      RaimLog.d('[ChatProvider] 過去メッセージの取得に失敗: $e');
    } finally {
      _isLoadingOlder = false;
      notifyListeners();
    }
  }

  /// 履歴のメッセージを画面用の Message へ変換する
  Message _toMessage(ThreadMessage m) {
    final dominantEmotion = (m.emotions != null && m.emotions!.isNotEmpty)
        ? m.emotions!.entries
            .reduce((a, b) => a.value >= b.value ? a : b)
            .key
        : 'neutral';

    return Message(
      text: m.displayText,
      role: m.isUser ? MessageRole.user : MessageRole.assistant,
      timestamp: DateTime.tryParse(m.createdAt) ?? DateTime.now(),
      emotion: m.isUser ? null : dominantEmotion,
      emotions: m.emotions ?? const {'neutral': 1.0},
    );
  }

  /// 新しい会話を始める
  ///
  /// クライアント側で識別子を採番して送る。サーバーは未知の threadId を
  /// 受け取るとその ID でスレッドを新規作成するため、専用の API は要らない。
  void startNewThread() {
    _audioAssembler.reset();
    unawaited(_audioQueue.reset());
    _currentThreadId = _generateThreadId();
    _historyCursor = null;
    _hasMoreHistory = false;
    _messages.clear();
    _currentStreamingMessage = null;
    _isLoading = false;
    _isThinking = false;
    _isUsingTool = false;
    _toolStatus = null;

    RaimLog.d('[ChatProvider] 新しい会話: $_currentThreadId');
    notifyListeners();
  }

  /// スレッド識別子を作る
  ///
  /// サーバー側は未知の threadId を受け取るとその ID でスレッドを作るため、
  /// クライアントが採番してよい。
  String _generateThreadId() => 'thread-${const Uuid().v4()}';
  @override
  void reassemble() {
    _audioAssembler.reset();
    _messages.clear();
    _currentStreamingMessage = null;
    _toolStatus = null;
    _isLoading = false;
    // 追加: Hot Reload時に状態をリセットする
    _isThinking = false;
    _isUsingTool = false;

    // 再生中・待機中の音声も止める
    unawaited(_audioQueue.reset());

    notifyListeners();
  }

  //メモリ圧迫の対策
  @override
  void dispose() {
    _stateSubscription?.cancel();
    _audioAssembler.dispose();
    // ChatProvider が破棄されるとき、音声プレイヤーも破棄する
    unawaited(_audioQueue.dispose());
    super.dispose();
  }
//{List<String>? images}の追加
  /// ストリーミング中のメッセージを差し替える。
  ///
  /// 以前は `_messages[_messages.length - 1]` と末尾決め打ちだったため、
  /// スレッド切替で _messages が空になった直後にチャンクが届くと
  /// index -1 で RangeError になり、末尾が別のメッセージに入れ替わって
  /// いる場合は無関係な発言を上書きしていた。
  /// 同一インスタンスを探して置き換え、見つからなければ何もしない。
  void _replaceStreamingMessage(Message updated) {
    final current = _currentStreamingMessage;
    if (current == null) return;

    final index = _messages.lastIndexWhere((m) => identical(m, current));
    if (index < 0) {
      // 画面が切り替わるなどで対象が消えている。積み直さずに諦める。
      _currentStreamingMessage = null;
      return;
    }

    _messages[index] = updated;
    _currentStreamingMessage = updated;
  }

  /// 一度に送れる画像の合計サイズ（Base64 の文字数）
  ///
  /// 上限が無いと巨大 payload でサーバー側に弾かれるか、
  /// 端末側のメモリを圧迫する。
  static const int maxTotalImageBase64Chars = 4 * 1024 * 1024;

  Future<void> sendUserMessage(String text, {List<String>? images, List<String>? filePaths}) async {
    // 応答の生成中は新しい送信を受け付けない。
    // 受け付けると2つの応答が同じ吹き出しに混ざり、
    // 片方の chat_end でもう片方が打ち切られる。
    if (_isLoading) {
      RaimLog.d('[ChatProvider] 応答生成中のため送信を無視しました');
      return;
    }

    // 新しい送信を始める前に、途中メッセージと検索中表示をリセットする。
    //
    // 音声は即座に切らない。文の途中でブツッと切れると会話として不自然なので、
    // 今喋っている1文だけ言い切らせて、待機中のぶんを捨てる。
    // 生成に数秒かかるため、その1文は新しい音声が届く前に鳴り終わる。
    // 万一残っていてもキューは直列なので、重ならず後ろに並ぶだけ。
    _audioAssembler.reset();
    _audioQueue.stopAfterCurrent();
    _currentStreamingMessage = null;
    _toolStatus = null;
    // ここに追加
    _isThinking = false;
    _isUsingTool = false;
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
      var totalChars = 0;
      for (final base64Data in images) {
        if (targetImages.length >= CameraProvider.maxImageCount) {
          RaimLog.w('[ChatProvider] 画像の枚数上限を超えたぶんは送りません');
          break;
        }
        if (totalChars + base64Data.length > maxTotalImageBase64Chars) {
          RaimLog.w('[ChatProvider] 画像の合計サイズ上限を超えたぶんは送りません');
          break;
        }
        totalChars += base64Data.length;
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
        threadId: _currentThreadId,
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
      RaimLog.d('[ChatProvider] 未対応のメッセージ type: ${response.type}');
    }
  }
}
