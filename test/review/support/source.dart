// レビュー課題のテストで、ソースを読んで確かめるための道具。
//
// 画面のボタンやビルドの設定のように、テストから動かしにくいところは
// 「そのコードがあるか」「消えているか」を見て確かめる。

import 'dart:io';

/// プロジェクトのファイルを読む（flutter test はプロジェクトの直下で動く）
String readSource(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError('$path がありません');
  }
  return file.readAsStringSync();
}

/// [marker] を含むメソッド（関数）の本体を、すべて返す。
///
/// `) {` や `) async {` の直後の `{` をメソッドの始まりとみなす。
/// if や try のかっこは飛ばして、いちばん内側のメソッドまでさかのぼる。
List<String> methodBodiesContaining(String source, String marker) {
  final bodies = <String>[];
  var from = 0;
  while (true) {
    final at = source.indexOf(marker, from);
    if (at < 0) break;
    from = at + marker.length;
    final body = _enclosingMethodBody(source, at);
    if (body != null && !bodies.contains(body)) bodies.add(body);
  }
  return bodies;
}

String? _enclosingMethodBody(String source, int position) {
  var depth = 0;
  for (var i = position; i >= 0; i--) {
    final c = source[i];
    if (c == '}') {
      depth++;
    } else if (c == '{') {
      if (depth > 0) {
        depth--;
        continue;
      }
      // いちばん内側の開きかっこ。メソッドの始まりか確かめる
      final before = source.substring(0, i).trimRight();
      final isMethod = RegExp(r'\)\s*(async\*?|sync\*)?$').hasMatch(before) &&
          !RegExp(r'\b(if|for|while|switch|catch)\s*\([^()]*(\([^()]*\)[^()]*)*\)\s*$')
              .hasMatch(before);
      if (!isMethod) continue;
      final end = _matchingBrace(source, i);
      if (end == null) return null;
      return source.substring(i, end + 1);
    }
  }
  return null;
}

/// [signature]（例: ` switchServer(`。最後は `(` にする）で始まるメソッドの本体を返す。
/// 引数のかっこ（`{String? x}` のような名前付き引数も）を飛ばしてから本体を探す。無ければ null
String? methodBodyAfter(String source, String signature) {
  var from = 0;
  while (true) {
    final at = source.indexOf(signature, from);
    if (at < 0) return null;
    from = at + signature.length;
    // 引数の閉じかっこを探す
    var depth = 0;
    var close = -1;
    for (var i = at + signature.length - 1; i < source.length; i++) {
      if (source[i] == '(') depth++;
      if (source[i] == ')') {
        depth--;
        if (depth == 0) {
          close = i;
          break;
        }
      }
    }
    if (close < 0) return null;
    // 閉じかっこのあとが `{` か `async {` なら定義。`;` や `,` なら呼び出しなので次を探す
    final rest = source.substring(close + 1);
    final head = RegExp(r'^\s*(async\*?|sync\*)?\s*\{').firstMatch(rest);
    if (head == null) continue;
    final open = close + head.end;
    final end = _matchingBrace(source, open);
    if (end == null) return null;
    return source.substring(open, end + 1);
  }
}

int? _matchingBrace(String source, int open) {
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    final c = source[i];
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return null;
}

/// フォルダの中のファイルを（下の階層も含めて）列挙する
Iterable<File> filesUnder(String dir, {Set<String> extensions = const {}}) sync* {
  final root = Directory(dir);
  if (!root.existsSync()) return;
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final path = entity.path.replaceAll('\\', '/');
    if (path.contains('/.dart_tool/') || path.contains('/build/')) continue;
    if (extensions.isNotEmpty &&
        !extensions.any((ext) => path.toLowerCase().endsWith(ext))) {
      continue;
    }
    yield entity;
  }
}

/// [pattern] に当たる行を「ファイル:行番号: 行」の形で返す
List<String> findLines(Iterable<File> files, RegExp pattern) {
  final hits = <String>[];
  for (final file in files) {
    List<String> lines;
    try {
      lines = file.readAsLinesSync();
    } catch (_) {
      continue; // 文字コードが違う・画像などは飛ばす
    }
    for (var i = 0; i < lines.length; i++) {
      if (pattern.hasMatch(lines[i])) {
        hits.add('${file.path.replaceAll('\\', '/')}:${i + 1}: ${lines[i].trim()}');
      }
    }
  }
  return hits;
}
