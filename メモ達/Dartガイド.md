# Dart 文法ガイド（TS経験者向け）

## このドキュメントについて

RAiMプロジェクトでDart（Flutterの言語）を読み書きする班員向けの解説。
TypeScript/JavaScript経験を活かせるよう、対比形式で書いている。

このドキュメント1本で **Dart の基本文法** + **RAiMでよく使うパターン**（factoryコンストラクタなど）をカバーする。

---

# Part 1: Dart 基本文法（TS経験者向け）

## DartとTypeScript、共通点

両方とも：
- 静的型付け
- クラスベースのオブジェクト指向
- async/await サポート
- ジェネリクス

なので、構文の表面が違うだけで**考え方はほぼ同じ**。

## 変数宣言

### TypeScript
```typescript
const name: string = "ライム";
let age: number = 18;
```

### Dart
```dart
final String name = "ライム";  // 不変
String name = "ライム";         // 可変
var age = 18;                   // 型推論
```

ポイント:
- `const`の代わりに**`final`**を使うことが多い（compile-timeとruntime-timeの違いはあるが）
- 型は変数名の**前**に書く（TSは後ろに `:` で書く）

## 関数

### TypeScript
```typescript
function greet(name: string): string {
  return `こんにちは、${name}`;
}
```

### Dart
```dart
String greet(String name) {
  return 'こんにちは、$name';
}
```

ポイント:
- 戻り値の型は**関数名の前**
- 文字列展開は `${変数}` または `$変数`（変数1つなら波カッコ省略OK）

## クラス

### TypeScript
```typescript
class Message {
  text: string;
  role: string;
  
  constructor(text: string, role: string) {
    this.text = text;
    this.role = role;
  }
}
```

### Dart
```dart
class Message {
  final String text;
  final String role;
  
  Message({required this.text, required this.role});
}
```

ポイント:
- コンストラクタの引数で `this.text` と書くと「フィールドに直接代入」される（**糖衣構文**、書く量が減る）
- `{}` で囲むと**名前付き引数**になる（TSのオブジェクト引数に近い）
- `required` で必須化

## 名前付き引数の使い方

### TypeScript（オブジェクト引数）
```typescript
const msg = new Message({ text: "おはよう", role: "user" });
```

### Dart（名前付き引数）
```dart
final msg = Message(text: "おはよう", role: "user");
```

DartでもTSと同じ感覚で書ける。

## null安全

### TypeScript
```typescript
let name: string | null = null;
name?.length;  // null安全アクセス
```

### Dart
```dart
String? name = null;  // ? で nullable
name?.length;         // 同じく ? でアクセス
```

ポイント:
- 型に `?` を付けると nullable（TSは `| null`）
- アクセスは同じ `?.`

## async/await

両方ほぼ同じ書き方：

### TypeScript
```typescript
async function fetchData(): Promise<string> {
  const response = await fetch("/api");
  return response.text();
}
```

### Dart
```dart
Future<String> fetchData() async {
  final response = await http.get(Uri.parse("/api"));
  return response.body;
}
```

ポイント:
- `Promise<T>` の代わりに `Future<T>`
- `await` の使い方は完全に同じ

## コレクション

### TypeScript
```typescript
const list: number[] = [1, 2, 3];
const map: Record<string, string> = { name: "ライム" };
```

### Dart
```dart
final List<int> list = [1, 2, 3];
final Map<String, String> map = {"name": "ライム"};
```

ポイント:
- `List<T>`、`Map<K, V>`、`Set<T>`
- リテラルの書き方は同じ `[]` `{}`

## クラスの継承・インターフェース

### TypeScript
```typescript
interface LLMService {
  sendMessage(text: string): Promise<string>;
}

class OllamaService implements LLMService {
  async sendMessage(text: string): Promise<string> { ... }
}
```

### Dart
```dart
abstract class LLMService {
  Future<String> sendMessage(String text);
}

class OllamaService implements LLMService {
  @override
  Future<String> sendMessage(String text) async { ... }
}
```

ポイント:
- `interface` の代わりに `abstract class`
- `implements` キーワードは同じ
- メソッドオーバーライドには `@override` アノテーション推奨

## 列挙型

### TypeScript
```typescript
enum MessageRole {
  user,
  assistant,
}
```

### Dart
```dart
enum MessageRole {
  user,
  assistant,
}
```

書き方は同じ！

---

# Part 2: factory コンストラクタ（Dart特有）

DartのfactoryコンストラクタはRAiMで `LLMResponse.fromJson()` などで使うので、ここで腹落ちさせる。

## 通常のコンストラクタとの違い

### 通常のコンストラクタ

```dart
class LLMResponse {
  final String text;
  
  LLMResponse({required this.text});
}
```

呼ぶときはこう：
```dart
final r = LLMResponse(text: "hello");
```

**通常のコンストラクタは「呼ばれた瞬間に新しいインスタンスを作る」**。シンプル。

### factoryコンストラクタ

```dart
factory LLMResponse.fromJson(Map<String, dynamic> json) {
  return LLMResponse(
    text: json['text'] as String,
  );
}
```

`factory` がつくと、**「インスタンスを作る前に、何か処理を挟める」**ようになる。

### 比較表

| | 通常コンストラクタ | factoryコンストラクタ |
|---|---|---|
| 戻り値 | 必ず新しいインスタンス | 何でも返せる（既存のインスタンスでもOK） |
| 処理 | フィールドに値入れるだけ | 自由なロジックを書ける |
| `return` | 書かない | `return new ...` を明示的に書く |

## なぜ「factory」という名前なのか

「factory（工場）」という名前は、**設計パターンの用語**から来ている。「インスタンスを作る工場」という意味。

普通のコンストラクタが「料理を作る人」だとしたら、factoryは「**注文を受けて、状況に応じて適切なものを作って渡す工場**」のイメージ。

## RAiMでなぜ使うか

LLMから返ってくるデータはこういう JSON 文字列：

```json
{"text": "おはよう", "emotion": "happy", "intensity": 0.8}
```

これを `LLMResponse` 型のオブジェクトに変換したい。

「JSONをLLMResponseに変える処理」を**LLMResponseクラス自身に書きたい**。なぜなら変換ロジックを別の場所に置くと、

```dart
// もし別関数に書くと…
LLMResponse convertJsonToLLMResponse(Map json) { ... }
```

「LLMResponseの作り方」が2箇所に分散する（コンストラクタと変換関数）。

**LLMResponseクラスの中に「JSONから自分自身を作る方法」を書く**のが綺麗。それが `factory LLMResponse.fromJson()` の役目。

## 実際の使い方

services層ではこう使う：

```dart
// Ollamaに POST
final response = await http.post(...);

// 文字列のJSONを Map に変換
final json = jsonDecode(response.body) as Map<String, dynamic>;

// MapからLLMResponseオブジェクトを作る ← ここで factory が活躍
final llmResponse = LLMResponse.fromJson(json);

// 型のあるオブジェクトとして扱える
print(llmResponse.text);      // "おはよう"
print(llmResponse.emotion);   // "happy"
print(llmResponse.intensity); // 0.8
```

`LLMResponse.fromJson(json)` の呼び方は「**LLMResponseクラスの fromJson メソッドを使って、JSONから新しいインスタンスを生成**」という意味。クラス名から直接呼べる。

## TypeScriptで例えると

TypeScriptには`factory`という構文はないが、static methodで同じことをやる：

```typescript
class LLMResponse {
  constructor(
    public text: string,
    public emotion: string,
    public intensity: number,
  ) {}
  
  static fromJson(json: any): LLMResponse {
    return new LLMResponse(
      json.text,
      json.emotion,
      json.intensity,
    );
  }
}

const response = LLMResponse.fromJson({text: "おはよう", ...});
```

Dartの`factory`は、これを**コンストラクタとして扱える**ようにしたバージョン、と思うと分かりやすい。

## factoryが「特別」な理由

通常のコンストラクタとfactoryコンストラクタの本質的な違いは、**`return`を書けるかどうか**。

```dart
// 通常のコンストラクタ：return書けない
LLMResponse({required this.text});  // 自動で新しいインスタンスができる

// factoryコンストラクタ：returnを明示的に書く
factory LLMResponse.fromJson(Map json) {
  if (json['text'] == null) {
    return LLMResponse(text: "(空)", ...);  // 条件によって違うものを返せる
  }
  
  return LLMResponse(
    text: json['text'],
    ...
  );
}
```

通常のコンストラクタでは「フィールドに値を入れる」しかできない。factoryなら**ロジックを挟める**。

## 応用：他にもfactoryが活躍する場面

### 例1: キャッシュ的な使い方

```dart
class LLMResponse {
  static final _cache = <String, LLMResponse>{};
  
  factory LLMResponse.cached(String key) {
    if (_cache.containsKey(key)) {
      return _cache[key]!;
    }
    final newInstance = LLMResponse(text: key, ...);
    _cache[key] = newInstance;
    return newInstance;
  }
}
```

これは通常のコンストラクタでは絶対できない（必ず新規作成してしまうから）。

### 例2: サブクラスを返す使い方

```dart
factory LLMResponse.fromEmotion(String emotion) {
  if (emotion == "happy") {
    return HappyResponse(...);
  }
  return LLMResponse(...);
}
```

## まとめ

- **通常コンストラクタ**: 「シンプルにインスタンスを作る」
- **factoryコンストラクタ**: 「インスタンスを作る前に処理を挟める」「何を返すか柔軟に決められる」

`fromJson` でfactoryを使う理由：

1. JSON → LLMResponse の**変換ロジック**を、LLMResponseクラス自身に持たせたい
2. 「クラスから直接 `LLMResponse.fromJson(json)` で呼べる」という書き方が綺麗
3. これはDartの慣習として、JSONからオブジェクトを作るときの**標準パターン**

---

# Part 3: RAiM でよく使う Dart パターン

## 抽象クラス + implements

```dart
// 抽象インターフェース
abstract class UnityCommunicator {
  Future<void> start();
  void sendEmotion({required String text, required String emotion, required double intensity});
}

// 具体実装1
class WindowsUnityBridge implements UnityCommunicator {
  @override
  Future<void> start() async { ... }
  
  @override
  void sendEmotion({required String text, required String emotion, required double intensity}) { ... }
}

// 具体実装2
class EmbedUnityBridge implements UnityCommunicator {
  @override
  Future<void> start() async { ... }
  
  @override
  void sendEmotion({required String text, required String emotion, required double intensity}) { ... }
}
```

これで「プラットフォームごとに別実装、呼ぶ側は型だけ知ってればいい」という設計ができる。

## プラットフォーム判定

```dart
import 'dart:io' show Platform;

if (Platform.isAndroid || Platform.isIOS) {
  // モバイル処理
} else {
  // デスクトップ処理
}
```

## Provider パターン（Reactのcontextに相当）

```dart
// 提供側
ChangeNotifierProvider(
  create: (_) => ChatProvider(),
  child: MyApp(),
)

// 取得側（buildメソッド内）
final provider = context.watch<ChatProvider>();
final provider2 = context.read<ChatProvider>();  // 再描画なし
```

---

## 参考リソース

- [Dart 公式チートシート](https://dart.dev/codelabs/dart-cheatsheet)
- [Dart 言語ツアー](https://dart.dev/language)
- [Effective Dart](https://dart.dev/effective-dart)

---

## 変更履歴

- 初版: プロトタイプ開発開始時点（dart文法 + factory別ファイル）
- **最新版（本ドキュメント）**: dart基本文法 + factoryコンストラクタ + RAiMパターンを1本に統合
