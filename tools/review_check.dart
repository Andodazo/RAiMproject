// レビュー課題の確認テストを、番号を指定して動かす。
//
//   dart run tools/review_check.dart 3        … 課題3だけ
//   dart run tools/review_check.dart 1 4 6    … いくつか
//   dart run tools/review_check.dart all      … 全部
//
// 中で `flutter test test/review/item<番号>_*.dart` を動かしているだけなので、
// 直接 flutter test で動かしても同じ。

import 'dart:io';

const items = <int, String>{
  1: 'ログアウトで前の人の会話・会話ID・一覧・画像を消す',
  2: 'トークン更新とログアウトが重なってもトークンを書き戻さない',
  3: '古いメッセージの読み込み中に会話を切り替えても混ざらない',
  4: '返事の途中でエラーになったら途中の文を消し、声を止める',
  5: '配布版で接続先の切り替えを出さない・トークンを付ける相手をホスト名で決める',
  6: '画像は4枚まで（サーバーとそろえる）',
  7: 'Unity のログに会話の中身を出さない',
  8: '鍵が無ければ release を作らない',
  9: '展示モードと駅アラームの録音を消す',
};

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    _usage();
    exit(64);
  }

  final targets = <int>[];
  for (final arg in args) {
    if (arg == 'all') {
      targets.addAll(items.keys);
      continue;
    }
    final n = int.tryParse(arg);
    if (n == null || !items.containsKey(n)) {
      stderr.writeln('「$arg」という課題はありません。');
      _usage();
      exit(64);
    }
    targets.add(n);
  }

  final dir = Directory('test/review');
  if (!dir.existsSync()) {
    stderr.writeln('test/review がありません。プロジェクトの直下で動かしてください。');
    exit(66);
  }

  final results = <int, bool>{};
  for (final n in targets.toSet().toList()..sort()) {
    final file = dir
        .listSync()
        .whereType<File>()
        .map((f) => f.path.replaceAll('\\', '/'))
        .firstWhere(
          (p) => RegExp('/item${n}_.*_test\\.dart\$').hasMatch(p),
          orElse: () => '',
        );
    if (file.isEmpty) {
      stderr.writeln('課題$n のテストファイルが見つかりません。');
      results[n] = false;
      continue;
    }

    stdout.writeln('');
    stdout.writeln('==== 課題$n: ${items[n]}');
    final process = await Process.start(
      'flutter',
      ['test', file],
      runInShell: true,
      mode: ProcessStartMode.inheritStdio,
    );
    results[n] = await process.exitCode == 0;
  }

  stdout.writeln('');
  stdout.writeln('==== 結果');
  for (final entry in results.entries) {
    stdout.writeln('  ${entry.value ? 'OK  ' : 'だめ'} 課題${entry.key}: ${items[entry.key]}');
  }
  exit(results.values.every((ok) => ok) ? 0 : 1);
}

void _usage() {
  stdout.writeln('使い方: dart run tools/review_check.dart <番号…|all>');
  for (final entry in items.entries) {
    stdout.writeln('  ${entry.key}: ${entry.value}');
  }
}
