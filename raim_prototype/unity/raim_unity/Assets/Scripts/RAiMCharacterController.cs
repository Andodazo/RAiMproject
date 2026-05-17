using System.Collections.Generic;
using UnityEngine;
using NativeWebSocket;
using System;

public class RAiMCharacterController : MonoBehaviour
{
    // ========================================
    // Inspector から設定するフィールド
    // ========================================
    
    [Header("WebSocket設定")]
    [SerializeField] private string serverUrl = "ws://localhost:8765";
    
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
            { "caring", defaultSprite },  // caring は default にフォールバック
        };
        
        // 初期表情を default に
        spriteRenderer.sprite = defaultSprite;
        
        // WebSocket 接続開始
        await ConnectWebSocket();
    }
    
    // ========================================
    // WebSocket 接続
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
            Debug.Log($"受信: {message}");
            HandleMessage(message);
        };
        
        await websocket.Connect();
    }
    
    // ========================================
    // 受信メッセージ処理
    // ========================================
    
    void HandleMessage(string json)
    {
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
    
    void ChangeEmotion(string emotion)
    {
        if (emotionMap.TryGetValue(emotion, out Sprite sprite) && sprite != null)
        {
            spriteRenderer.sprite = sprite;
            Debug.Log($"表情変更: {emotion}");
        }
        else
        {
            // 未知の感情は default にフォールバック
            spriteRenderer.sprite = defaultSprite;
            Debug.LogWarning($"未知の感情: {emotion} → default にフォールバック");
        }
    }
    
    // ========================================
    // 毎フレーム処理（WebSocket メッセージ受信のため必要）
    // ========================================
    
    void Update()
    {
#if !UNITY_WEBGL || UNITY_EDITOR
        websocket?.DispatchMessageQueue();
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