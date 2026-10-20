using UnityEngine;

/// <summary>
/// Windows のデスクトップマスコット（ライム）の大きさ。
///
/// Flutter のタスクトレイの「ライムの大きさ」で選ばれた値を、
/// WindowsOverlayController が受け取ってここに入れる。
/// 吹き出し（SpeechBubbleController）と「Zzz」（SleepZzzEffect）はこれを見て文字の大きさを合わせる。
///
/// スマホでは使わないので 1 のまま。
/// </summary>
public static class MascotScale
{
    /// <summary>窓の大きさの倍率。1 で元の大きさ（800×700）。</summary>
    public static float Window { get; private set; } = 1f;

    /// <summary>
    /// 展示モードなどで全画面に出している間 true。
    /// そのときは窓の大きさを変えないので、吹き出しなども元の大きさにする。
    /// </summary>
    public static bool FullScreen { get; set; }

    /// <summary>
    /// ライムの見た目の倍率。吹き出しをライムからどれだけ離すか など、
    /// ライムとの位置関係に使う。
    /// </summary>
    public static float Character => FullScreen ? 1f : Window;

    /// <summary>
    /// 吹き出しや「Zzz」の文字の倍率。
    ///
    /// 窓と同じだけ縮めると、小（60%）で文字が11px ほどになって読めない。
    /// 縮め方を半分にする（小 80%・中 90%・大 100%）。
    /// </summary>
    public static float Ui => FullScreen ? 1f : (1f + Window) * 0.5f;

    /// <summary>選べる範囲。Flutter から変な値が来ても窓が消えたり巨大にならないように。</summary>
    public const float Min = 0.4f;
    public const float Max = 1.5f;

    public static void Set(float window)
    {
        Window = Mathf.Clamp(window, Min, Max);
    }
}
