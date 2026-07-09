import 'dart:async';
import 'dart:io';

/// Windows デスクトップで OAuth callback を受け取るための一時的なローカルHTTPサーバーです。
///
/// Google OAuth は埋め込み WebView で完走できないことがあるため、Windows では既定ブラウザで
/// Cognito / Google 認証を行い、認証後の `http://localhost:3000/callback` をこのサーバーで
/// 受け取ります。AWS Cognito 側には同じURLを「許可されているコールバックURL」として登録します。
class LocalCallbackServer {
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;

  Future<Uri> waitForCallback({
    Duration timeout = const Duration(minutes: 10),
  }) async {
    await close();

    final completer = Completer<Uri>();
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 3000);

    _subscription = _server!.listen(
      (request) async {
        final callbackUri = Uri(
          scheme: 'http',
          host: 'localhost',
          port: 3000,
          path: request.uri.path,
          query: request.uri.query,
        );

        if (request.uri.path != '/callback') {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }

        request.response.headers.contentType = ContentType.html;
        request.response.write('''
<!doctype html>
<html lang="ja">
  <head>
    <meta charset="utf-8">
    <title>RAiM 認証完了</title>
    <script>
      window.addEventListener('load', function () {
        setTimeout(function () {
          window.open('', '_self');
          window.close();
        }, 300);
      });
    </script>
  </head>
  <body style="font-family: sans-serif; padding: 32px;">
    <h1>RAiM の認証が完了しました</h1>
    <p>RAiM アプリに戻っています。このタブが自動で閉じない場合は、手動で閉じてください。</p>
  </body>
</html>
''');
        await request.response.close();

        if (!completer.isCompleted) {
          completer.complete(callbackUri);
        }
        await close();
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
    );

    return completer.future.timeout(
      timeout,
      onTimeout: () async {
        await close();
        throw TimeoutException('Cognito認証のcallback待機がタイムアウトしました。', timeout);
      },
    );
  }

  Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;

    await _server?.close(force: true);
    _server = null;
  }
}
