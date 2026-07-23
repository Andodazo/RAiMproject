using System.Collections.Generic;
using UnityEngine;
using NativeWebSocket;
using System;

public class RAiMCharacterController: MonoBehaviour
{
    // ========================================
    // Inspector から設定するフィールド
    // ========================================
    
    [Header("WebSocket設定（Windows版のみ使用）")]
    [SerializeField] private string serverUrl = "ws://localhost:8765";
    [SerializeField] private bool useWebSocket = true;  // Windows ビルド時のみ true
    
    [Header("表情スプライト")]
    [SerializeField] private Sprite defaultSprite;
    [SerializeField] private Sprite happySprite;
    [SerializeField] private Sprite sadSprite;
    [SerializeField] private Sprite surprisedSprite;
    [SerializeField] private Sprite angrySprite;
    [SerializeField] private Sprite amusedSprite;
    [SerializeField] private Sprite caringSprite;
    [SerializeField] private Sprite cariousSprite;
    [SerializeField] private Sprite embarrassedSprite;
    [SerializeField] private Sprite excitedSprite;
    [SerializeField] private Sprite playfulSprite;
    [SerializeField] private Sprite thoughtfulSprite;
    [SerializeField] private Sprite investigateSprite;

    // 追加：Tool使用中かどうかを管理する
    private bool isUsingTool = false;

    // 追加：現在の感情
    private string currentEmotion = "neutral";

    // 追加：Tool開始前の感情
    private string emotionBeforeTool = "neutral";

    // ========================================
    // 内部状態
    // ========================================

    private SpriteRenderer spriteRenderer;
    private WebSocket websocket;
    private Dictionary<string, Sprite> emotionMap;
    
    // ========================================
    // 起動時処理
    // ========================================
    
    async void Start()
    {
        // SpriteRenderer 取得
        spriteRenderer = GetComponent<SpriteRenderer>();
        if (spriteRenderer == null)
        {
            Debug.LogError("SpriteRenderer が見つかりません！");
            return;
        }
        
        // emotion → Sprite のマッピング作成
        emotionMap = new Dictionary<string, Sprite>
        {
            { "happy", happySprite },
            { "sad", sadSprite },
            { "angry", angrySprite },
            { "surprised", surprisedSprite },
            { "neutral", defaultSprite },
            { "amused", amusedSprite},
            { "caring", caringSprite},
            { "carious", cariousSprite},
            { "embarrassed", embarrassedSprite},
            { "excited", excitedSprite},
            { "playful", playfulSprite},
            { "thoughtful", thoughtfulSprite},
        };
        
        // 初期表情を default に
        spriteRenderer.sprite = defaultSprite;

        // モバイルプラットフォームの場合はWebSocket無効化
        // プラットフォームごとの通信設定
        #if UNITY_EDITOR
            // Unity EditorでWindows版Flutterと接続する場合
            useWebSocket = true;
            Debug.Log("Unity Editor: WebSocket有効");
        #elif UNITY_ANDROID || UNITY_IOS
            // Android/iOSはflutter_embed_unity経由
            useWebSocket = false;
            Debug.Log("モバイル版: WebSocket無効、flutter_embed_unity経由で受信");
        #elif UNITY_STANDALONE_WIN
            // Windows版はWebSocket経由
            useWebSocket = true;
            Debug.Log("Windows版: WebSocket有効");
        #endif

        // WebSocket接続
        if (useWebSocket)
        {
            await ConnectWebSocket();
        }
    }
    
    // ========================================
    // ★ Flutter (flutter_embed_unity) から呼ばれるメソッド
    // ========================================
    
    /// <summary>
    /// Flutter 側から sendToUnity("character", "ReceiveEmotion", "happy") で呼ばれる
    /// </summary>
    public void ReceiveEmotion(string emotion)
    {
        Debug.Log($"Flutter から受信: emotion={emotion}");
        ChangeEmotion(emotion);
    }
    
    /// <summary>
    /// Flutter 側から JSON 全体を渡す場合用
    /// JSON 例: {"text":"...","emotion":"happy","intensity":0.8}
    /// </summary>
    public void ReceiveMessage(string json)
    {
        Debug.Log($"Flutter から受信: {json}");
        try
        {
            // メッセージの種類を確認する
            var typeData = JsonUtility.FromJson<MessageType>(json);
            // 追加：Tool状態メッセージの場合
            if (typeData != null && typeData.type == "tool_state")
            {
                ReceiveToolState(json);
                return;
            }
            // 通常の感情メッセージ
            var emotionData =
            JsonUtility.FromJson<EmotionMessage>(json);
            if (!string.IsNullOrEmpty(emotionData.emotion))
            {
                ChangeEmotion(emotionData.emotion);
            }
        }
        catch (Exception e)
        {
            Debug.LogError($"JSON パースエラー: {e.Message}");
        }
    }
    // FlutterからTool状態を受け取る
    public void ReceiveToolState(string json)
    {
        Debug.Log($"[Unity] Tool状態受信: {json}");

        try
        {
            var data =
                JsonUtility.FromJson<ToolStateMessage>(json);

            Debug.Log(
                $"[Unity] is_using_tool={data.is_using_tool}, " +
                $"investigateSprite={investigateSprite}"
            );

            SetToolState(data.is_using_tool);
        }
        catch (Exception e)
        {
            Debug.LogError($"Tool状態JSONエラー: {e.Message}");
        }
    }

    // ========================================
    // WebSocket 接続（Windows版のみ）
    // ========================================

    async System.Threading.Tasks.Task ConnectWebSocket()
    {
        websocket = new WebSocket(serverUrl);
        
        websocket.OnOpen += () =>
        {
            Debug.Log("WebSocket 接続成功");
        };
        
        websocket.OnError += (e) =>
        {
            Debug.LogError($"WebSocket エラー: {e}");
        };
        
        websocket.OnClose += (e) =>
        {
            Debug.Log($"WebSocket 切断: {e}");
        };
        
        websocket.OnMessage += (bytes) =>
        {
            string message = System.Text.Encoding.UTF8.GetString(bytes);
            Debug.Log($"WebSocket 受信: {message}");
            HandleWebSocketMessage(message);
        };
        
        await websocket.Connect();
    }

    void HandleWebSocketMessage(string json)
    {
        try
        {
            var typeData =
                JsonUtility.FromJson<MessageType>(json);

            // Tool状態メッセージの場合
            if (typeData != null &&
                typeData.type == "tool_state")
            {
                ReceiveToolState(json);
                return;
            }

            // 感情メッセージの場合
            var emotionData =
                JsonUtility.FromJson<EmotionMessage>(json);

            if (!string.IsNullOrEmpty(emotionData.emotion))
            {
                ChangeEmotion(emotionData.emotion);
            }
        }
        catch (Exception e)
        {
            Debug.LogError($"WebSocket JSONエラー: {e.Message}");
        }
    }

// 追加：Tool使用中はinvestigateSpriteを表示する
private void SetToolState(bool value)
{
    if (spriteRenderer == null)
    {
        Debug.LogWarning("SpriteRendererがまだ初期化されていません");
        return;
    }

    if (value)
    {
        // すでにTool使用中なら何もしない
        if (isUsingTool)
        {
            return;
        }

        // Tool開始前の感情を保存する
        emotionBeforeTool = currentEmotion;
        isUsingTool = true;

        // 調査中はinvestigateSpriteを表示する
        if (investigateSprite != null)
        {
            spriteRenderer.sprite = investigateSprite;
            Debug.Log("調査中Spriteに変更しました");
        }
        else
        {
            Debug.LogWarning("investigateSpriteが設定されていません");
        }
    }
    else
    {
        // Toolを使用していない場合は何もしない
        if (!isUsingTool)
        {
            return;
        }

        isUsingTool = false;

        // Tool終了後、開始前の感情に戻す
        ChangeEmotion(emotionBeforeTool);

        Debug.Log("Tool終了。通常のSpriteに戻しました");
    }
}

// ========================================
// 共通：emotion で Sprite 切り替え
// ========================================

void ChangeEmotion(string emotion)
    {
            // Tool使用中は感情Spriteで上書きしない
            if (isUsingTool)
            {
                return;
            }

            currentEmotion = emotion;

    if (emotionMap.TryGetValue(emotion, out Sprite sprite)
        && sprite != null)
    {
        spriteRenderer.sprite = sprite;
        Debug.Log($"表情変更: {emotion}");
    }
    else
        {
            spriteRenderer.sprite = defaultSprite;
            Debug.LogWarning($"未知の感情: {emotion} → default にフォールバック");
        }
    }
    
    // ========================================
    // 毎フレーム処理（WebSocket メッセージ受信のため、Windows版のみ必要）
    // ========================================
    
    void Update()
    {
#if !UNITY_WEBGL || UNITY_EDITOR
        if (useWebSocket && websocket != null)
        {
            websocket.DispatchMessageQueue();
        }
#endif
    }
    
    // ========================================
    // 終了処理
    // ========================================
    
    async void OnApplicationQuit()
    {
        if (websocket != null)
        {
            await websocket.Close();
        }
    }
}

// ========================================
// 受信 JSON の構造
// ========================================

[Serializable]
public class EmotionMessage
{
    public string type;
    public string text;
    public string emotion;
    public float intensity;
}

// 追加：メッセージ種類確認用
[Serializable]
public class MessageType
{
    public string type;
}

// 追加：Tool状態受信用
[Serializable]
public class ToolStateMessage
{
    public string type;
    public bool is_using_tool;
    public string description;
}