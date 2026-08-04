/// 会話スレッドに関するモデル
///
/// サーバー側は会話を「スレッド」単位で保存している。
/// 「新しい会話」ボタンから過去のスレッドを呼び戻せるようにするため、
/// 一覧（ThreadSummary）と履歴（ThreadMessage）の2つを扱う。
library;

/// スレッド一覧の1件
///
/// `{"type": "thread.list"}` を送ると `thread_list` で返ってくる要素。
/// 本文（messages）は含まれない。一覧表示に必要な情報だけを持つ。
class ThreadSummary {
  /// スレッド識別子。次の送信で threadId として送り返す
  final String threadId;

  /// 一覧に表示する名前
  ///
  /// サーバー側で2段階に決まる:
  ///   1. スレッド作成時 … 最初の発話を20文字で切ったもの
  ///   2. 要約生成後   … 要約の【事実】1件目に差し替え
  final String title;

  /// 最終更新日時（ISO8601）。一覧はこれの降順で返る
  final String updatedAt;

  /// 往復数。UI で「12往復」のように出せる
  final int turnCount;

  const ThreadSummary({
    required this.threadId,
    required this.title,
    required this.updatedAt,
    required this.turnCount,
  });

  factory ThreadSummary.fromJson(Map<String, dynamic> json) {
    return ThreadSummary(
      threadId: (json['threadId'] as String?) ?? '',
      title: (json['title'] as String?) ?? '新しい会話',
      updatedAt: (json['updatedAt'] as String?) ?? '',
      turnCount: (json['turnCount'] as num?)?.toInt() ?? 0,
    );
  }

  /// 「8月2日」のような表示用の文字列
  ///
  /// updatedAt をパースできない場合は空文字を返す（UI 側で出し分ける）。
  String get displayDate {
    final parsed = DateTime.tryParse(updatedAt);
    if (parsed == null) return '';

    final local = parsed.toLocal();
    final now = DateTime.now();

    // 今日なら時刻、それ以外は日付
    if (local.year == now.year &&
        local.month == now.month &&
        local.day == now.day) {
      return '${local.hour}:${local.minute.toString().padLeft(2, '0')}';
    }
    return '${local.month}月${local.day}日';
  }
}

/// スレッド履歴の1メッセージ
///
/// `{"type": "thread.history", "threadId": "..."}` を送ると
/// `thread_history` で返ってくる要素。古い順（時系列）に並んでいる。
class ThreadMessage {
  /// 'user' または 'assistant'
  final String role;

  /// 発話本文
  final String text;

  /// 画像を送ったときの説明文
  ///
  /// 画像そのものは保存されない（サイズが大きいため）。
  /// マルチモーダルで生成された説明文だけが残る。
  final String? imageDescription;

  /// ライムの発話のみ入る。過去の表情を復元したい場合に使える
  final Map<String, double>? emotions;

  /// 発話日時（ISO8601）
  final String createdAt;

  const ThreadMessage({
    required this.role,
    required this.text,
    this.imageDescription,
    this.emotions,
    required this.createdAt,
  });

  bool get isUser => role == 'user';

  factory ThreadMessage.fromJson(Map<String, dynamic> json) {
    Map<String, double>? emotions;
    final raw = json['emotions'];
    if (raw is Map) {
      emotions = <String, double>{};
      raw.forEach((key, value) {
        if (value is num) emotions![key.toString()] = value.toDouble();
      });
      if (emotions.isEmpty) emotions = null;
    }

    return ThreadMessage(
      role: (json['role'] as String?) ?? 'user',
      text: (json['text'] as String?) ?? '',
      imageDescription: json['imageDescription'] as String?,
      emotions: emotions,
      createdAt: (json['createdAt'] as String?) ?? '',
    );
  }

  /// 画面に出す本文
  ///
  /// 画像付きの発話は、画像本体が無いので説明文を併記する。
  String get displayText {
    if (imageDescription == null || imageDescription!.isEmpty) {
      return text;
    }
    if (text.isEmpty) {
      return '[画像: $imageDescription]';
    }
    return '$text\n[画像: $imageDescription]';
  }
}

/// thread_history の応答全体
class ThreadHistory {
  final String threadId;
  final String title;
  final List<ThreadMessage> messages;

  /// 返した中で最も古いメッセージの位置
  ///
  /// さらに古い分を取るとき、これを beforeIndex として送り返す。
  final int startIndex;

  /// さらに古いメッセージが存在するか
  ///
  /// サーバーは1回の応答で一定量しか返さない。
  /// true の場合は startIndex を beforeIndex として送ると続きが取れる。
  final bool hasMore;

  /// スレッドの全メッセージ数
  final int totalMessages;

  const ThreadHistory({
    required this.threadId,
    required this.title,
    required this.messages,
    required this.startIndex,
    required this.hasMore,
    required this.totalMessages,
  });

  factory ThreadHistory.fromJson(Map<String, dynamic> json) {
    final rawMessages = json['messages'];
    final messages = <ThreadMessage>[];

    if (rawMessages is List) {
      for (final item in rawMessages) {
        if (item is Map<String, dynamic>) {
          messages.add(ThreadMessage.fromJson(item));
        } else if (item is Map) {
          messages.add(ThreadMessage.fromJson(
            item.map((k, v) => MapEntry(k.toString(), v)),
          ));
        }
      }
    }

    return ThreadHistory(
      threadId: (json['threadId'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      messages: messages,
      startIndex: (json['startIndex'] as num?)?.toInt() ?? 0,
      hasMore: (json['hasMore'] as bool?) ?? false,
      totalMessages: (json['totalMessages'] as num?)?.toInt() ?? messages.length,
    );
  }
}
