// lib/services/station/station_proximity.dart
//
// GPS の現在地から、降りる駅への近さを判断する。
//
// 音声（車内アナウンス）と組み合わせて使う。
//
//   1. 音声の判定を絞る
//      降りる駅から遠いところで「次は新宿」と聞こえたら、それは聞き間違い
//      （または別の路線の話）として無視する。
//   2. アナウンスを聞き逃したときの保険
//      降りる駅に十分近づいたら、音声が無くても知らせる。
//      速く走っているときは、距離ではなく「このままだと着くまで [arriveLead]」の
//      時点で知らせる。500m は時速 80km だと 20 秒ちょっとで、寝ていると間に合わない。
//   3. 地下など GPS が取れないとき
//      位置が古い・精度が悪いときは絞らない（音声だけで判定する）。
//
// 距離の目安は「隣の駅までの距離」から決める。駅の間隔は路線によって
// 数百 m（地下鉄）から数十 km（新幹線）まで違うため、固定の距離では決めない。

import 'dart:math' as math;

import 'package:raim_prototype/services/station/station_alarm.dart';
import 'package:raim_prototype/services/station/station_database.dart';

class StationProximity {
  StationProximity(
    this.plan, {
    this.arriveRadius = 500,
    this.arriveLead = const Duration(seconds: 60),
    this.maxArriveLeadDistance = 2500,
    this.minLeadSpeed = 5,
    this.maxFixAge = const Duration(seconds: 90),
    this.maxAccuracy = 300,
  }) {
    final dest = plan.destination;
    final gaps = [
      for (final s in plan.approach)
        distanceMeters(dest.lat, dest.lng, s.lat, s.lng),
    ];
    final nearest = gaps.isEmpty ? 2000.0 : gaps.reduce(math.min);
    final farthest = gaps.isEmpty ? 2000.0 : gaps.reduce(math.max);

    // 隣の駅を過ぎたあたり（隣の駅より降りる駅に近い）を「もうすぐ」とする
    approachRadius = (nearest * 1.1).clamp(800.0, 30000.0).toDouble();

    // 「次は◯◯（隣の駅）」は、降りる駅の2つ手前を出たあたりで流れる。
    // 隣の駅までの距離の 2.5 倍までは音声を受け付ける
    gateRadius = math.max(3000.0, farthest * 2.5);
  }

  final StationAlarmPlan plan;

  /// ここまで近づいたら、音声が無くても「着く」と知らせる（m）。
  final double arriveRadius;

  /// 速く走っているときは、着くまでこれだけ前に「着く」と知らせる。
  final Duration arriveLead;

  /// [arriveLead] で知らせる距離の上限（m）。GPS の速さが飛んだときに、
  /// 遠くで鳴らないようにするため。
  final double maxArriveLeadDistance;

  /// これより遅ければ [arriveLead] は使わず、[arriveRadius] で知らせる（m/秒）。
  /// 18km/h。駅に止まりかけているときや、歩いているとき。
  final double minLeadSpeed;

  /// これより速い値は GPS の誤りとみなす（m/秒、360km/h）。
  static const double maxPlausibleSpeed = 100;

  /// これより古い位置は使わない。地下では位置が更新されなくなるため。
  final Duration maxFixAge;

  /// これより精度が悪い（誤差が大きい）位置は使わない（m）。
  final double maxAccuracy;

  /// ここまで近づいたら「もうすぐ」と知らせる（m）。
  late final double approachRadius;

  /// これより遠いところで聞こえたアナウンスは無視する（m）。
  late final double gateRadius;

  double? _distance;
  DateTime? _fixAt;

  /// 最後に分かった、降りる駅に近づく速さ（m/秒）。分からなければ null。
  double? _speed;

  /// 一度でも「外」にいたか。乗車モードを始めた場所がもう駅の近くだった
  /// ときに、始めた瞬間に鳴らないようにするため。
  bool _wasOutsideApproach = false;
  bool _wasOutsideArrive = false;

  bool _approachFired = false;
  bool _arriveFired = false;

  /// 最後に分かった降りる駅までの距離（m）。分からなければ null。
  double? get distance => _distance;

  /// 最後に分かった、降りる駅に近づく速さ（m/秒）。離れているときや、
  /// 分からなければ null。
  double? get speed => _speed;

  /// 今「着く」と知らせる距離（m）。速く近づいていれば、着くまで
  /// [arriveLead] の距離（[maxArriveLeadDistance] まで）。
  double get arriveDistance {
    final v = _speed;
    if (v == null || v < minLeadSpeed) return arriveRadius;
    final lead = v * arriveLead.inMilliseconds / 1000;
    return lead.clamp(arriveRadius, maxArriveLeadDistance).toDouble();
  }

  /// 位置が今使えるか（新しくて精度が十分）。
  bool hasFreshFix(DateTime now) {
    final at = _fixAt;
    return at != null && now.difference(at) <= maxFixAge;
  }

  /// 現在地を渡す。知らせるべきことがあれば返す。
  ///
  /// [speed] は GPS の速さ（m/秒）。分からなければ null か負の値。
  StationAlarmStage? onPosition(
    double lat,
    double lng, {
    required double accuracy,
    required DateTime at,
    double? speed,
  }) {
    if (accuracy > maxAccuracy) return null;

    final dest = plan.destination;
    final d = distanceMeters(lat, lng, dest.lat, dest.lng);
    _speed = _approachSpeed(d, at, speed);
    _distance = d;
    _fixAt = at;

    if (d > approachRadius) _wasOutsideApproach = true;
    if (d > arriveRadius) _wasOutsideArrive = true;

    if (!_arriveFired && _wasOutsideArrive && d <= arriveDistance) {
      _arriveFired = true;
      _approachFired = true;
      return StationAlarmStage.arriving;
    }
    if (!_approachFired && _wasOutsideApproach && d <= approachRadius) {
      _approachFired = true;
      return StationAlarmStage.approaching;
    }
    return null;
  }

  /// 降りる駅に近づく速さ（m/秒）。離れている・止まっている・分からなければ null。
  ///
  /// 前の位置より近づいているときだけ求める。GPS の速さがあればそれを使い、
  /// 無ければ前の位置からの距離の変化で求める。
  double? _approachSpeed(double d, DateTime at, double? reported) {
    final prevD = _distance;
    final prevAt = _fixAt;
    if (prevD == null || prevAt == null) return null;
    if (d >= prevD) return null; // 近づいていない

    double? v;
    if (reported != null && reported > 0) {
      v = reported;
    } else {
      final dt = at.difference(prevAt).inMilliseconds / 1000;
      if (dt >= 1 && dt <= 120) v = (prevD - d) / dt;
    }
    if (v == null || v > maxPlausibleSpeed) return null;
    return v;
  }

  /// 音声で聞こえた知らせを受け入れてよいか。
  ///
  /// 位置が使えないとき（地下・取得できない）は、いつでも受け入れる。
  bool allowsVoice(DateTime now) {
    if (!hasFreshFix(now)) return true;
    return (_distance ?? 0) <= gateRadius;
  }

  /// GPS で、降りる駅の近く（音声を受け付ける範囲）にいると分かっているか。
  ///
  /// [allowsVoice] と違い、位置が分からないときは false。
  /// 「次は」が無いアナウンス（駅名の繰り返し）を受け入れるかに使う。
  bool isNearByGps(DateTime now) =>
      hasFreshFix(now) && (_distance ?? double.infinity) <= gateRadius;

  /// 音声で知らせたことを伝える（同じ知らせを GPS で重ねて出さないため）。
  void markNotified(StationAlarmStage stage) {
    _approachFired = true;
    if (stage == StationAlarmStage.arriving) _arriveFired = true;
  }
}
