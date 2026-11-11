/// キャラクターの表示方式。保存・通信・UIで同じ値を使う。
enum AvatarMode {
  twoD('2d'),
  threeD('3d');

  const AvatarMode(this.wireValue);
  final String wireValue;

  static AvatarMode? tryParse(String? value) => switch (value) {
    '2d' => twoD,
    '3d' => threeD,
    _ => null,
  };
}
