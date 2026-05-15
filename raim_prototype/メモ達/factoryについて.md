# Dart factoryコンストラクタの解説

## このドキュメントについて

Dart の `factory` コンストラクタは、Flutter初心者がつまずきやすい文法のひとつ。
RAiMプロジェクトで `LLMResponse.fromJson()` などで使うので、ここで腹落ちさせておく。

---

## 通常のコンストラクタとの違い

### 通常のコンストラクタ

```dart
class LLMResponse {
  final String text;
  
  LLMResponse({required this.text});
  // ↑ これが通常のコンストラクタ
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
    ...
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

---

## なぜ「factory」という名前なのか

「factory（工場）」という名前は、**設計パターンの用語**から来ている。「インスタンスを作る工場」という意味。

普通のコンストラクタが「料理を作る人」だとしたら、factoryは「**注文を受けて、状況に応じて適切なものを作って渡す工場**」のイメージ。

---

## RAiMでなぜ使うか

LLMから返ってくるデータはこういう JSON 文字列：

```json
{"text": "おはよう", "emotion": "happy", "intensity": 0.8}
```

これをそのままDartで扱うと文字列のまま。型もない：

```dart
String jsonString = '{"text": "おはよう", ...}';
// このままだと jsonString.text みたいなアクセスできない
```

これを `LLMResponse` 型のオブジェクトに変換したい。

「JSONをLLMResponseに変える処理」を**LLMResponseクラス自身に書きたい**。なぜなら変換ロジックを別の場所に置くと、

```dart
// もし別関数に書くと…
LLMResponse convertJsonToLLMResponse(Map json) { ... }
```

「LLMResponseの作り方」が2箇所に分散する（コンストラクタと変換関数）。修正したいときどちらも変えなくてはいけない。

**LLMResponseクラスの中に「JSONから自分自身を作る方法」を書く**のが綺麗。それが `factory LLMResponse.fromJson()` の役目。

---

## 実際の使い方

services層ではこう使う：

```dart
// Ollamaに POST
final response = await http.post(...);

// 文字列のJSONを Map に変換
final json = jsonDecode(response.body) as Map<String, dynamic>;
// json は {"text": "おはよう", "emotion": "happy", "intensity": 0.8}

// MapからLLMResponseオブジェクトを作る ← ここで factory が活躍
final llmResponse = LLMResponse.fromJson(json);

// 型のあるオブジェクトとして扱える
print(llmResponse.text);      // "おはよう"
print(llmResponse.emotion);   // "happy"
print(llmResponse.intensity); // 0.8
```

`LLMResponse.fromJson(json)` の呼び方は「**LLMResponseクラスの fromJson メソッドを使って、JSONから新しいインスタンスを生成**」という意味。クラス名から直接呼べる。

---

## TypeScriptで例えると

TypeScriptには`factory`という構文はないが、static methodで同じことをやる：

```typescript
class LLMResponse {
  constructor(
    public text: string,
    public emotion: string,
    public intensity: number,
  ) {}
  
  // staticメソッドで「JSONから自分を作る」処理を提供
  static fromJson(json: any): LLMResponse {
    return new LLMResponse(
      json.text,
      json.emotion,
      json.intensity,
    );
  }
}

// 使い方
const response = LLMResponse.fromJson({text: "おはよう", ...});
```

Dartの`factory`は、これを**コンストラクタとして扱える**ようにしたバージョン、と思うと分かりやすい。

---

## factoryが「特別」な理由

通常のコンストラクタとfactoryコンストラクタの本質的な違いは、**`return`を書けるかどうか**。

```dart
// 通常のコンストラクタ：return書けない
LLMResponse({required this.text});  // 自動で新しいインスタンスができる

// factoryコンストラクタ：returnを明示的に書く
factory LLMResponse.fromJson(Map json) {
  // ここで何でも処理できる
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

---

## 応用：他にもfactoryが活躍する場面

### 例1: キャッシュ的な使い方

```dart
class LLMResponse {
  static final _cache = <String, LLMResponse>{};
  
  factory LLMResponse.cached(String key) {
    // キャッシュにあれば既存のインスタンスを返す
    if (_cache.containsKey(key)) {
      return _cache[key]!;
    }
    // なければ新規作成してキャッシュに保存
    final newInstance = LLMResponse(text: key, ...);
    _cache[key] = newInstance;
    return newInstance;
  }
}
```

これは通常のコンストラクタでは絶対できない（必ず新規作成してしまうから）。factoryなら「既存のインスタンスを返す」ことができる。

### 例2: サブクラスを返す使い方

```dart
factory LLMResponse.fromEmotion(String emotion) {
  if (emotion == "happy") {
    return HappyResponse(...);  // サブクラスを返せる
  }
  return LLMResponse(...);
}
```

---

## まとめ

- **通常コンストラクタ**: 「シンプルにインスタンスを作る」
- **factoryコンストラクタ**: 「インスタンスを作る前に処理を挟める」「何を返すか柔軟に決められる」

`fromJson` でfactoryを使う理由：

1. JSON → LLMResponse の**変換ロジック**を、LLMResponseクラス自身に持たせたい
2. 「クラスから直接 `LLMResponse.fromJson(json)` で呼べる」という書き方が綺麗
3. これはDartの慣習として、JSONからオブジェクトを作るときの**標準パターン**

「`fromJson` を見たら、JSONからオブジェクト作るんだな」と思える。これがDartコードの読みやすさにつながる。

---

## 補足: static method ではダメなのか？

技術的にはstatic methodでも同じことができる：

```dart
class LLMResponse {
  static LLMResponse fromJson(Map<String, dynamic> json) {
    return LLMResponse(
      text: json['text'] as String,
      ...
    );
  }
}
```

これでも動く。

しかし慣習として `factory` を使うことが多い。理由：

- `LLMResponse.fromJson(json)` の呼び方が「コンストラクタっぽく見える」
- Dart 標準ライブラリも `factory` を使っている
- 将来的にキャッシュやサブクラス返却に拡張しやすい

なので、JSONからオブジェクト作る系のメソッドは `factory` で書くのが Dart 流。

---

## 関連リソース

- [Dart公式: factory constructors](https://dart.dev/language/constructors#factory-constructors)