// ライムが覚えていることの表示と、忘れさせる操作。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/models/raim_memory.dart';
import 'package:raim_prototype/widgets/memory_panel.dart';

class _FakeMemory implements MemoryService {
  _FakeMemory(this.memory, {this.failFetch = false});

  RaimMemory memory;
  final bool failFetch;
  final forgotten = <List<String>>[];
  int forgotAll = 0;

  @override
  Future<RaimMemory> fetchMemory() async {
    if (failFetch) throw Exception('offline');
    return memory;
  }

  @override
  Future<RaimMemory> forgetMemory({
    List<String> items = const [],
    bool all = false,
  }) async {
    if (all) {
      forgotAll++;
      memory = const RaimMemory();
    } else {
      forgotten.add(items);
      memory = RaimMemory(
        facts: memory.facts.where((f) => !items.contains(f)).toList(),
        relationship: memory.relationship.where((r) => !items.contains(r)).toList(),
      );
    }
    return memory;
  }
}

Widget _host(MemoryService service) => MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: MemoryPanel(service: service, showTitle: true),
      ),
    );

void main() {
  const memory = RaimMemory(
    facts: ['卒業制作でアプリを作っている', '猫を飼っている'],
    relationship: ['制作の話になると楽しそうな様子'],
  );

  testWidgets('覚えていることを、話したことと感じたことに分けて出す', (tester) async {
    await tester.pumpWidget(_host(_FakeMemory(memory)));
    await tester.pumpAndSettle();

    expect(find.text('話してくれたこと'), findsOneWidget);
    expect(find.text('ライムが感じたこと'), findsOneWidget);
    expect(find.text('猫を飼っている'), findsOneWidget);
    expect(find.text('制作の話になると楽しそうな様子'), findsOneWidget);
  });

  testWidgets('× を押して確かめてから、その項目だけ忘れさせる', (tester) async {
    final service = _FakeMemory(memory);
    await tester.pumpWidget(_host(service));
    await tester.pumpAndSettle();

    // 2つ目（猫）の × を押す
    await tester.tap(find.byTooltip('忘れさせる').at(1));
    await tester.pumpAndSettle();
    expect(find.text('これを忘れさせますか？元に戻せません。'), findsOneWidget);
    // 確かめるまでは消さない
    expect(service.forgotten, isEmpty);

    await tester.tap(find.widgetWithText(TextButton, '忘れさせる'));
    await tester.pumpAndSettle();

    expect(service.forgotten, [
      ['猫を飼っている'],
    ]);
    expect(find.text('猫を飼っている'), findsNothing);
    expect(find.text('卒業制作でアプリを作っている'), findsOneWidget);
  });

  testWidgets('「やめる」なら何も消さない', (tester) async {
    final service = _FakeMemory(memory);
    await tester.pumpWidget(_host(service));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('忘れさせる').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('やめる'));
    await tester.pumpAndSettle();

    expect(service.forgotten, isEmpty);
    expect(find.text('これを忘れさせますか？元に戻せません。'), findsNothing);
  });

  testWidgets('全部忘れさせると、まだ何も覚えていない表示になる', (tester) async {
    final service = _FakeMemory(memory);
    await tester.pumpWidget(_host(service));
    await tester.pumpAndSettle();

    await tester.tap(find.text('全部忘れさせる'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '忘れさせる'));
    await tester.pumpAndSettle();

    expect(service.forgotAll, 1);
    expect(find.textContaining('まだ覚えていることはありません'), findsOneWidget);
  });

  testWidgets('読めなかったら、もう一度読めるようにする', (tester) async {
    await tester.pumpWidget(_host(_FakeMemory(memory, failFetch: true)));
    await tester.pumpAndSettle();

    expect(find.text('読み込めませんでした'), findsOneWidget);
    expect(find.text('もう一度'), findsOneWidget);
  });
}
