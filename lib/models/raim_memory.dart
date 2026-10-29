// lib/models/raim_memory.dart
//
// ライムが覚えていること（サーバーの userMemory）。
//
// サーバーは会話の要約から「この人はどんな人か」をまとめて覚えている。
// 【事実】（利用者が話したこと）と【関係性】（会話の雰囲気から感じたこと）に分かれる。

class RaimMemory {
  const RaimMemory({
    this.facts = const [],
    this.relationship = const [],
    this.updatedAt,
  });

  /// 利用者がはっきり話したこと（「卒業制作でアプリを作っている」など）
  final List<String> facts;

  /// 会話の雰囲気から感じたこと（「制作の話になると楽しそうな様子」など）
  final List<String> relationship;

  /// 最後に覚え直した時刻。まだ何も覚えていなければ null
  final DateTime? updatedAt;

  bool get isEmpty => facts.isEmpty && relationship.isEmpty;

  factory RaimMemory.fromJson(Map<String, dynamic> json) {
    List<String> strings(Object? value) => value is List
        ? value.whereType<String>().where((s) => s.trim().isNotEmpty).toList()
        : const [];
    return RaimMemory(
      facts: strings(json['facts']),
      relationship: strings(json['relationship']),
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? ''),
    );
  }
}

/// 覚えていることを読んだり消したりできるサービス。
///
/// 画面のテストで偽物に差し替えられるよう、RaimServerService と分けている。
abstract class MemoryService {
  Future<RaimMemory> fetchMemory();

  /// [items] の項目を消す。[all] が true なら全部消す。消したあとの内容を返す。
  Future<RaimMemory> forgetMemory({List<String> items = const [], bool all = false});
}
