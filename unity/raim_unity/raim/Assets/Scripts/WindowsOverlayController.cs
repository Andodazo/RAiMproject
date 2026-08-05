using System.Runtime.InteropServices;
using UnityEngine;
using Kirurobo;

/// <summary>
/// Windows 版のデスクトップマスコット用。
///
/// Windows ビルドのときだけ:
///   - 背景スプライトなど、透過の邪魔になるものを消す
///   - UniWindowController を有効にして透過ウィンドウにする
///   - Ctrl+Q の脱出口を用意する（クリックスルー中でも効く）
///   - ウィンドウ位置を記憶して、次回起動時に同じ場所へ戻す
///   - 起動時にウィンドウサイズ等をログ出力する（吹き出し設計用）
///
/// Android / iOS では何も起きない。
/// RAiMCharacterController.cs は変更しない。
/// </summary>
public class WindowsOverlayController : MonoBehaviour
{
    [Header("透過ウィンドウ")]
    [Tooltip("UniWindowController を載せた GameObject。シーン上では無効にしておく")]
    [SerializeField] private GameObject overlayRoot;

    [Header("Windows では非表示にするもの")]
    [Tooltip("background など。描画されると透過ウィンドウでも背景が残る")]
    [SerializeField] private GameObject[] hideOnWindows;

    [Header("終了ショートカット")]
    [Tooltip("クリックスルー中はウィンドウを閉じられないので脱出口を用意する")]
    [SerializeField] private bool enableQuitShortcut = true;

    [Tooltip("Ctrl と同時に押すキー。他アプリのショートカットと衝突する場合は変更する")]
    [SerializeField] private KeyCode quitKey = KeyCode.Q;

    [Tooltip("Shift も必要にする。Ctrl+Q が他アプリと衝突するときに使う")]
    [SerializeField] private bool requireShift = false;

    [Header("ウィンドウ位置の記憶")]
    [Tooltip("終了時に位置を保存し、次回起動時に復元する")]
    [SerializeField] private bool rememberPosition = true;

    [Header("常駐時のフレームレート")]
    [Tooltip("一日中動かすので抑える。0 で変更しない")]
    [SerializeField] private int targetFrameRate = 30;

    [Header("デバッグ")]
    [Tooltip("起動時にウィンドウサイズ・座標・画面解像度をログに出す")]
    [SerializeField] private bool logWindowInfoOnStart = true;

    private bool isWindowsOverlay = false;

    // ------------------------------------------------------------
    // Win32: フォーカスに依存しないキー入力
    // ------------------------------------------------------------
    // クリックスルー中はウィンドウがフォアグラウンドになれず、
    // Unity の Input.GetKey がまったく反応しない。
    // GetAsyncKeyState はフォーカスと無関係にキーの物理状態を読めるので、
    // 透過オーバーレイからでも終了ショートカットを拾える。

#if UNITY_STANDALONE_WIN
    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);

    private const int VK_CONTROL = 0x11;
    private const int VK_SHIFT = 0x10;

    private static bool IsKeyDown(int vKey)
    {
        if (vKey == 0) return false;
        return (GetAsyncKeyState(vKey) & 0x8000) != 0;
    }
#endif

    private bool quitComboWasDown = false;

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

        // 透過ウィンドウを有効化。
        // DragMoveCanvas を子にしておけば、これで一緒に有効になる。
        if (overlayRoot != null)
        {
            overlayRoot.SetActive(true);
            Debug.Log("[Overlay] Windows: 透過ウィンドウを有効化");
        }
        else
        {
            Debug.LogWarning("[Overlay] overlayRoot が未設定です");
        }

        if (targetFrameRate > 0)
        {
            Application.targetFrameRate = targetFrameRate;
        }

        // 最小化されても Flutter からのメッセージを処理し続ける
        Application.runInBackground = true;
#else
        // モバイルでは何もしない。背景もそのまま表示される。
        isWindowsOverlay = false;
#endif
    }

    private void Start()
    {
        if (!isWindowsOverlay) return;

        RestoreWindowPosition();

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
        if (!isWindowsOverlay || !enableQuitShortcut) return;

#if UNITY_STANDALONE_WIN
        bool ctrl = IsKeyDown(VK_CONTROL);
        bool shift = !requireShift || IsKeyDown(VK_SHIFT);
        bool key = IsKeyDown(ToVirtualKey(quitKey));

        bool down = ctrl && shift && key;

        // 押しっぱなしで何度も走らないよう、立ち上がりだけを見る
        if (down && !quitComboWasDown)
        {
            Debug.Log("[Overlay] 終了ショートカットが押されました");
            QuitApplication();
        }
        quitComboWasDown = down;
#endif
    }

#if UNITY_STANDALONE_WIN
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

    // ------------------------------------------------------------
    // ウィンドウ情報のログ
    // ------------------------------------------------------------

    /// <summary>
    /// 吹き出しのレイアウトを決めるための情報を出す。
    ///
    /// - clientSize : 実際の描画領域。吹き出し用の余白を足す基準になる
    /// - windowSize : 枠込みのサイズ。clientSize と同じなら枠なし
    /// - screen     : 画面端の判定（吹き出しを左右どちらに出すか）に使う
    /// - Screen.w/h : Unity の描画解像度。windowSize とズレていたら高DPIの影響
    /// </summary>
    private void LogWindowInfo()
    {
        var controller = UniWindowController.current;
        if (controller == null)
        {
            Debug.LogWarning("[Overlay] UniWindowController が見つかりません");
            return;
        }

        var res = Screen.currentResolution;
        Debug.Log(
            $"[Overlay] windowSize={controller.windowSize} " +
            $"clientSize={controller.clientSize} " +
            $"windowPosition={controller.windowPosition} " +
            $"screen={res.width}x{res.height} " +
            $"Screen.width/height={Screen.width}x{Screen.height} " +
            $"dpiScale={Screen.dpi}"
        );
    }

    // ------------------------------------------------------------
    // ウィンドウ位置の保存・復元
    // ------------------------------------------------------------

    /// <summary>
    /// 前回終了時の位置に戻す。
    /// 画面構成が変わって範囲外になっていた場合は既定位置のままにする。
    /// </summary>
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
        Debug.Log($"[Overlay] ウィンドウ位置を保存: {pos}");
    }

    /// <summary>
    /// モニタ構成が変わって完全に画面外になっていないかを見る。
    /// ざっくり判定で十分（厳密なマルチモニタ計算はしない）。
    /// </summary>
    private bool IsPositionVisible(Vector2 pos)
    {
        // 全モニタを合わせた大まかな範囲。負の座標もありうるので広めに取る。
        const float margin = 10000f;
        return pos.x > -margin && pos.x < margin
            && pos.y > -margin && pos.y < margin;
    }

    // ------------------------------------------------------------
    // 終了処理
    // ------------------------------------------------------------

    private void QuitApplication()
    {
        SaveWindowPosition();

#if UNITY_EDITOR
        UnityEditor.EditorApplication.isPlaying = false;
#else
        Application.Quit();
#endif
    }

    /// <summary>
    /// × ボタンやシャットダウンなど、別経路で落ちた場合も位置を残す。
    /// タスクマネージャーでの強制終了時は呼ばれない。
    /// </summary>
    private void OnApplicationQuit()
    {
        if (!isWindowsOverlay) return;
        SaveWindowPosition();
    }
}