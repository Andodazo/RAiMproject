using System.Collections;
using UnityEngine;
using UnityEngine.UI;
using TMPro;

/// <summary>
/// ライムの吹き出し（Windows デスクトップマスコット用）。
///
/// RAiMCharacterController から text_chunk / bubble_break / chat_end / error を
/// 受け取り、届いた順に追記していく。サーバー側が 140〜270ms 間隔で送ってくるので、
/// 自前でウェイトを入れなくても自然なタイプライター表示になる。
///
/// 箱のサイズは uGUI の VerticalLayoutGroup + ContentSizeFitter に任せる。
/// 幅は固定、高さだけ本文に追従する。必要なコンポーネントは Awake で
/// 自動的に付けるので、Inspector 側の準備は不要。
///
/// 置き方:
///   WindowsOverlay (無効。Windowsビルド時のみ有効化)
///     └ SpeechBubbleCanvas   ← Canvas (Screen Space - Overlay)
///          └ Bubble          ← Image + CanvasGroup + このスクリプト
///               └ Text       ← TextMeshProUGUI
/// </summary>
[RequireComponent(typeof(CanvasGroup))]
public class SpeechBubbleController : MonoBehaviour
{
    [Header("参照")]
    [Tooltip("吹き出し本文の TextMeshProUGUI")]
    [SerializeField] private TextMeshProUGUI label;

    [Tooltip("吹き出しの追従先。ライムの Transform を指定する")]
    [SerializeField] private Transform anchorTarget;

    [Tooltip("しっぽ（三角）の Image。左右反転させる場合に指定。未設定でも動く")]
    [SerializeField] private RectTransform tail;

    [Header("レイアウト")]
    [Tooltip("吹き出しの幅(px)")]
    [SerializeField] private float bubbleWidth = 280f;

    [Tooltip("吹き出しの高さの上限(px)。超えたぶんは古い行から削る")]
    [SerializeField] private float maxBubbleHeight = 240f;

    [Tooltip("箱の内側の余白(px)")]
    [SerializeField] private float padding = 16f;

    [Tooltip("ライムの中心からのオフセット(px)。x は右に出すときの距離")]
    [SerializeField] private Vector2 offset = new Vector2(150f, 180f);

    [Header("表示時間")]
    [Tooltip("chat_end からの基本表示秒数")]
    [SerializeField] private float baseDuration = 4f;

    [Tooltip("1文字あたりの追加秒数")]
    [SerializeField] private float secondsPerChar = 0.15f;

    [Tooltip("表示秒数の下限 / 上限")]
    [SerializeField] private float minDuration = 5f;
    [SerializeField] private float maxDuration = 20f;

    [Header("フェード")]
    [SerializeField] private float fadeInSeconds = 0.15f;
    [SerializeField] private float fadeOutSeconds = 0.4f;

    // ------------------------------------------------------------
    // 内部状態
    // ------------------------------------------------------------

    private CanvasGroup canvasGroup;
    private RectTransform rectTransform;
    private ContentSizeFitter fitter;
    private LayoutElement layoutElement;

    /// 次の text_chunk で新しい吹き出しを始めるかどうか（bubble_break 用）
    private bool startNewBubble = true;

    /// 現在の本文
    private string currentText = "";

    /// 消去タイマーのコルーチン
    private Coroutine hideRoutine;

    /// フェードのコルーチン
    private Coroutine fadeRoutine;

    /// 右に出しているか（false なら左に反転中）
    private bool showingOnRight = true;

    private void Awake()
    {
        canvasGroup = GetComponent<CanvasGroup>();
        rectTransform = GetComponent<RectTransform>();

        if (label == null)
        {
            label = GetComponentInChildren<TextMeshProUGUI>();
        }

        SetupLayout();

        // 起動時は隠しておく
        canvasGroup.alpha = 0f;
        canvasGroup.blocksRaycasts = false;
    }

    /// <summary>
    /// 箱のレイアウトを組み立てる。
    ///
    /// 手計算だと本文の状態によってズレるので、幅の固定と高さの追従は
    /// uGUI の仕組みに任せる。必要なコンポーネントはここで自動追加するため、
    /// Inspector で Layout 系を触る必要はない。
    /// </summary>
    private void SetupLayout()
    {
        rectTransform.anchorMin = new Vector2(0.5f, 0.5f);
        rectTransform.anchorMax = new Vector2(0.5f, 0.5f);
        rectTransform.pivot = new Vector2(0.5f, 0.5f);

        // 縦に積むレイアウト。padding が箱の内側の余白になる。
        var group = GetComponent<VerticalLayoutGroup>();
        if (group == null) group = gameObject.AddComponent<VerticalLayoutGroup>();

        int pad = Mathf.RoundToInt(padding);
        group.padding = new RectOffset(pad, pad, pad, pad);
        group.childControlWidth = true;
        group.childControlHeight = true;
        group.childForceExpandWidth = true;
        group.childForceExpandHeight = false;

        // 高さだけ本文に追従させる。幅は sizeDelta の値を保つ。
        fitter = GetComponent<ContentSizeFitter>();
        if (fitter == null) fitter = gameObject.AddComponent<ContentSizeFitter>();

        fitter.horizontalFit = ContentSizeFitter.FitMode.Unconstrained;
        fitter.verticalFit = ContentSizeFitter.FitMode.PreferredSize;

        rectTransform.sizeDelta = new Vector2(bubbleWidth, rectTransform.sizeDelta.y);

        if (label == null) return;

        // 本文は折り返しあり・切り詰めなし。
        // 高さは LayoutGroup が preferredHeight を見て決めてくれる。
        label.enableWordWrapping = true;
        label.overflowMode = TextOverflowModes.Overflow;
        label.alignment = TextAlignmentOptions.TopLeft;

        layoutElement = label.GetComponent<LayoutElement>();
        if (layoutElement == null)
        {
            layoutElement = label.gameObject.AddComponent<LayoutElement>();
        }
    }

    private void LateUpdate()
    {
        if (canvasGroup.alpha <= 0f) return;
        UpdatePosition();
    }

    // ============================================================
    // 外部から呼ばれる
    // ============================================================

    /// <summary>
    /// text_chunk を受け取る。bubble_break 後の最初の1回は新規、以降は追記。
    /// </summary>
    public void AppendText(string text)
    {
        if (string.IsNullOrEmpty(text)) return;

        if (startNewBubble)
        {
            currentText = text;
            startNewBubble = false;
        }
        else
        {
            currentText += text;
        }

        ApplyText();
        Show();

        // 発話中は消さない。chat_end が来てからタイマーを開始する。
        CancelHideTimer();
    }

    /// <summary>
    /// bubble_break。次の text_chunk から新しい吹き出しにする。
    /// v14 でツールの前置きと本文を分けるために入ったメッセージ。
    /// </summary>
    public void BreakBubble()
    {
        startNewBubble = true;
    }

    /// <summary>
    /// chat_end。ここから消去タイマーを開始する。
    /// full_text が渡されれば、取りこぼし対策として最終確定に使う。
    /// </summary>
    public void EndSpeech(string fullText = null)
    {
        if (!string.IsNullOrEmpty(fullText) && string.IsNullOrEmpty(currentText))
        {
            // text_chunk を取りこぼしていた場合の保険。
            // bubble_break で分割済みのときは上書きしない。
            currentText = fullText;
            ApplyText();
            Show();
        }

        startNewBubble = true;
        StartHideTimer(currentText.Length);
    }

    /// <summary>
    /// error。サーバー側やネットワークで失敗したときに、
    /// 黙って何も出ないのを避けるため吹き出しに出す。
    /// </summary>
    public void ShowError(string message)
    {
        if (string.IsNullOrEmpty(message)) return;

        currentText = message;
        startNewBubble = true;

        ApplyText();
        Show();
        StartHideTimer(currentText.Length);
    }

    /// <summary>
    /// 即座に隠す。
    /// </summary>
    public void HideImmediately()
    {
        CancelHideTimer();
        if (fadeRoutine != null) StopCoroutine(fadeRoutine);

        canvasGroup.alpha = 0f;
        canvasGroup.blocksRaycasts = false;
        currentText = "";
        startNewBubble = true;
    }

    // ============================================================
    // 本文の反映
    // ============================================================

    private void ApplyText()
    {
        if (label == null) return;

        float innerWidth = bubbleWidth - padding * 2f;
        float maxTextHeight = maxBubbleHeight - padding * 2f;

        // 上限を超えるなら、収まるまで古い行から削る。
        // スクロールバーはマスコットには重いので出さない。
        int guard = 0;
        while (MeasureHeight(currentText, innerWidth) > maxTextHeight && guard < 200)
        {
            string trimmed = TrimFirstLine(currentText);
            if (trimmed == currentText || string.IsNullOrEmpty(trimmed)) break;

            currentText = trimmed;
            guard++;
        }

        label.text = currentText;

        // LayoutGroup に本文の高さを伝える。
        // これがないと1フレーム遅れて箱が伸びるため、
        // ストリーミング中に本文がはみ出して見える。
        if (layoutElement != null)
        {
            layoutElement.preferredHeight = MeasureHeight(currentText, innerWidth);
        }

        // 今フレームのうちに箱のサイズを確定させる
        LayoutRebuilder.ForceRebuildLayoutImmediate(rectTransform);

        // 幅は ContentSizeFitter が触らないので、念のため戻しておく
        rectTransform.sizeDelta = new Vector2(bubbleWidth, rectTransform.sizeDelta.y);
    }

    /// <summary>
    /// 指定幅で本文を組んだときの高さ(px)を返す。
    /// 実際のレイアウトを変えずに測れる。
    /// </summary>
    private float MeasureHeight(string text, float width)
    {
        if (label == null || string.IsNullOrEmpty(text)) return 0f;
        return label.GetPreferredValues(text, width, 0f).y;
    }

    /// <summary>
    /// 先頭の1文（または改行まで）を削る。
    /// 句点で切ると読みやすさが保てる。
    /// </summary>
    private string TrimFirstLine(string text)
    {
        if (string.IsNullOrEmpty(text)) return "";

        int idx = text.IndexOf('\n');
        int period = text.IndexOf('。');

        if (period >= 0 && (idx < 0 || period < idx))
        {
            idx = period;
        }

        if (idx < 0 || idx + 1 >= text.Length)
        {
            // 区切りが見つからない場合は先頭20文字を削る
            return text.Length > 20 ? text.Substring(20) : "";
        }

        return text.Substring(idx + 1);
    }

    // ============================================================
    // 位置の更新（ライムへの追従と画面端での反転）
    // ============================================================

    private void UpdatePosition()
    {
        if (anchorTarget == null) return;

        Camera cam = Camera.main;

        Vector3 screenPos = cam != null
            ? cam.WorldToScreenPoint(anchorTarget.position)
            : new Vector3(Screen.width * 0.5f, Screen.height * 0.5f, 0f);

        // 右に出したときに吹き出しの右端がウィンドウからはみ出すなら左へ反転
        float rightEdge = screenPos.x + offset.x + bubbleWidth * 0.5f;
        bool shouldShowOnRight = rightEdge <= Screen.width;

        if (shouldShowOnRight != showingOnRight)
        {
            showingOnRight = shouldShowOnRight;
            FlipTail();
        }

        float dx = showingOnRight ? offset.x : -offset.x;
        rectTransform.position = new Vector3(
            screenPos.x + dx,
            screenPos.y + offset.y,
            0f
        );

        ClampToScreen();
    }

    /// <summary>
    /// ウィンドウの外に出ないよう押し戻す。
    /// 吹き出しはウィンドウの内側にしか描けないため。
    /// </summary>
    private void ClampToScreen()
    {
        Vector3 pos = rectTransform.position;
        float halfW = rectTransform.rect.width * 0.5f;
        float halfH = rectTransform.rect.height * 0.5f;

        pos.x = Mathf.Clamp(pos.x, halfW, Screen.width - halfW);
        pos.y = Mathf.Clamp(pos.y, halfH, Screen.height - halfH);

        rectTransform.position = pos;
    }

    private void FlipTail()
    {
        if (tail == null) return;

        Vector3 scale = tail.localScale;
        scale.x = Mathf.Abs(scale.x) * (showingOnRight ? 1f : -1f);
        tail.localScale = scale;

        Vector2 anchored = tail.anchoredPosition;
        anchored.x = Mathf.Abs(anchored.x) * (showingOnRight ? -1f : 1f);
        tail.anchoredPosition = anchored;
    }

    // ============================================================
    // 表示 / 消去
    // ============================================================

    private void Show()
    {
        if (fadeRoutine != null) StopCoroutine(fadeRoutine);
        fadeRoutine = StartCoroutine(FadeTo(1f, fadeInSeconds));

        canvasGroup.blocksRaycasts = true;
        UpdatePosition();
    }

    private void StartHideTimer(int charCount)
    {
        CancelHideTimer();

        float duration = baseDuration + charCount * secondsPerChar;
        duration = Mathf.Clamp(duration, minDuration, maxDuration);

        hideRoutine = StartCoroutine(HideAfter(duration));
    }

    private void CancelHideTimer()
    {
        if (hideRoutine != null)
        {
            StopCoroutine(hideRoutine);
            hideRoutine = null;
        }
    }

    private IEnumerator HideAfter(float seconds)
    {
        float elapsed = 0f;

        while (elapsed < seconds)
        {
            // 読んでいる最中に消えるのが一番ストレスなので、
            // カーソルが吹き出しの上にある間はタイマーを止める。
            if (!IsPointerOverBubble())
            {
                elapsed += Time.deltaTime;
            }
            yield return null;
        }

        if (fadeRoutine != null) StopCoroutine(fadeRoutine);
        fadeRoutine = StartCoroutine(FadeTo(0f, fadeOutSeconds));
        yield return fadeRoutine;

        canvasGroup.blocksRaycasts = false;
        currentText = "";
        startNewBubble = true;
        hideRoutine = null;
    }

    private bool IsPointerOverBubble()
    {
        if (rectTransform == null) return false;

        return RectTransformUtility.RectangleContainsScreenPoint(
            rectTransform,
            Input.mousePosition,
            null
        );
    }

    private IEnumerator FadeTo(float targetAlpha, float seconds)
    {
        float start = canvasGroup.alpha;

        if (seconds <= 0f)
        {
            canvasGroup.alpha = targetAlpha;
            fadeRoutine = null;
            yield break;
        }

        float elapsed = 0f;
        while (elapsed < seconds)
        {
            elapsed += Time.deltaTime;
            canvasGroup.alpha = Mathf.Lerp(start, targetAlpha, elapsed / seconds);
            yield return null;
        }

        canvasGroup.alpha = targetAlpha;
        fadeRoutine = null;
    }
}