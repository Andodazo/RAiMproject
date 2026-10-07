using UnityEngine;

public class CharacterAspectScaler : MonoBehaviour
{
    [Header("基準となる画面サイズ")]
    [SerializeField] private float referenceWidth = 1080f;  // 開発基準の横幅
    [SerializeField] private float referenceHeight = 1920f; // 開発基準の縦幅

    [Header("現在の基準位置・スケール")]
    [SerializeField] private Vector3 basePosition = new Vector3(0f, -1.43f, 0f);
    [SerializeField] private Vector3 baseScale = new Vector3(1.01f, 1.01f, 1.01f);

    private void Awake()
    {
        ApplyResponsiveScale();
    }

    /// <summary>
    /// 画面の縦横比に合わせてサイズと位置を自動計算
    /// </summary>
    public void ApplyResponsiveScale()
    {
        float targetAspect = referenceWidth / referenceHeight;
        float currentAspect = (float)Screen.width / Screen.height;

        // 基準（9:16など）より縦長な端末（iPhone等）の場合
        if (currentAspect < targetAspect)
        {
            // 画面横幅の縮小率を算出
            float scaleFactor = currentAspect / targetAspect;

            // スケールを画面に合わせて補正
            transform.localScale = new Vector3(
                baseScale.x * scaleFactor,
                baseScale.y * scaleFactor,
                baseScale.z
            );

            // 足元の位置感が変わらないよう Pos Y も補正
            transform.localPosition = new Vector3(
                basePosition.x,
                basePosition.y * scaleFactor,
                basePosition.z
            );
        }
        else
        {
            // 基準以上の幅がある場合は現在の設定値をそのまま使用
            transform.localScale = baseScale;
            transform.localPosition = basePosition;
        }
    }
}