using System;
using System.Collections;
using System.Runtime.InteropServices;
using UnityEngine;
using Kirurobo;

/// <summary>
/// Windows 版のデスクトップマスコット用。
///
/// Windows ビルドのときだけ:
///   - 背景スプライトなど、透過の邪魔になるものを消す
///   - UniWindowController を有効にして透過ウィンドウにする
///   - カメラをずらしてキャラを窓の右寄りに配置する（左を吹き出し用に空ける）
///   - Ctrl+Q で Unity と Flutter をまとめて終了する
///   - ウィンドウ位置を記憶して、次回起動時に同じ場所へ戻す
///   - ライムのクリックとウィンドウ移動を Flutter へ通知する
///
/// マウスもキーボードも UnityEngine.Input を使わず Win32 API で拾う。
/// このプロジェクトは新しい Input System を使っており、
/// 旧来の UnityEngine.Input が反応しないため。
/// クリックスルー中はウィンドウがフォーカスを取れないという事情もある。
///
/// Android / iOS では何も起きない。
/// </summary>
public class WindowsOverlayController : MonoBehaviour
{
    [Header("透過ウィンドウ")]
    [Tooltip("UniWindowController を載せた GameObject。シーン上では無効にしておく")]
    [SerializeField] private GameObject overlayRoot;

    [Header("Windows では非表示にするもの")]
    [Tooltip("background など。描画されると透過ウィンドウでも背景が残る")]
    [SerializeField] private GameObject[] hideOnWindows;

    [Header("カメラ位置の調整")]
    [Tooltip("キャラを窓の右寄りに置くためのカメラ移動量(ワールド単位)。" +
             "マイナスでキャラが右へ寄る。0 で調整しない")]
    [SerializeField] private float cameraOffsetX = 0f;

    [Tooltip("縦方向の調整。マイナスでキャラが上へ寄る")]
    [SerializeField] private float cameraOffsetY = 0f;

    [Header("Flutter への通知")]
    [Tooltip("WebSocket 送信を担当する RAiMCharacterController")]
    [SerializeField] private RAiMCharacterController characterController;

    [Tooltip("ライムのクリックを Flutter に通知する（入力小窓を開くため）")]
    [SerializeField] private bool notifyClick = true;

    [Tooltip("ドラッグとみなすウィンドウ移動量(px)。これ未満ならクリック扱い")]
    [SerializeField] private float dragThreshold = 4f;

    [Tooltip("ウィンドウ位置を Flutter に通知する（入力小窓を追従させるため）")]
    [SerializeField] private bool notifyMove = true;

    [Tooltip("移動通知の間隔(秒)。細かく送りすぎないよう間引く")]
    [SerializeField] private float moveNotifyInterval = 0.016f;

    [Tooltip("位置が変わっていなくても強制的に送る間隔(秒)。" +
             "起動直後や再接続直後に Flutter が位置を知らないままになるのを防ぐ")]
    [SerializeField] private float forceNotifyInterval = 2f;

    [Header("画面外へのはみ出し防止")]
    [Tooltip("ドラッグでライムが画面外へ出ないよう押し戻す")]
    [SerializeField] private bool clampToScreen = true;

    [Tooltip("画面端に残す余白(px)。0 でぴったりまで寄せられる")]
    [SerializeField] private float screenMargin = 0f;

    [Header("終了ショートカット")]
    [Tooltip("クリックスルー中はウィンドウを閉じられないので脱出口を用意する")]
    [SerializeField] private bool enableQuitShortcut = true;

    [Tooltip("Ctrl と同時に押すキー。他アプリのショートカットと衝突する場合は変更する")]
    [SerializeField] private KeyCode quitKey = KeyCode.Q;

    [Tooltip("Shift も必要にする。Ctrl+Q が他アプリと衝突するときに使う")]
    [SerializeField] private bool requireShift = false;

    [Tooltip("Ctrl+Q で Flutter 側も一緒に終了させる")]
    [SerializeField] private bool quitFlutterToo = true;

    [Tooltip("終了通知が Flutter に届くのを待つ秒数")]
    [SerializeField] private float quitNotifyDelay = 0.3f;

    [Header("ウィンドウ位置の記憶")]
    [Tooltip("終了時に位置を保存し、次回起動時に復元する")]
    [SerializeField] private bool rememberPosition = true;

    [Header("常駐時のフレームレート")]
    [Tooltip("一日中動かすので抑える。0 で変更しない")]
    [SerializeField] private int targetFrameRate = 30;

    [Header("デバッグ")]
    [Tooltip("起動時にウィンドウサイズ・座標・キャラの占有範囲をログに出す")]
    [SerializeField] private bool logWindowInfoOnStart = true;

    private bool isWindowsOverlay = false;

    // ------------------------------------------------------------
    // Win32
    // ------------------------------------------------------------

#if UNITY_STANDALONE_WIN
    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out POINT lpPoint);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter,
        int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int nIndex);

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint dwFlags);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    private static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MONITORINFO
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
    }

    private const uint MONITOR_DEFAULTTONEAREST = 2;

    /// <summary>
    /// ライムが今いるモニタの作業領域（タスクバーを除いた範囲）を返す。
    /// Flutter の入力小窓をそのモニタ内に収めるために送る。
    /// </summary>
    private bool TryGetCurrentMonitorWorkArea(out RECT work)
    {
        work = default;

        IntPtr hwnd = GetSelfWindow();
        if (hwnd == IntPtr.Zero) return false;

        IntPtr monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        if (monitor == IntPtr.Zero) return false;

        var info = new MONITORINFO();
        info.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
        if (!GetMonitorInfo(monitor, ref info)) return false;

        work = info.rcWork;
        return true;
    }

    // 仮想デスクトップ（全モニタを合わせた矩形）
    private const int SM_XVIRTUALSCREEN = 76;
    private const int SM_YVIRTUALSCREEN = 77;
    private const int SM_CXVIRTUALSCREEN = 78;
    private const int SM_CYVIRTUALSCREEN = 79;

    private const uint SWP_NOSIZE = 0x0001;
    private const uint SWP_NOZORDER = 0x0004;
    private const uint SWP_NOACTIVATE = 0x0010;

    /// <summary>
    /// 自分のウィンドウハンドル。
    /// クリックスルー中は GetActiveWindow が使えないため、
    /// Unity のウィンドウクラス名から探す。
    /// </summary>
    private IntPtr _hwnd = IntPtr.Zero;

    private IntPtr GetSelfWindow()
    {
        if (_hwnd != IntPtr.Zero) return _hwnd;
        _hwnd = FindWindow("UnityWndClass", null);
        return _hwnd;
    }

    /// <summary>
    /// ウィンドウの実座標を取得する（画面座標・左上原点・仮想デスクトップ基準）。
    ///
    /// UniWindowController の windowPosition は Y が下から上で、
    /// しかもプライマリモニタの高さを基準に反転しているため、
    /// サブモニタでは正しい値にならない。
    /// GetWindowRect なら OS が持っている実座標がそのまま取れる。
    /// </summary>
    private bool TryGetWindowRect(out RECT rect)
    {
        rect = default;
        IntPtr hwnd = GetSelfWindow();
        if (hwnd == IntPtr.Zero) return false;
        return GetWindowRect(hwnd, out rect);
    }

    private const int VK_LBUTTON = 0x01;
    private const int VK_SHIFT = 0x10;
    private const int VK_CONTROL = 0x11;

    /// <summary>
    /// キーが物理的に押されているか。フォーカスと無関係に読める。
    /// </summary>
    private static bool IsKeyDown(int vKey)
    {
        if (vKey == 0) return false;
        return (GetAsyncKeyState(vKey) & 0x8000) != 0;
    }
#endif

    private bool quitComboWasDown = false;
    private bool leftButtonWasDown = false;
    private bool quitting = false;

    // クリック / ドラッグ判定用
    private Vector2 windowPosOnMouseDown;
    private bool mouseDownOnCharacter = false;

    // 移動通知の間引き用
    private Vector2 lastNotifiedPosition;
    private float moveNotifyTimer = 0f;
    private float forceNotifyTimer = 0f;
    private bool hasNotifiedOnce = false;

    // 位置保存用のキー
    private const string PrefKeyX = "raim_window_x";
    private const string PrefKeyY = "raim_window_y";

    // ------------------------------------------------------------
    // 起動
    // ------------------------------------------------------------

    private void Awake()
    {
#if UNITY_STANDALONE_WIN
        isWindowsOverlay = true;

        // 背景など、透過の邪魔になるものを先に消す。
        // カメラの Clear Color(Alpha 0) は「何も描かれなかったピクセル」にしか
        // 効かないため、スプライトが描画されるとそこは不透明のまま残る。
        int hidden = 0;
        if (hideOnWindows != null)
        {
            foreach (var obj in hideOnWindows)
            {
                if (obj == null) continue;
                obj.SetActive(false);
                hidden++;
            }
        }
        Debug.Log($"[Overlay] Windows: {hidden}個のオブジェクトを非表示にしました");

        ApplyCameraOffset();

        if (overlayRoot != null)
        {
            overlayRoot.SetActive(true);
            Debug.Log("[Overlay] Windows: 透過ウィンドウを有効化");
        }
        else
        {
            Debug.LogWarning("[Overlay] overlayRoot が未設定です");
        }

        if (characterController == null)
        {
            characterController = FindObjectOfType<RAiMCharacterController>();
        }

        if (targetFrameRate > 0)
        {
            Application.targetFrameRate = targetFrameRate;
        }

        // 最小化されても Flutter からのメッセージを処理し続ける
        Application.runInBackground = true;
#else
        isWindowsOverlay = false;
#endif
    }

    /// <summary>
    /// キャラを窓の中で右寄りに配置する。
    ///
    /// 吹き出しはウィンドウの内側にしか描けないため、キャラを中央に置くと
    /// 左右どちらにも吹き出し分の余白が必要になり、窓が横に広がってしまう。
    /// キャラを右に寄せれば左側だけを確保すればよく、
    /// そのぶん画面の右端までライムを近づけられる。
    ///
    /// キャラの Transform ではなくカメラを動かすのは、
    /// シーンをモバイルと共有しているため。
    /// </summary>
    private void ApplyCameraOffset()
    {
        if (cameraOffsetX == 0f && cameraOffsetY == 0f) return;

        var cam = Camera.main;
        if (cam == null)
        {
            Debug.LogWarning("[Overlay] Main Camera が見つかりません");
            return;
        }

        var pos = cam.transform.position;
        pos.x += cameraOffsetX;
        pos.y += cameraOffsetY;
        cam.transform.position = pos;

        Debug.Log($"[Overlay] カメラを移動: offset=({cameraOffsetX}, {cameraOffsetY})");
    }

    /// <summary>
    /// UniWindowController の初期化は Awake の直後には終わっていないため、
    /// ログ出力は1フレーム待ってから行う。
    /// </summary>
    private IEnumerator Start()
    {
        if (!isWindowsOverlay) yield break;

        RestoreWindowPosition();

        yield return null;

        if (logWindowInfoOnStart)
        {
            LogWindowInfo();
        }

    }

    // ------------------------------------------------------------
    // 毎フレーム
    // ------------------------------------------------------------

    private void Update()
    {
        if (!isWindowsOverlay || quitting) return;

        HandleQuitShortcut();
        HandleClickDetection();
        ClampWindowToScreen();
        HandleMoveNotification();
    }

    // ============================================================
    // 画面外へのはみ出し防止
    // ============================================================
    //
    // DragMoveCanvas は毎フレーム windowPosition を書き換えるので、
    // その後に押し戻す。ウィンドウではなく「ライムの見えている範囲」を
    // 基準にするので、透明な余白のぶんは画面外に出てよい。

    // ============================================================
    // 終了ショートカット
    // ============================================================

    private void HandleQuitShortcut()
    {
        if (!enableQuitShortcut) return;

#if UNITY_STANDALONE_WIN
        bool ctrl = IsKeyDown(VK_CONTROL);
        bool shift = !requireShift || IsKeyDown(VK_SHIFT);
        bool key = IsKeyDown(ToVirtualKey(quitKey));

        bool down = ctrl && shift && key;

        // 押しっぱなしで何度も走らないよう、立ち上がりだけを見る
        if (down && !quitComboWasDown)
        {
            Debug.Log("[Overlay] 終了ショートカットが押されました");
            StartCoroutine(QuitRoutine());
        }
        quitComboWasDown = down;
#endif
    }

    /// <summary>
    /// Flutter へ終了を伝えてから自分も落ちる。
    ///
    /// SendToFlutter は非同期なので、送信が WebSocket に乗る前に
    /// Application.Quit() すると届かない。少し待ってから終了する。
    /// </summary>
    private IEnumerator QuitRoutine()
    {
        quitting = true;
        SaveWindowPosition();

        if (quitFlutterToo)
        {
            Debug.Log("[Overlay] Flutter へ終了を通知します");
            SendToFlutter("{\"type\":\"unity.quit\"}");
            yield return new WaitForSecondsRealtime(quitNotifyDelay);
        }

#if UNITY_EDITOR
        UnityEditor.EditorApplication.isPlaying = false;
#else
        Application.Quit();
#endif
    }

    // ============================================================
    // クリック / ドラッグの判定
    // ============================================================
    //
    // DragMoveCanvas が左ドラッグでウィンドウを動かすため、
    // 「押して離した」だけをクリックとして拾う必要がある。
    //
    // カーソルのスクリーン座標では判定できないことに注意。
    // ドラッグ中はウィンドウごと動くので、ウィンドウとの相対位置が
    // ほとんど変わらない。代わりにウィンドウ自体が動いたかどうかを見る。

    private void HandleClickDetection()
    {
        if (!notifyClick) return;

#if UNITY_STANDALONE_WIN
        bool down = IsKeyDown(VK_LBUTTON);

        // 押した瞬間
        if (down && !leftButtonWasDown)
        {
            mouseDownOnCharacter = IsCursorOverCharacter();
            windowPosOnMouseDown = CurrentWindowPosition();
        }

        // 離した瞬間
        if (!down && leftButtonWasDown && mouseDownOnCharacter)
        {
            mouseDownOnCharacter = false;

            float moved = (CurrentWindowPosition() - windowPosOnMouseDown).magnitude;
            if (moved < dragThreshold)
            {
                Debug.Log("[Overlay] ライムがクリックされました");
                SendToFlutter("{\"type\":\"unity.clicked\"}");
            }
            else
            {
                NotifyMove(force: true);
                SaveWindowPosition();
            }
        }

        leftButtonWasDown = down;
#endif
    }

#if UNITY_STANDALONE_WIN
    /// <summary>
    /// カーソルがライムのスプライト範囲にあるか。
    ///
    /// GetCursorPos もウィンドウ矩形も画面座標（左上原点）なので、
    /// 引き算でウィンドウ内座標になる。
    /// Unity のスクリーン座標は左下原点なので Y だけ反転する。
    ///
    /// 判定はスプライトの矩形。髪の横の透明な部分でも反応する。
    /// </summary>
    private bool IsCursorOverCharacter()
    {
        if (!GetCursorPos(out POINT p)) return false;
        if (!TryGetWindowRect(out RECT r)) return false;

        float localX = p.X - r.Left;
        float localY = Screen.height - (p.Y - r.Top);

        var cam = Camera.main;
        var sr = FindObjectOfType<SpriteRenderer>();
        if (cam == null || sr == null) return false;

        Vector3 bMin = cam.WorldToScreenPoint(sr.bounds.min);
        Vector3 bMax = cam.WorldToScreenPoint(sr.bounds.max);

        return localX >= bMin.x && localX <= bMax.x
            && localY >= bMin.y && localY <= bMax.y;
    }

    /// <summary>
    /// UnityEngine.KeyCode を Win32 の仮想キーコードに変換する。
    /// A-Z / 0-9 / Escape だけ対応していれば足りる。
    /// </summary>
    private static int ToVirtualKey(KeyCode code)
    {
        if (code >= KeyCode.A && code <= KeyCode.Z)
        {
            return 0x41 + (code - KeyCode.A);
        }
        if (code >= KeyCode.Alpha0 && code <= KeyCode.Alpha9)
        {
            return 0x30 + (code - KeyCode.Alpha0);
        }
        if (code == KeyCode.Escape) return 0x1B;
        return 0;
    }
#endif

    // ============================================================
    // 画面外へのはみ出し防止
    // ============================================================

    private void ClampWindowToScreen()
    {
        if (!clampToScreen) return;

        var cam = Camera.main;
        var sr = FindObjectOfType<SpriteRenderer>();
        if (cam == null || sr == null) return;

        if (!TryGetWindowRect(out RECT r)) return;

        int w = r.Right - r.Left;
        int h = r.Bottom - r.Top;
        if (w <= 0 || h <= 0) return;

        // ウィンドウ内でのキャラの位置（Unityのスクリーン座標＝左下原点）
        Vector3 bMin = cam.WorldToScreenPoint(sr.bounds.min);
        Vector3 bMax = cam.WorldToScreenPoint(sr.bounds.max);

        // 画面座標（左上原点）へ直す
        float charLeft = r.Left + bMin.x;
        float charRight = r.Left + bMax.x;
        float charTop = r.Top + (Screen.height - bMax.y);
        float charBottom = r.Top + (Screen.height - bMin.y);

        // 全モニタを合わせた矩形。サブモニタへ移動しても弾かれない。
        float vx = GetSystemMetrics(SM_XVIRTUALSCREEN);
        float vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
        float vw = GetSystemMetrics(SM_CXVIRTUALSCREEN);
        float vh = GetSystemMetrics(SM_CYVIRTUALSCREEN);

        float minX = vx + screenMargin;
        float maxX = vx + vw - screenMargin;
        float minY = vy + screenMargin;
        float maxY = vy + vh - screenMargin;

        float dx = 0f;
        float dy = 0f;

        if (charLeft < minX) dx = minX - charLeft;
        else if (charRight > maxX) dx = maxX - charRight;

        if (charTop < minY) dy = minY - charTop;
        else if (charBottom > maxY) dy = maxY - charBottom;

        if (Mathf.Abs(dx) < 0.5f && Mathf.Abs(dy) < 0.5f) return;

        IntPtr hwnd = GetSelfWindow();
        if (hwnd == IntPtr.Zero) return;

        SetWindowPos(hwnd, IntPtr.Zero,
            r.Left + Mathf.RoundToInt(dx),
            r.Top + Mathf.RoundToInt(dy),
            0, 0,
            SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    }

    private void HandleMoveNotification()
    {
        if (!notifyMove) return;

        // 位置が変わっていなくても定期的に送り直す。
        // Flutter が後から起動した場合や再接続した場合、
        // 差分だけ送る方式だと相手はいつまでも位置を知らないままになる。
        forceNotifyTimer -= Time.deltaTime;
        if (forceNotifyTimer <= 0f || !hasNotifiedOnce)
        {
            forceNotifyTimer = forceNotifyInterval;
            NotifyMove(force: true);
            return;
        }

        moveNotifyTimer -= Time.deltaTime;
        if (moveNotifyTimer > 0f) return;

        moveNotifyTimer = moveNotifyInterval;
        NotifyMove();
    }

    private void NotifyMove(bool force = false)
    {
        // OS から実座標を取る。マルチモニタでもそのまま使える。
        if (!TryGetWindowRect(out RECT r))
        {
            return;
        }

        var pos = new Vector2(r.Left, r.Top);

        if (!force && (pos - lastNotifiedPosition).sqrMagnitude < 1f) return;
        lastNotifiedPosition = pos;
        hasNotifiedOnce = true;

        int x = r.Left;
        int y = r.Top;
        int w = r.Right - r.Left;
        int h = r.Bottom - r.Top;

        // ライムの足元の座標も送る。
        // ウィンドウの中でキャラがどこにいるかは cameraOffset や
        // モデルの差し替えで変わるので、Flutter 側で推測させない。
        // cx = キャラ中心のX、cy = 足元のY（どちらも画面座標・上原点）
        int cx = x + w / 2;
        int cy = y + h;

        var cam = Camera.main;
        var sr = FindObjectOfType<SpriteRenderer>();
        if (cam != null && sr != null)
        {
            // Unity のスクリーン座標は左下原点・Y上向き
            Vector3 bMin = cam.WorldToScreenPoint(sr.bounds.min);
            Vector3 bMax = cam.WorldToScreenPoint(sr.bounds.max);

            cx = x + Mathf.RoundToInt((bMin.x + bMax.x) * 0.5f);
            cy = y + Mathf.RoundToInt(Screen.height - bMin.y);
        }

        // ライムがいるモニタの作業領域。
        // Flutter はこの中に入力小窓を収める。
        // モニタごとに解像度もタスクバー位置も違うので、
        // Flutter 側で調べさせず Unity が測って渡す。
        int mx = 0, my = 0, mw = 0, mh = 0;
        if (TryGetCurrentMonitorWorkArea(out RECT work))
        {
            mx = work.Left;
            my = work.Top;
            mw = work.Right - work.Left;
            mh = work.Bottom - work.Top;
        }

        string json = "{\"type\":\"unity.moved\"," +
                      "\"x\":" + x + ",\"y\":" + y + "," +
                      "\"width\":" + w + ",\"height\":" + h + "," +
                      "\"cx\":" + cx + ",\"cy\":" + cy + "," +
                      "\"mx\":" + mx + ",\"my\":" + my + "," +
                      "\"mw\":" + mw + ",\"mh\":" + mh + "}";

        SendToFlutter(json);
    }

    /// <summary>
    /// ウィンドウの左上座標（画面座標）。取得できなければゼロ。
    /// </summary>
    private Vector2 CurrentWindowPosition()
    {
        if (TryGetWindowRect(out RECT r))
        {
            return new Vector2(r.Left, r.Top);
        }
        return Vector2.zero;
    }

    private void SendToFlutter(string json)
    {
        if (characterController == null) return;
        characterController.SendToFlutter(json);
    }

    // ------------------------------------------------------------
    // ウィンドウ情報のログ
    // ------------------------------------------------------------

    private void LogWindowInfo()
    {
        var controller = UniWindowController.current;
        var res = Screen.currentResolution;

        if (controller != null)
        {
            Debug.Log(
                $"[Overlay] windowSize={controller.windowSize} " +
                $"clientSize={controller.clientSize} " +
                $"windowPosition={controller.windowPosition} " +
                $"screen={res.width}x{res.height} " +
                $"Screen.width/height={Screen.width}x{Screen.height} " +
                $"dpi={Screen.dpi}"
            );
        }
        else
        {
            Debug.LogWarning("[Overlay] UniWindowController が見つかりません");
        }

        LogCharacterBounds();
    }

    /// <summary>
    /// キャラクターの画面上での占有範囲を測る。
    /// 必要なウィンドウ幅 = キャラ幅 + 吹き出しのオフセット + 吹き出し幅/2 + 余白
    /// </summary>
    private void LogCharacterBounds()
    {
        var cam = Camera.main;
        if (cam == null) return;

        var sr = FindObjectOfType<SpriteRenderer>();
        if (sr == null) return;

        Vector3 min = cam.WorldToScreenPoint(sr.bounds.min);
        Vector3 max = cam.WorldToScreenPoint(sr.bounds.max);

        Debug.Log(
            $"[Overlay] character screen bounds: " +
            $"x={min.x:F0}〜{max.x:F0} ({max.x - min.x:F0}px) " +
            $"y={min.y:F0}〜{max.y:F0} ({max.y - min.y:F0}px) " +
            $"center=({(min.x + max.x) * 0.5f:F0}, {(min.y + max.y) * 0.5f:F0})"
        );
    }

    // ------------------------------------------------------------
    // ウィンドウ位置の保存・復元
    // ------------------------------------------------------------

    private void RestoreWindowPosition()
    {
        if (!rememberPosition) return;
        if (!PlayerPrefs.HasKey(PrefKeyX)) return;

        var controller = UniWindowController.current;
        if (controller == null) return;

        float x = PlayerPrefs.GetFloat(PrefKeyX);
        float y = PlayerPrefs.GetFloat(PrefKeyY);
        var pos = new Vector2(x, y);

        if (!IsPositionVisible(pos))
        {
            Debug.LogWarning($"[Overlay] 保存位置 {pos} が画面外のため復元しません");
            return;
        }

        controller.windowPosition = pos;
        Debug.Log($"[Overlay] ウィンドウ位置を復元: {pos}");
    }

    private void SaveWindowPosition()
    {
        if (!rememberPosition) return;

        var controller = UniWindowController.current;
        if (controller == null) return;

        var pos = controller.windowPosition;
        PlayerPrefs.SetFloat(PrefKeyX, pos.x);
        PlayerPrefs.SetFloat(PrefKeyY, pos.y);
        PlayerPrefs.Save();
    }

    /// <summary>
    /// モニタ構成が変わって完全に画面外になっていないかを見る。
    /// </summary>
    private bool IsPositionVisible(Vector2 pos)
    {
        const float margin = 10000f;
        return pos.x > -margin && pos.x < margin
            && pos.y > -margin && pos.y < margin;
    }

    // ------------------------------------------------------------
    // 終了処理
    // ------------------------------------------------------------

    private void OnApplicationQuit()
    {
        if (!isWindowsOverlay) return;
        SaveWindowPosition();
    }
}
