using System.Collections.Generic;
using UnityEngine;
using NativeWebSocket;
using System;

public class RAiMCharacterController : MonoBehaviour
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
    [SerializeField] private Sprite angrySprite;
    [SerializeField] private Sprite surprisedSprite;
    
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
            { "caring", defaultSprite },
        };
        
        // 初期表情を default に
        spriteRenderer.sprite = defaultSprite;
        
        // モバイルプラットフォームの場合はWebSocket無効化
#if UNITY_ANDROID || UNITY_IOS
        useWebSocket = false;
        Debug.Log("モバイルプラットフォーム検出: WebSocket無効、flutter_embed_unity 経由で受信");
#endif
        
        // Windows版の場合はWebSocket接続
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
            var data = JsonUtility.FromJson<EmotionMessage>(json);
            ChangeEmotion(data.emotion);
        }
        catch (Exception e)
        {
            Debug.LogError($"JSON パースエラー: {e.Message}");
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
            var data = JsonUtility.FromJson<EmotionMessage>(json);
            ChangeEmotion(data.emotion);
        }
        catch (Exception e)
        {
            Debug.LogError($"WebSocket JSON パースエラー: {e.Message}");
        }
    }
    
    // ========================================
    // 共通：emotion で Sprite 切り替え
    // ========================================
    
    void ChangeEmotion(string emotion)
    {
        if (emotionMap.TryGetValue(emotion, out Sprite sprite) && sprite != null)
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