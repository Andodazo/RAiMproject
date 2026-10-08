import 'dart:convert';

import 'package:raim_prototype/config/raim_config.dart';
import 'package:raim_prototype/models/auth_tokens.dart';

/// 展示アカウントとして扱ってよいかを認証情報から判定するポリシー。
///
/// Cognito の `cognito:groups` は通常 ID token に含まれる。テスト用や
/// 将来の認証フローで access token に含まれる場合もあるため、両方を読むが、
/// グループが確認できない場合は展示モードを許可しない（fail closed）。
class DemoAccountPolicy {
  const DemoAccountPolicy({this.group = RaimConfig.exhibitionGroup});

  final String group;

  bool isDemoAccount(AuthTokens? tokens) {
    if (tokens == null || tokens.isExpired || group.isEmpty) return false;

    return _containsGroup(tokens.idToken) ||
        _containsGroup(tokens.accessToken);
  }

  bool _containsGroup(String? token) {
    final claims = _decodeClaims(token);
    if (claims == null) return false;

    final raw = claims['cognito:groups'] ?? claims['groups'];
    if (raw is List) {
      return raw.any((value) => value.toString() == group);
    }
    if (raw is String) {
      return raw.split(RegExp(r'[ ,]+')).any((value) => value == group);
    }
    return false;
  }

  Map<String, dynamic>? _decodeClaims(String? token) {
    if (token == null || token.isEmpty) return null;
    final parts = token.split('.');
    if (parts.length < 2) return null;

    try {
      final normalized = base64Url.normalize(parts[1]);
      final decoded = jsonDecode(utf8.decode(base64Url.decode(normalized)));
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}
