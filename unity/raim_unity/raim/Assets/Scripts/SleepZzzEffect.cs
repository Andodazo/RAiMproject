using UnityEngine;
using TMPro;

/// <summary>
/// 寝ているライムの頭の右上に「Z」を浮かべる（Windows のデスクトップマスコット用）。
///
/// サーバーにつながらない間、RAiMCharacterController が寝ている立ち絵にして、これを表示する。
/// スマホは Flutter 側で同じ表示を出すので使わない。
///
/// 位置は立ち絵の範囲から毎フレーム計算するので、ライムを動かしても付いてくる。
/// 3つの Z を少しずつずらして、左下から右上へ浮かんで消えるのを繰り返す。
/// 部品は実行時に作るので、シーンの準備は要らない。
/// </summary>
public class SleepZzzEffect : MonoBehaviour
{
    [Tooltip("Z が1つ浮かんで消えるまでの秒数")]
    [SerializeField] private float period = 2.7f;

    [Tooltip("Z の文字の大きさ(px)")]
    [SerializeField] private float fontSize = 30f;

    [Tooltip("Z が浮かぶ距離(px)。x は横、y は上")]
    [SerializeField] private Vector2 rise = new Vector2(40f, 70f);

    [Tooltip("立ち絵の中心から、Z を出し始める位置までの横のずれ（立ち絵の幅に対する割合）")]
    [SerializeField] private float rightOfCenter = 0.12f;

    [Tooltip("立ち絵の上端から、Z を出し始める位置までの下へのずれ（立ち絵の高さに対する割合）")]
    [SerializeField] private float belowTop = 0.04f;

    private static readonly Color LetterColor = Color.white;
    private static readonly Color OutlineColor = new Color(0.25f, 0.35f, 0.05f, 0.9f);

    private SpriteRenderer target;
    private GameObject canvasObject;
    private Canvas canvas;
    private RectTransform root;
    private readonly TextMeshProUGUI[] letters = new TextMeshProUGUI[3];
    private float startTime;

    /// <summary>
    /// 表示に使う部品を作る。最初に1回だけ呼ぶ。
    /// </summary>
    public void Init(SpriteRenderer sprite)
    {
        target = sprite;
        if (canvasObject != null) return;

        // 吹き出しと同じく、画面に重ねて描く Canvas を作る
        canvasObject = new GameObject("SleepZzzCanvas");
        canvas = canvasObject.AddComponent<Canvas>();
        canvas.renderMode = RenderMode.ScreenSpaceOverlay;
        canvas.sortingOrder = 50;

        var rootObject = new GameObject("Zzz", typeof(RectTransform));
        root = rootObject.GetComponent<RectTransform>();
        root.SetParent(canvasObject.transform, false);
        // 画面の左下を原点にして、WorldToScreenPoint の値をそのまま使う
        root.anchorMin = Vector2.zero;
        root.anchorMax = Vector2.zero;
        root.pivot = Vector2.zero;
        root.sizeDelta = Vector2.zero;

        for (int i = 0; i < letters.Length; i++)
        {
            var letterObject = new GameObject($"Z{i}", typeof(RectTransform));
            var rect = letterObject.GetComponent<RectTransform>();
            rect.SetParent(root, false);
            rect.anchorMin = Vector2.zero;
            rect.anchorMax = Vector2.zero;
            rect.pivot = Vector2.zero;
            rect.sizeDelta = new Vector2(fontSize, fontSize);

            // フォントを指定しなければ TextMesh Pro の既定のフォントが使われる
            var text = letterObject.AddComponent<TextMeshProUGUI>();
            text.text = "Z";
            text.fontSize = fontSize;
            text.fontStyle = FontStyles.Bold;
            text.alignment = TextAlignmentOptions.BottomLeft;
            text.raycastTarget = false;
            text.color = LetterColor;
            text.outlineWidth = 0.2f;
            text.outlineColor = OutlineColor;
            letters[i] = text;
        }

        canvasObject.SetActive(false);
    }

    public void SetVisible(bool visible)
    {
        if (canvasObject == null) return;
        if (visible && !canvasObject.activeSelf) startTime = Time.unscaledTime;
        canvasObject.SetActive(visible);
        if (visible) UpdateLetters();
    }

    private void LateUpdate()
    {
        if (canvasObject == null || !canvasObject.activeSelf) return;
        UpdateLetters();
    }

    private void UpdateLetters()
    {
        var cam = Camera.main;
        if (cam == null || target == null) return;

        // ライムの大きさに合わせて Z も縮める（Windows のトレイ「ライムの大きさ」）。
        // fontSize・rise は Canvas の単位なので、画面の画素で比べるときは倍率を掛ける
        float s = MascotScale.Ui;
        if (!Mathf.Approximately(canvas.scaleFactor, s)) canvas.scaleFactor = s;

        // 立ち絵の矩形から、頭の右上あたりを画面座標にする。
        // 立ち絵は左右に透明な余白があり、ライムは横の中央に立っている。
        Bounds b = target.bounds;
        var headRight = new Vector3(
            b.center.x + b.size.x * rightOfCenter,
            b.max.y - b.size.y * belowTop,
            b.center.z);
        Vector3 p = cam.WorldToScreenPoint(headRight);

        // ウィンドウの右端からはみ出すときは、頭の左上に出して左へ浮かべる
        float direction = 1f;
        if (p.x + (rise.x + fontSize * 1.5f) * s > Screen.width)
        {
            var headLeft = new Vector3(
                b.center.x - b.size.x * rightOfCenter,
                headRight.y,
                headRight.z);
            p = cam.WorldToScreenPoint(headLeft);
            p.x -= fontSize * s;
            direction = -1f;
        }
        // 上にはみ出す分は下げる
        p.y = Mathf.Min(p.y, Screen.height - (rise.y + fontSize * 1.5f) * s);

        // anchoredPosition は Canvas の単位なので、画素を倍率で割る
        root.anchoredPosition = new Vector2(p.x / s, p.y / s);

        float now = (Time.unscaledTime - startTime) / period;
        for (int i = 0; i < letters.Length; i++)
        {
            float t = Mathf.Repeat(now + i / (float)letters.Length, 1f);

            // 出始めと消え際をなめらかにする
            float alpha = t < 0.2f ? t / 0.2f : t > 0.7f ? (1f - t) / 0.3f : 1f;
            var color = letters[i].color;
            color.a = Mathf.Clamp01(alpha);
            letters[i].color = color;

            var rect = letters[i].rectTransform;
            rect.anchoredPosition = new Vector2(rise.x * t * direction, rise.y * t);
            float scale = 0.6f + 0.6f * t;
            rect.localScale = new Vector3(scale, scale, 1f);
        }
    }

    private void OnDestroy()
    {
        if (canvasObject != null) Destroy(canvasObject);
    }
}
