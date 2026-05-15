# Dart 文法ガイド（TypeScript経験者向け）

## このドキュメントについて

TypeScript経験者がDart/Flutterのコードを読み書きするための文法ガイド。

RAiMプロジェクトで実際に使う文法を中心に、TypeScriptとの違いを明示してまとめてある。
「TSのアレと同じ」「ここはTSと違う」が分かれば、Dartはすぐ書けるようになる。

---

## 全体像：DartとTypeScript

似ているところ：

- クラスベースのオブジェクト指向
- 強い静的型付け
- async/await による非同期処理
- ジェネリクス
- null安全性（Dartは比較的最近導入された）

違うところ：

- Dartは**型推論が控えめ**（明示的に書くことが多い）
- インスタンス化に `new` キーワードは**不要**（書いてもOK、省略推奨）
- セミコロン `;` **必須**（TSは省略可だがDartは必須）
- `interface` キーワードは**ない**（abstract classで代用）
- import文の書き方が違う

---

## 変数宣言

### `final` — 再代入不可（実行時定数）

```dart
final String name = "RAiM";
final age = 20;  // 型推論もできる
```

TS対応:
```typescript
const name: string = "RAiM";
```

**`final` は TSの `const` に相当**。
ただし「変数自体は再代入不可、中身（オブジェクトの中）は変更可」という点も同じ。

### `const` — コンパイル時定数

```dart
const String appName = "RAiM";
const Duration timeout = Duration(seconds: 5);
```

TSの `const` よりさらに厳しい。**コンパイル時に値が確定するもの**のみ使える。

実用上の使い分け：

```dart
final list1 = [1, 2, 3];   // 実行時に生成
const list2 = [1, 2, 3];   // コンパイル時に生成（最適化される）
```

迷ったら `final` で良い。

### `var` — 型推論

```dart
var name = "RAiM";  // String と推論される
```

TSの `let` 相当。再代入可。
ただし**型は固定**される。`var name = "RAiM";` の後に `name = 123;` はエラー。

### `late` — 遅延初期化

```dart
late String userId;  // 後で必ず初期化する宣言
// ...
userId = await fetchUserId();
```

TSにはない概念。「nullableにしたくないけど、コンストラクタでは初期化できない」場合に使う。

---

## クラス

### 基本構文

```dart
class User {
  final String name;
  final int age;
  
  User({required this.name, required this.age});
}
```

TS対応:
```typescript
class User {
  constructor(
    public readonly name: string,
    public readonly age: number,
  ) {}
}
```

ポイント：

- Dartではフィールド宣言とコンストラクタが**分離**している
- `this.name` というショートカット記法で、引数を自動的にフィールドに代入できる
- `{}` で囲むと**名前付き引数**になる（TSでオブジェクト分割代入する書き方に近い）

呼び出し方：

```dart
final user = User(name: "Ando", age: 20);
```

`new` キーワードは不要（書いてもエラーにならないが省略推奨）。

### 名前付き引数 vs 位置引数

```dart
// 位置引数（順番で渡す）
class Point {
  final int x;
  final int y;
  Point(this.x, this.y);
}
final p = Point(1, 2);  // 順番に渡す

// 名前付き引数（名前で渡す）
class User {
  final String name;
  final int age;
  User({required this.name, required this.age});
}
final u = User(name: "Ando", age: 20);  // 名前付きで渡す
```

実務では**名前付き引数を使うことが多い**。引数が多くなっても可読性が保たれるから。

### `required` と省略可能引数

```dart
class Message {
  final String text;
  final String? emotion;   // null許容
  
  Message({
    required this.text,    // 必須
    this.emotion,          // 省略可（デフォルト null）
  });
}

// 使い方
Message(text: "hello");                              // OK
Message(text: "hello", emotion: "happy");            // OK
Message(emotion: "happy");                           // エラー（textが必須）
```

TS対応:
```typescript
class Message {
  constructor(
    public text: string,
    public emotion?: string,
  ) {}
}
```

### コンストラクタの種類

Dartには**3種類**のコンストラクタがある。

#### 1. 通常のコンストラクタ

```dart
class User {
  final String name;
  User({required this.name});
}
```

#### 2. 名前付きコンストラクタ（複数のコンストラクタを持てる）

```dart
class User {
  final String name;
  final int age;
  
  User({required this.name, required this.age});
  
  // 名前付きコンストラクタ
  User.guest() : name = "Guest", age = 0;
  
  User.fromMap(Map<String, dynamic> map)
    : name = map['name'],
      age = map['age'];
}

// 使い方
final user1 = User(name: "Ando", age: 20);
final user2 = User.guest();
final user3 = User.fromMap({"name": "Ando", "age": 20});
```

TSには無い概念。同じ役割をstaticメソッドで実現する：

```typescript
class User {
  static guest(): User {
    return new User("Guest", 0);
  }
}
```

#### 3. ファクトリコンストラクタ

```dart
class LLMResponse {
  final String text;
  
  LLMResponse({required this.text});
  
  factory LLMResponse.fromJson(Map<String, dynamic> json) {
    return LLMResponse(text: json['text']);
  }
}
```

通常のコンストラクタは「**必ず新規インスタンスを作る**」が、factoryは「**何を返すか自由に決められる**」。

詳細は別ドキュメント `Dart_factoryコンストラクタの解説.md` 参照。

要点：

- JSON → オブジェクト変換 (`fromJson`) は factory が定石
- キャッシュやサブクラス返却にも使える
- TSの static method に近いが、コンストラクタとして呼べる

### 抽象クラスとインターフェース

Dartに `interface` キーワードは**ない**。代わりに **abstract class** または **暗黙的なインターフェース** を使う。

#### abstract class（抽象クラス）

```dart
abstract class LLMService {
  Future<LLMResponse> sendMessage(String userInput);
}

class MockLLMService implements LLMService {
  @override
  Future<LLMResponse> sendMessage(String userInput) async {
    // 実装
  }
}
```

TS対応:
```typescript
interface LLMService {
  sendMessage(userInput: string): Promise<LLMResponse>;
}

class MockLLMService implements LLMService {
  async sendMessage(userInput: string): Promise<LLMResponse> {
    // 実装
  }
}
```

#### `implements` vs `extends`

```dart
class A implements B { }  // Bのインターフェースに従う（中身は全部書き直し）
class A extends B { }     // Bを継承する（Bの実装も引き継ぐ）
```

TSと同じ意味。

### プライベートメンバー（`_` プレフィックス）

```dart
class ChatProvider {
  final List<Message> _messages = [];  // ファイル外からアクセス不可
  
  List<Message> get messages => _messages;  // 公開用getter
}
```

TS対応:
```typescript
class ChatProvider {
  private messages: Message[] = [];
  
  get messagesPublic(): Message[] {
    return this.messages;
  }
}
```

**Dartはキーワードではなく命名規則**でプライベートを表現する。
`_` で始まる名前は**そのファイル内からしかアクセスできない**。
（クラス内ではなくファイル単位なのが Java や C# とは違うポイント）

### Getter/Setter

```dart
class Circle {
  final double radius;
  Circle(this.radius);
  
  double get area => 3.14 * radius * radius;
  double get diameter => radius * 2;
}

final c = Circle(5);
print(c.area);  // メソッドではなくプロパティとしてアクセス
```

TS対応：
```typescript
class Circle {
  constructor(public radius: number) {}
  
  get area(): number {
    return 3.14 * this.radius * this.radius;
  }
}
```

書き方ほぼ同じ。`get` キーワードを使う点も共通。

---

## 関数

### 矢印関数

```dart
int add(int a, int b) => a + b;
```

TS対応:
```typescript
const add = (a: number, b: number): number => a + b;
```

ただしDartの矢印関数は**式しか書けない**（1行のみ）。複数行は通常の `{}` を使う。

### 名前付き引数

```dart
void greet({required String name, String greeting = "Hello"}) {
  print("$greeting, $name!");
}

greet(name: "Ando");                    // Hello, Ando!
greet(name: "Ando", greeting: "やあ");   // やあ, Ando!
```

`String greeting = "Hello"` のようにデフォルト値も指定できる。

### 引数の `_` 省略

```dart
Consumer<ChatProvider>(
  builder: (context, provider, _) {  // 第3引数を使わない
    return Text(provider.messages.first.text);
  },
);
```

TSで `(a, _, c) => ...` と書くのと同じ感覚。

---

## Null安全性

Dartは**デフォルトでnull非許容**。null許容にしたいときだけ `?` をつける。

```dart
String name = "Ando";     // null不可（"Ando"必須）
String? nickname = null;  // null可
```

TSの `strictNullChecks: true` 相当が常に有効、と思えばOK。

### Null安全演算子

```dart
String? name = getUserName();

// ?. — null チェック付きアクセス
print(name?.length);  // null なら null、そうでなければ length

// ?? — null合体演算子
print(name ?? "Guest");  // null なら "Guest"

// ! — null強制（nullじゃないと断言）
print(name!.length);  // nullだった場合は実行時エラー

// late — 遅延初期化（後で必ず初期化する）
late String userId;
```

TSと完全に同じ書き方（`?.`、`??`、`!`）。

---

## 非同期処理

### Future / async / await

```dart
Future<String> fetchData() async {
  await Future.delayed(Duration(seconds: 1));
  return "data";
}

void main() async {
  final result = await fetchData();
  print(result);
}
```

TS対応:
```typescript
async function fetchData(): Promise<string> {
  await new Promise(r => setTimeout(r, 1000));
  return "data";
}
```

`Future<T>` = `Promise<T>` と思えばOK。
`async/await` の使い方も完全に同じ。

### エラーハンドリング

```dart
try {
  final result = await fetchData();
  print(result);
} catch (e) {
  print("エラー: $e");
} finally {
  print("終了処理");
}
```

TSと完全に同じ。

---

## コレクション

### List

```dart
List<int> numbers = [1, 2, 3];
numbers.add(4);
numbers.length;
numbers.map((n) => n * 2).toList();
numbers.where((n) => n > 1).toList();
```

TS対応:
```typescript
const numbers: number[] = [1, 2, 3];
numbers.push(4);
numbers.length;
numbers.map(n => n * 2);
numbers.filter(n => n > 1);
```

ほぼ同じだが、Dartの `map` / `where` は**遅延評価のIterableを返す**ので、`.toList()` で確定させる必要がある。

### Map

```dart
Map<String, int> ages = {"Ando": 20, "Tanaka": 21};
ages["Ando"];
ages["Yamada"] = 22;
ages.containsKey("Ando");
```

TSの `Map` というよりオブジェクトリテラルに近い感覚。

### スプレッド演算子

```dart
final a = [1, 2, 3];
final b = [0, ...a, 4];  // [0, 1, 2, 3, 4]
```

TSと同じ書き方。

### コレクション内のif/for

```dart
final showEmotion = true;

return Column(
  children: [
    Text("Hello"),
    if (showEmotion) Text("感情あり"),  // 条件付きで子要素を含める
    for (var msg in messages) Text(msg),  // ループで子要素を生成
  ],
);
```

これはDart独自の便利機能。Flutterのウィジェット構築で頻出。

---

## Enum

```dart
enum MessageRole {
  user,
  assistant,
}

// 使い方
MessageRole role = MessageRole.user;

switch (role) {
  case MessageRole.user:
    print("ユーザー");
    break;
  case MessageRole.assistant:
    print("AI");
    break;
}
```

TS対応:
```typescript
enum MessageRole {
  User = "user",
  Assistant = "assistant",
}
```

TSのenumとほぼ同じだが、Dartはより本格的なオブジェクト。
拡張enum（メソッドを持たせる）も書ける。

---

## Flutter特有の概念

### StatelessWidget / StatefulWidget

```dart
// StatelessWidget — 状態を持たない
class MyWidget extends StatelessWidget {
  const MyWidget({super.key});
  
  @override
  Widget build(BuildContext context) {
    return Text("Hello");
  }
}

// StatefulWidget — 状態を持つ
class MyWidget extends StatefulWidget {
  const MyWidget({super.key});
  
  @override
  State<MyWidget> createState() => _MyWidgetState();
}

class _MyWidgetState extends State<MyWidget> {
  int count = 0;
  
  @override
  Widget build(BuildContext context) {
    return Text("$count");
  }
}
```

React対応:
- StatelessWidget = 関数コンポーネント（useStateなし）
- StatefulWidget = 関数コンポーネント（useStateあり）

### `super.key`

```dart
const MyWidget({super.key});
```

これは「親クラス（Widget）の `key` パラメータをそのまま受け取る」というショートカット。

`Key` はFlutter内部でウィジェットを識別するためのもの。Reactの `key` プロパティと同じ役割。
基本的に呪文として `super.key` を書いておけばOK。

### `@override`

```dart
@override
Widget build(BuildContext context) { ... }
```

TSと同じ「親メソッドを上書きしてます」のマーカー。
必須ではないが書くとIDEがチェックしてくれる。

### `const` コンストラクタ

```dart
const MyWidget({super.key});
```

`const` をつけられるコンストラクタは、コンパイル時に評価されてメモリに1回しか作られない。
**パフォーマンス最適化**につながる。

使うときも `const` を明示できる：

```dart
const MyWidget()  // const付きで使う
MyWidget()        // const付けないで使う（毎回新規生成）
```

慣習として、変更されないウィジェットには `const` を付ける。

### Provider / ChangeNotifier

```dart
class ChatProvider extends ChangeNotifier {
  int _count = 0;
  int get count => _count;
  
  void increment() {
    _count++;
    notifyListeners();  // UIに「変わったよ」と通知
  }
}
```

React対応:
```typescript
const ChatContext = createContext<ChatProvider | null>(null);
// ...useContext, useState で同等のことをやる
```

### `context.read` vs `context.watch` vs `Consumer`

```dart
// read: 一度だけ取得、変化を監視しない（イベントハンドラ内で使う）
context.read<ChatProvider>().sendMessage(text);

// watch: 取得＋変化を監視（再描画される）
final provider = context.watch<ChatProvider>();

// Consumer: 特定部分だけ再描画したいとき
Consumer<ChatProvider>(
  builder: (context, provider, child) {
    return Text(provider.count.toString());
  },
)
```

React で言うと：
- `read` ≒ `useRef` でストアを参照（再レンダリングしない）
- `watch` ≒ `useContext` でストアを購読（変化で再レンダリング）
- `Consumer` ≒ 子コンポーネントだけが購読する形

---

## 文字列補間

```dart
final name = "Ando";
print("Hello, $name!");
print("Length: ${name.length}");
```

TS対応:
```typescript
const name = "Ando";
console.log(`Hello, ${name}!`);
console.log(`Length: ${name.length}`);
```

書き方が少し違うが意味は同じ：
- 変数のみ: `$name`
- 式を含む: `${name.length}`

---

## カスケード記法 `..`

これはDart独特の便利機能。

```dart
final list = []
  ..add(1)
  ..add(2)
  ..add(3);
// list = [1, 2, 3]
```

「同じオブジェクトに対して複数操作を連続で行う」書き方。
チェーン的に書けるので、初期化処理が綺麗になる。

TSにはない。あえて似たことをするなら：

```typescript
const list: number[] = [];
list.push(1);
list.push(2);
list.push(3);
```

---

## ジェネリクス

```dart
class Container<T> {
  final T value;
  Container(this.value);
}

final c = Container<int>(42);
final c2 = Container<String>("hello");
```

TSと書き方も使い方もほぼ同じ。

Flutter のクラスで多用される：

```dart
Future<LLMResponse>   // Promise<LLMResponse>
List<Message>          // Message[]
Consumer<ChatProvider> // Reactで言うContext.Consumer
```

---

## import文

```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:raim_app/models/message.dart';
import 'dart:convert';  // 標準ライブラリ
```

3つの形式：

- `package:` — 外部パッケージ or 自プロジェクト（pubspec.yaml の `name:` で参照）
- `dart:` — Dart標準ライブラリ
- 相対パス（`'../models/message.dart'`）も使えるが非推奨

TS の `import { X } from "..."` と違って、**何をimportするか指定しない**（全部入る）。
これに違和感あるけど慣れる。

特定のものだけ取り込みたいときは：

```dart
import 'package:foo/foo.dart' show Bar, Baz;        // BarとBazだけ
import 'package:foo/foo.dart' hide Qux;             // Qux以外
import 'package:foo/foo.dart' as foo;               // 名前空間付き
```

---

## RAiMで実際に出てきた要素 早見表

| 文法 | 用例 | TS対応 |
|---|---|---|
| `final` | `final String text;` | `const text: string;` |
| `required` | `required this.text` | （必須プロパティ） |
| `?` (nullable) | `String? emotion;` | `emotion?: string` |
| `factory` | `factory LLMResponse.fromJson(...)` | static method |
| `abstract class` | `abstract class LLMService` | `interface LLMService` |
| `implements` | `class Mock implements LLMService` | 同じ |
| `extends ChangeNotifier` | `class ChatProvider extends ChangeNotifier` | 状態管理クラス |
| `async/await/Future` | `Future<X> fn() async` | `async function fn(): Promise<X>` |
| `_` プレフィックス | `_messages` | `private messages` |
| `get` | `List<Message> get messages` | `get messages()` |
| `notifyListeners()` | `notifyListeners();` | `setState({...})` |
| `@override` | `@override` | `override` |
| `super.key` | `MyWidget({super.key})` | （Reactのkey相当） |
| `Consumer<T>` | `Consumer<ChatProvider>(...)` | `<Context.Consumer>` |
| `context.read<T>()` | `context.read<ChatProvider>()` | `useContext(...)` |
| `$変数` | `"Hello, $name"` | `` `Hello, ${name}` `` |
| `if` in collection | `if (cond) Widget()` | 三項演算子 |

---

## 重要な「考え方」の違い

### 1. ウィジェットツリーで全部を表現する

Flutterは**すべてがWidget**。
画面はWidget、ボタンもWidget、レイアウトもWidget、パディングもWidget。

```dart
return Container(
  padding: EdgeInsets.all(8),
  child: Column(
    children: [
      Text("Hello"),
      Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text("World"),
      ),
    ],
  ),
);
```

Reactなら：

```tsx
<div style={{ padding: 8 }}>
  <Text>Hello</Text>
  <div style={{ paddingTop: 8 }}>
    <Text>World</Text>
  </div>
</div>
```

CSSやスタイルプロパティで指定するものを、Flutter ではWidgetとして表現する。
最初は冗長に見えるが、慣れると非常に明示的で読みやすい。

### 2. 不変性（Immutability）が基本

Widgetは基本的に**不変**。状態を持たない。
状態が変わるたびに新しいWidgetツリーが作られる（Reactの再レンダリングと同じ）。

だから `const` や `final` を多用する。

### 3. ファイル単位の可視性

Javaのpublic/privateはクラス単位だが、Dartは**ファイル単位**。
1つのファイルの中なら `_変数` も自由にアクセスできる。

これにより、関連クラスを1ファイルにまとめても可読性が落ちない。

---

## まとめ

TS経験者なら、以下を押さえれば即書ける：

1. **final = const、var = let**
2. **`?` でnull許容、`!` で強制、`??` でデフォルト値** （TSと同じ）
3. **`Future<T>` = `Promise<T>`、`async/await` 同じ**
4. **`abstract class + implements` で TS の interface 相当**
5. **`new` キーワード不要**
6. **`_` 始まりはファイル内プライベート**
7. **コンストラクタは `this.field` のショートカットで楽**
8. **factoryコンストラクタは「JSONから生成」の定石**
9. **すべてがWidget、ツリーで構築**

そのほかの細かい違いは、書いてれば自然に身につく。

---

## 関連ドキュメント

- `Flutter_プロジェクト構造の解説.md` — フォルダ構成と設計思想
- `Dart_factoryコンストラクタの解説.md` — factoryの詳しい解説
- `RAiM_プロトタイプ実装まとめ.md` — 実装したコードの解説

---

## 公式リソース

- [Dart Language Tour](https://dart.dev/language) — 一通り読む価値あり
- [Flutter Widget Catalog](https://docs.flutter.dev/ui/widgets) — UI部品の辞書
- [pub.dev](https://pub.dev/) — Dart/Flutter のパッケージレジストリ（npmと同じ）

---

## 変更履歴

- 初版作成: TS経験者向け文法ガイド