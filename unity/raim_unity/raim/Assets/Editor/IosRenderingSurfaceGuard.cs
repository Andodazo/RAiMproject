using System.IO;
using System.Text.RegularExpressions;
using UnityEditor;
using UnityEditor.Callbacks;
using UnityEngine;

/// <summary>
/// iOS に書き出したあと、Unity が出力する Xcode 用のコード（UnityView）を直す。
///
/// 【何が起きていたか】
/// Flutter に埋め込むと、Unity の画面はまず大きさ 0 の入れ物に付けられ、
/// Flutter が並べ終わってから本当の大きさになる。その間に Unity が
/// 画面の向きを合わせ直す（viewDidAppear → updateAppOrientation → didRotate）と、
/// 描画用の画像を幅 0・高さ 0 で作ろうとして、Metal に止められてアプリが落ちていた
/// （「MTLTextureDescriptor has width of zero」）。縦で起動したときに起きていた。
///
/// 【どう直すか】
/// 描画用の画像を作り直す処理（-[UnityView recreateRenderingSurface]）の先頭で、
/// 大きさが 0 のあいだは何もしないようにする。それまでの画像はそのまま使われ、
/// 大きさが付いたあとの描画で作り直される。
///
/// 書き出すたびに自動で直すので、手で Xcode のファイルを触る必要はない。
/// 何度書き出しても二重には入らない。
/// </summary>
public static class IosRenderingSurfaceGuard
{
    private const string Marker = "RAiM: zero-size guard";

    private static readonly Regex MethodStart = new Regex(
        @"(-\s*\(void\)\s*recreateRenderingSurface\s*\{)",
        RegexOptions.Compiled);

    private const string Guard =
        "\n    // " + Marker + "（Flutter に埋め込んだ直後は大きさ 0 のことがある。0 で作ると Metal が止める）\n" +
        "    if (self.bounds.size.width < 1 || self.bounds.size.height < 1) return;\n";

    [PostProcessBuild(1000)]
    public static void OnPostprocessBuild(BuildTarget target, string pathToBuiltProject)
    {
        if (target != BuildTarget.iOS) return;

        var classes = Path.Combine(pathToBuiltProject, "Classes");
        if (!Directory.Exists(classes))
        {
            Debug.LogWarning($"[RAiM] Classes フォルダが見つかりません: {classes}");
            return;
        }

        int patched = 0;
        foreach (var file in Directory.GetFiles(classes, "*.mm", SearchOption.AllDirectories))
        {
            var text = File.ReadAllText(file);
            if (text.Contains(Marker))
            {
                patched++;
                continue;
            }
            if (!MethodStart.IsMatch(text)) continue;

            text = MethodStart.Replace(text, "$1" + Guard, 1);
            File.WriteAllText(file, text);
            patched++;
            Debug.Log($"[RAiM] 大きさ 0 のときに描画用の画像を作らないようにしました: {file}");
        }

        if (patched == 0)
        {
            Debug.LogWarning(
                "[RAiM] recreateRenderingSurface が見つからず、大きさ 0 の対策を入れられませんでした。" +
                "Unity の版が変わった可能性があります。iOS で縦に起動して落ちないか確認してください。");
        }
    }
}
