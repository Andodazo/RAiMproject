// lib/services/approx_location.dart
//
// 天気のための、だいたいの現在地。
//
// 場所を言わずに「今日の天気は？」と聞かれたとき、サーバーはこの位置の
// 天気を返す。以前は場所が分からず、ライムがどこかの都市を勝手に選んでいた。
//
// 【プライバシー】
//   - 設定「天気に現在地を使う」が ON で、位置情報の許可があるときだけ送る
//   - 0.1度（約10km）に丸めて送る。天気には十分で、住所までは分からない
//   - サーバーは天気を調べるときだけ使い、保存もログ出力もしない
//
// 【送信を待たせない】
// 位置の取得（GPS）は数秒かかることがある。送信のたびに待つと返事が遅れるので、
// 端末が覚えている最後の位置を使い、古ければ裏で取り直しておく。

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'package:raim_prototype/services/raim_log.dart';

class ApproxLocation {
  ApproxLocation._();

  /// これより古い位置なら、裏で取り直す。
  static const Duration maxAge = Duration(minutes: 30);

  static double? _lat;
  static double? _lon;
  static DateTime? _at;
  static bool _refreshing = false;

  /// 使える端末か。Windows は位置情報の許可の扱いを確かめていないので出さない。
  static bool get isSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// 位置情報の許可があるか。許可を求めはしない。
  static Future<bool> hasPermission() async {
    if (!isSupported) return false;
    try {
      final p = await Geolocator.checkPermission();
      return p == LocationPermission.whileInUse ||
          p == LocationPermission.always;
    } catch (_) {
      return false;
    }
  }

  /// 位置情報の許可を求める。設定で ON にしたときに呼ぶ。使えるなら true。
  static Future<bool> requestPermission() async {
    if (!isSupported) return false;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return false;
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) {
        p = await Geolocator.requestPermission();
      }
      final ok = p == LocationPermission.whileInUse ||
          p == LocationPermission.always;
      if (ok) _refresh();
      return ok;
    } catch (e) {
      RaimLog.w('[Location] 位置情報の許可を確認できませんでした: ${e.runtimeType}');
      return false;
    }
  }

  /// 送信に付ける位置（約10kmに丸めたもの）。使えなければ null。
  ///
  /// 待つのは「端末が覚えている最後の位置」の問い合わせだけ。
  static Future<Map<String, double>?> forRequest() async {
    if (!await hasPermission()) return null;
    try {
      final at = _at;
      final stale = at == null || DateTime.now().difference(at) > maxAge;
      if (stale) {
        if (_lat == null) {
          final last = await Geolocator.getLastKnownPosition();
          if (last != null) _set(last);
        }
        _refresh();
      }
      final lat = _lat;
      final lon = _lon;
      if (lat == null || lon == null) return null;
      return {'lat': _round(lat), 'lon': _round(lon)};
    } catch (_) {
      return null;
    }
  }

  /// 0.1度単位に丸める（約10km）。サーバーでも丸めるが、送る前に丸めておく。
  static double _round(double v) => (v * 10).roundToDouble() / 10;

  static void _set(Position p) {
    _lat = p.latitude;
    _lon = p.longitude;
    _at = DateTime.now();
  }

  /// 裏で今の位置を取り直す。精度は低くてよい（天気なので）。
  static void _refresh() {
    if (_refreshing) return;
    _refreshing = true;
    Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.low,
        timeLimit: Duration(seconds: 15),
      ),
    ).then(_set).catchError((Object e) {
      RaimLog.d('[Location] 現在地を取れませんでした: ${e.runtimeType}');
    }).whenComplete(() => _refreshing = false);
  }
}
