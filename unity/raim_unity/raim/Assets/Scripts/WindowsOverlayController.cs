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

    [Tooltip("カーソルがライムの上にあるときだけ終了ショートカットを受け付ける。" +
             "他アプリで Ctrl+Q を押したときの誤爆を防ぐ")]
    [SerializeField] private bool requireCursorOverCharacterToQuit = true;

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

    [Tooltip("フォーカスが無いときのフレームレート。常駐中のCPUとバッテリーを抑える。" +
             "動きがカクつくようなら targetFrameRate と同じ値にする")]
    [SerializeField] private int unfocusedFrameRate = 15;

    [Header("デバッグ")]
    [Tooltip("起動時にウィンドウサイズ・座標・キャラの占有範囲をログに出す")]
    [SerializeField] private bool logWindowInfoOnStart = true;

    private bool isWindowsOverlay = false;

    // 毎フレーム参照するのでキャッシュする。
    // FindObjectOfType を Update から呼ぶとシーン全体を走査するため重い。
    private Camera _cam;
    private SpriteRenderer _sprite;

    private Camera Cam => _cam != null ? _cam : (_cam = Camera.main);

    private SpriteRenderer Sprite
    {
        get
        {
            if (_sprite == null)
            {
#if UNITY_2023_1_OR_NEWER
                _sprite = FindFirstObjectByType<SpriteRenderer>();
#else
                _sprite = FindObjectOfType<SpriteRenderer>();
#endif
            }
            return _sprite;
        }
    }

    // ------------------------------------------------------------
    // Win32
    // ------------------------------------------------------------

#if UNITY_STANDALONE_WIN
    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out POINT lpPoint);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    private static extern IntPtr FindWindowEx(IntPtr hWndParent, IntPtr hWndChildAfter,
        string lpszClass, string lpszWindow);

    [DllImport("user32.dll")]
    private static extern IntPtr GetActiveWindow();

    // 指定座標の最前面ウィンドウ。カーソル下にあるのが本当に自分かを見るため。
    [DllImport("user32.dll")]
    private static extern IntPtr WindowFromPoint(POINT point);

    // 子ウィンドウから親のトップレベルウィンドウを辿る。
    // WindowFromPoint は描画用の子ウィンドウを返すことがあるため。
    [DllImport("user32.dll")]
    private static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);

    private const uint GA_ROOT = 2;

    private static IntPtr GetAncestorRoot(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return IntPtr.Zero;
        return GetAncestor(hwnd, GA_ROOT);
    }

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentProcessId();

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
    ///
    /// クリックスルー中は GetActiveWindow が使えない。
    /// クラス名で探す FindWindow も、Unity Editor が同時に開いていると
    /// そちらを掴んでしまうことがあるため、
    /// 自プロセスの可視トップレベルウィンドウを列挙して特定する。
    /// </summary>
    private IntPtr _hwnd = IntPtr.Zero;

    private IntPtr GetSelfWindow()
    {
        if (_hwnd != IntPtr.Zero) return _hwnd;

        uint myPid = GetCurrentProcessId();

        // ① 起動直後はまだフォーカスがあるので、これで取れることが多い
        IntPtr active = GetActiveWindow();
        if (IsOwnWindow(active, myPid))
        {
            _hwnd = active;
        }

        // ② Unity のウィンドウクラスを総当たりする。
        //    FindWindow はクラス名が一致した最初の1つしか返さず、
        //    Editor が開いているとそちらを掴んでしまうため、
        //    FindWindowEx で次々に辿って自プロセスのものを探す。
        if (_hwnd == IntPtr.Zero)
        {
            _hwnd = FindOwnWindowByClass("UnityWndClass", myPid);
        }

        // ③ クラス名が違う場合に備えて、全トップレベルウィンドウを辿る
        if (_hwnd == IntPtr.Zero)
        {
            _hwnd = FindOwnWindowByClass(null, myPid);
        }

        if (_hwnd == IntPtr.Zero)
        {
            Debug.LogWarning("[Overlay] 自分のウィンドウハンドルが取得できません");
        }
        else
        {
            Debug.Log($"[Overlay] ウィンドウハンドルを取得: {_hwnd}");
        }

        return _hwnd;
    }

    /// <summary>
    /// 指定クラス名（null なら全部）のトップレベルウィンドウを順に辿り、
    /// 自プロセスのものを返す。
    ///
    /// EnumWindows はコールバックを native へ渡すため IL2CPP ビルドでは
    /// 動作しない。FindWindowEx なら hWndChildAfter で列挙を継続でき、
    /// コールバックが要らない。
    /// </summary>
    private IntPtr FindOwnWindowByClass(string className, uint myPid)
    {
        IntPtr h = IntPtr.Zero;
        for (int i = 0; i < 200; i++)
        {
            h = FindWindowEx(IntPtr.Zero, h, className, null);
            if (h == IntPtr.Zero) break;
            if (IsOwnWindow(h, myPid)) return h;
        }
        return IntPtr.Zero;
    }

    private bool IsOwnWindow(IntPtr hWnd, uint myPid)
    {
        if (hWnd == IntPtr.Zero) return false;
        if (!IsWindowVisible(hWnd)) return false;

        GetWindowThreadProcessId(hWnd, out uint pid);
        if (pid != myPid) return false;

        if (!GetWindowRect(hWnd, out RECT r)) return false;
        return (r.Right - r.Left) > 0 && (r.Bottom - r.Top) > 0;
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
#if UNITY_2023_1_OR_NEWER
            characterController = FindFirstObjectByType<RAiMCharacterController>();
#else
            characterController = FindObjectOfType<RAiMCharacterController>();
#endif
        }

        if (targetFrameRate > 0)
        {
            Application.targetFrameRate = targetFrameRate;
        }

        // ToVirtualKey は A-Z / 0-9 / Escape しか変換できない。
        // それ以外を指定すると IsKeyDown(0) が常に false になり、
        // 終了ショートカットが何の警告も無く効かなくなる。
        if (enableQuitShortcut && ToVirtualKey(quitKey) == 0)
        {
            Debug.LogWarning(
                $"[Overlay] quitKey={quitKey} は未対応のキーです。" +
                "終了ショートカットは動きません（A-Z / 0-9 / Escape のみ対応）"
            );
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

    /// <summary>
    /// フォーカスの有無でフレームレートを切り替える。
    ///
    /// runInBackground を有効にしているため、非フォーカスでも
    /// 30fps で描画し続けていた。常駐アプリなので、ノートPCでは
    /// バッテリーとファンに効いてくる。
    ///
    /// 透過ウィンドウはフォーカスを取りにくいので、
    /// 動きがカクつくようなら unfocusedFrameRate を
    /// targetFrameRate と同じ値にすれば元の挙動に戻る。
    /// </summary>
    private void OnApplicationFocus(bool hasFocus)
    {
        if (targetFrameRate <= 0) return;

        Application.targetFrameRate =
            hasFocus || unfocusedFrameRate <= 0
                ? targetFrameRate
                : unfocusedFrameRate;
    }

    private void HandleQuitShortcut()
    {
        if (!enableQuitShortcut) return;

#if UNITY_STANDALONE_WIN
        // GetAsyncKeyState はフォーカスと無関係にキー状態を返す。
        // つまり素通しだと事実上のグローバルホットキーになり、
        // Firefox やエディタで Ctrl+Q（＝多くのアプリの終了）を押しただけで
        // ライムが黙って消えていた。押した本人は別アプリを終了したつもりなので
        // 原因に気づけない。
        //
        // 透過ウィンドウはフォーカスを取れないため、
        // 「カーソルがライムの上にある」を代わりの条件にする。
        if (requireCursorOverCharacterToQuit && !IsCursorOverCharacter()) return;

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

        // カーソルの下にあるウィンドウが自分でなければ、そのクリックは
        // 自分のものではない。
        //
        // 以前はウィンドウ矩形に入っているかだけを見ていたため、
        // ブラウザなどがライムの手前に重なっているとき、
        // その位置をクリックしただけで入力小窓が開いていた。
        // Win32 でカーソルを直接読んでいる以上、
        // 重なりは自分で確認しないと分からない。
        IntPtr self = GetSelfWindow();
        if (self == IntPtr.Zero) return false;

        IntPtr under = WindowFromPoint(p);
        if (under != self && GetAncestorRoot(under) != self) return false;

        if (!TryGetWindowRect(out RECT r)) return false;

        float localX = p.X - r.Left;
        float localY = Screen.height - (p.Y - r.Top);

        var cam = Cam;
        var sr = Sprite;
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

        var cam = Cam;
        var sr = Sprite;
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

    /// 送信できない理由を一度だけ出すためのフラグ
    private bool warnedNoRect = false;

    private void NotifyMove(bool force = false)
    {
        // OS から実座標を取る。マルチモニタでもそのまま使える。
        if (!TryGetWindowRect(out RECT r))
        {
            if (!warnedNoRect)
            {
                warnedNoRect = true;
                Debug.LogWarning("[Overlay] ウィンドウ矩形が取得できないため位置を送れません");
            }
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

        var cam = Cam;
        var sr = Sprite;
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

        if (!hasSentMoveOnce)
        {
            hasSentMoveOnce = true;
            Debug.Log($"[Overlay] 初回の位置を送信: {json}");
        }

        SendToFlutter(json);
    }

    private bool hasSentMoveOnce = false;

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
        var cam = Cam;
        if (cam == null) return;

        var sr = Sprite;
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
