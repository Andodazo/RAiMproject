using System;
using System.Collections.Generic;
using UnityEngine;
using NativeWebSocket;

public class RAiMCharacterController : MonoBehaviour
{
    // ============================================================
    // Inspector設定
    // ============================================================

    [Header("WebSocket設定（Windows版のみ使用）")]
    [SerializeField] private string serverUrl = "ws://localhost:8765";
    [SerializeField] private bool useWebSocket = true;

    [Tooltip("接続に失敗したとき再試行する間隔(秒)。0で再接続しない")]
    [SerializeField] private float reconnectInterval = 3f;

    [Header("吹き出し（Windows版のみ）")]
    [Tooltip("SpeechBubbleController。WindowsOverlay の子に置く。未設定でも動作する")]
    [SerializeField] private SpeechBubbleController speechBubble;

    [Header("表情スプライト")]
    [SerializeField] private Sprite defaultSprite;
    [SerializeField] private Sprite happySprite;
    [SerializeField] private Sprite sadSprite;
    [SerializeField] private Sprite surprisedSprite;
    [SerializeField] private Sprite angrySprite;
    [SerializeField] private Sprite amusedSprite;
    [SerializeField] private Sprite caringSprite;

    // 既存のInspector設定を維持するため、
    // フィールド名はcariousSpriteのままにしています。
    [SerializeField] private Sprite cariousSprite;

    [SerializeField] private Sprite embarrassedSprite;
    [SerializeField] private Sprite excitedSprite;
    [SerializeField] private Sprite playfulSprite;
    [SerializeField] private Sprite thoughtfulSprite;
    [SerializeField] private Sprite investigateSprite;

    // ============================================================
    // 内部状態
    // ============================================================

    // Tool使用中かどうか
    private bool isUsingTool = false;

    // 現在の感情
    private string currentEmotion = "neutral";

    // Tool開始前の感情
    private string emotionBeforeTool = "neutral";

    private SpriteRenderer spriteRenderer;
    private WebSocket websocket;
    private Dictionary<string, Sprite> emotionMap;

    // 再接続用
    private bool isConnecting = false;
    private float reconnectTimer = 0f;
    private bool quitting = false;

    // ============================================================
    // 起動時処理
    // ============================================================

    async void Start()
    {
        // SpriteRendererを取得
        spriteRenderer = GetComponent<SpriteRenderer>();

        if (spriteRenderer == null)
        {
            Debug.LogError("SpriteRendererが見つかりません。");
            return;
        }

        // 感情とSpriteの対応表を作成
        emotionMap = new Dictionary<string, Sprite>
        {
            { "happy", happySprite },
            { "sad", sadSprite },
            { "angry", angrySprite },
            { "surprised", surprisedSprite },
            { "neutral", defaultSprite },
            { "amused", amusedSprite },
            { "caring", caringSprite },

            // サーバーから届く名前はcurious
            // Inspectorのフィールド名は既存のcariousSpriteを使用
            { "curious", cariousSprite },

            { "embarrassed", embarrassedSprite },
            { "excited", excitedSprite },
            { "playful", playfulSprite },
            { "thoughtful", thoughtfulSprite },
        };

        // 初期表情
        spriteRenderer.sprite = defaultSprite;
        currentEmotion = "neutral";

        // ========================================================
        // プラットフォームごとの通信設定
        // ========================================================

#if UNITY_EDITOR
        // Unity EditorでWindows版Flutterと接続する場合
        useWebSocket = true;
        Debug.Log("Unity Editor: WebSocket有効");

#elif UNITY_ANDROID || UNITY_IOS
        // Android/iOSはflutter_embed_unity経由
        useWebSocket = false;
        Debug.Log("モバイル版: WebSocket無効、flutter_embed_unity経由で受信");

#elif UNITY_STANDALONE_WIN
        // Windows版UnityはWebSocket経由
        useWebSocket = true;
        Debug.Log("Windows版: WebSocket有効");
#endif

        // WindowsまたはUnity EditorではWebSocket接続
        if (useWebSocket)
        {
            await ConnectWebSocket();
        }
    }

    // ============================================================
    // Android/iOS用
    // flutter_embed_unityから呼ばれるメソッド
    // ============================================================

    /// <summary>
    /// 単一感情を受信する
    /// 例：happy
    /// </summary>
    public void ReceiveEmotion(string emotion)
    {
        Debug.Log($"[Unity] 単一感情受信: {emotion}");

        if (string.IsNullOrEmpty(emotion))
        {
            Debug.LogWarning("感情が空です。");
            return;
        }

        ChangeEmotion(emotion);
    }

    /// <summary>
    /// 複数感情JSONを受信する
    /// 例：
    /// {
    ///   "emotions": {
    ///     "caring": 0.667,
    ///     "surprised": 0.333
    ///   },
    ///   "overall_intensity": 1
    /// }
    /// </summary>
    public void ReceiveEmotions(string json)
    {
        Debug.Log($"[Unity] 複数感情受信: {json}");

        try
        {
            var data = JsonUtility.FromJson<EmotionsMessage>(json);

            if (data == null || data.emotions == null)
            {
                Debug.LogWarning("複数感情データが空です。");
                return;
            }

            // 最も強い感情を選択
            string mainEmotion = GetDominantEmotion(data.emotions);

            Debug.Log($"[Unity] 最終感情: {mainEmotion}");

            // 通常の表情に切り替える
            ChangeEmotion(mainEmotion);
        }
        catch (Exception e)
        {
            Debug.LogError($"複数感情JSONエラー: {e.Message}");
        }
    }

    /// <summary>
    /// Tool使用状態を受信する
    /// </summary>
    public void ReceiveToolState(string json)
    {
        Debug.Log($"[Unity] Tool状態受信: {json}");

        try
        {
            var data = JsonUtility.FromJson<ToolStateMessage>(json);

            if (data == null)
            {
                Debug.LogWarning("Tool状態データが空です。");
                return;
            }

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

    /// <summary>
    /// JSON全体を受信する場合の互換処理
    /// </summary>
    public void ReceiveMessage(string json)
    {
        Debug.Log($"[Unity] JSON受信: {json}");

        try
        {
            var typeData = JsonUtility.FromJson<MessageType>(json);

            if (typeData != null && typeData.type == "tool_state")
            {
                ReceiveToolState(json);
                return;
            }

            if (typeData != null && typeData.type == "emotions")
            {
                ReceiveEmotions(json);
                return;
            }

            var emotionData = JsonUtility.FromJson<EmotionMessage>(json);

            if (emotionData != null &&
                !string.IsNullOrEmpty(emotionData.emotion))
            {
                ChangeEmotion(emotionData.emotion);
            }
        }
        catch (Exception e)
        {
            Debug.LogError($"JSONパースエラー: {e.Message}");
        }
    }

    // ============================================================
    // 吹き出し（Windows版のみ）
    // ============================================================
    // モバイルではチャットUIをFlutterが描くため、speechBubble は
    // WindowsOverlay の子（=モバイルでは無効）に置いてある。
    // 無効なら何もしないので、プラットフォーム分岐は不要。

    private bool BubbleAvailable =>
        speechBubble != null && speechBubble.isActiveAndEnabled;

    /// <summary>
    /// text_chunk を受け取り、吹き出しに追記する。
    /// </summary>
    public void ReceiveTextChunk(string json)
    {
        if (!BubbleAvailable) return;

        try
        {
            var data = JsonUtility.FromJson<TextChunkMessage>(json);
            if (data == null || string.IsNullOrEmpty(data.text)) return;

            // is_filler は v14 以降サーバー側で実質使われていないが、
            // 届いても本文と同じ扱いで問題ない。
            speechBubble.AppendText(data.text);
        }
        catch (Exception e)
        {
            Debug.LogError($"text_chunk JSONエラー: {e.Message}");
        }
    }

    /// <summary>
    /// bubble_break。次の text_chunk から新しい吹き出しにする。
    /// </summary>
    public void ReceiveBubbleBreak()
    {
        if (!BubbleAvailable) return;
        speechBubble.BreakBubble();
    }

    /// <summary>
    /// chat_end。消去タイマーを開始する。
    /// </summary>
    public void ReceiveChatEnd(string json)
    {
        if (!BubbleAvailable) return;

        try
        {
            var data = JsonUtility.FromJson<ChatEndMessage>(json);
            speechBubble.EndSpeech(data != null ? data.full_text : null);
        }
        catch (Exception e)
        {
            Debug.LogError($"chat_end JSONエラー: {e.Message}");
            speechBubble.EndSpeech();
        }
    }

    // ============================================================
    // Flutter からの終了指示
    // ============================================================

    /// <summary>
    /// Flutter のメニューで「終了」が押されたときに呼ばれる。
    ///
    /// Flutter が Unity を起動した場合はプロセスを kill されるが、
    /// Unity Editor や手動起動の場合は kill が効かないため、
    /// メッセージを受けて自分で終了する。
    /// ウィンドウ位置の保存は OnApplicationQuit が担当する。
    /// </summary>
    private void QuitFromFlutter()
    {
#if UNITY_EDITOR
        UnityEditor.EditorApplication.isPlaying = false;
#else
        Application.Quit();
#endif
    }

    // ============================================================
    // Flutter への送信（Windows版のみ）
    // ============================================================

    /// <summary>
    /// Flutter へ JSON を送る。WindowsOverlayController から呼ばれ、
    /// ライムのクリックやウィンドウ移動を通知するのに使う。
    ///
    /// WebSocket をこのクラスが持っているため、送信口もここに置く。
    /// 未接続のときは黙って捨てる（通知は失っても支障がないため）。
    /// </summary>
    public async void SendToFlutter(string json)
    {
        if (websocket == null || websocket.State != WebSocketState.Open) return;

        try
        {
            await websocket.SendText(json);
        }
        catch (Exception e)
        {
            Debug.LogError($"Flutter への送信に失敗: {e.Message}");
        }
    }

    // ============================================================
    // Windows用WebSocket接続
    // ============================================================

    private async System.Threading.Tasks.Task ConnectWebSocket()
    {
        isConnecting = true;
        websocket = new WebSocket(serverUrl);

        websocket.OnOpen += () =>
        {
            isConnecting = false;
            Debug.Log("WebSocket接続成功");
        };

        websocket.OnError += (errorMessage) =>
        {
            isConnecting = false;
            Debug.LogError($"WebSocketエラー: {errorMessage}");
        };

        websocket.OnClose += (closeCode) =>
        {
            isConnecting = false;
            Debug.Log($"WebSocket切断: {closeCode}");
        };

        websocket.OnMessage += (bytes) =>
        {
            string message =
                System.Text.Encoding.UTF8.GetString(bytes);

            Debug.Log($"WebSocket受信: {message}");

            HandleWebSocketMessage(message);
        };

        try
        {
            await websocket.Connect();
        }
        catch (Exception e)
        {
            isConnecting = false;
            Debug.LogError($"WebSocket接続失敗: {e.Message}");
        }
    }

    /// <summary>
    /// Windows版でWebSocketから受信したJSONを処理する
    /// </summary>
    private void HandleWebSocketMessage(string json)
    {
        try
        {
            var typeData = JsonUtility.FromJson<MessageType>(json);

            // Tool状態
            if (typeData != null &&
                typeData.type == "tool_state")
            {
                ReceiveToolState(json);
                return;
            }

            // 複数感情
            if (typeData != null &&
                typeData.type == "emotions")
            {
                ReceiveEmotions(json);
                return;
            }

            // 吹き出し系（Windows版のみ）
            if (typeData != null && typeData.type == "text_chunk")
            {
                ReceiveTextChunk(json);
                return;
            }

            if (typeData != null && typeData.type == "bubble_break")
            {
                ReceiveBubbleBreak();
                return;
            }

            if (typeData != null && typeData.type == "chat_end")
            {
                ReceiveChatEnd(json);
                return;
            }

            // Flutter 側のメニューから終了された
            if (typeData != null && typeData.type == "app.quit")
            {
                Debug.Log("Flutter から終了を指示されました");
                QuitFromFlutter();
                return;
            }

            // 単一感情
            var emotionData = JsonUtility.FromJson<EmotionMessage>(json);

            if (emotionData != null &&
                !string.IsNullOrEmpty(emotionData.emotion))
            {
                ChangeEmotion(emotionData.emotion);
            }
        }
        catch (Exception e)
        {
            Debug.LogError($"WebSocket JSONエラー: {e.Message}");
        }
    }

    // ============================================================
    // Tool状態による表情変更
    // ============================================================

    private void SetToolState(bool value)
    {
        if (spriteRenderer == null)
        {
            Debug.LogWarning("SpriteRendererが初期化されていません。");
            return;
        }

        if (value)
        {
            // すでにTool使用中なら処理しない
            if (isUsingTool)
            {
                return;
            }

            // Tool開始前の感情を保存
            emotionBeforeTool = currentEmotion;
            isUsingTool = true;

            // 調査中画像に変更
            if (investigateSprite != null)
            {
                spriteRenderer.sprite = investigateSprite;
                Debug.Log("調査中Spriteに変更しました。");
            }
            else
            {
                Debug.LogWarning(
                    "investigateSpriteが設定されていません。"
                );
            }
        }
        else
        {
            // Toolを使用していない場合は処理しない
            if (!isUsingTool)
            {
                return;
            }

            isUsingTool = false;

            // 一度、Tool開始前の表情に戻す
            // その後、ReceiveEmotionsで最終感情に変更される
            ChangeEmotion(emotionBeforeTool);

            Debug.Log("Tool終了。通常のSpriteに戻しました。");
        }
    }

    // ============================================================
    // 感情によるSprite変更
    // ============================================================

    private void ChangeEmotion(string emotion)
    {
        if (spriteRenderer == null)
        {
            Debug.LogWarning("SpriteRendererが初期化されていません。");
            return;
        }

        if (emotionMap == null)
        {
            Debug.LogWarning("emotionMapが初期化されていません。");
            return;
        }

        // Tool使用中は通常感情で上書きしない
        if (isUsingTool)
        {
            Debug.Log(
                $"Tool使用中のため感情変更を保留: {emotion}"
            );
            return;
        }

        if (string.IsNullOrEmpty(emotion))
        {
            Debug.LogWarning("感情名が空です。");
            return;
        }

        currentEmotion = emotion;

        if (emotionMap.TryGetValue(
                emotion,
                out Sprite sprite
            ) && sprite != null)
        {
            spriteRenderer.sprite = sprite;
            Debug.Log($"表情変更: {emotion}");
        }
        else
        {
            spriteRenderer.sprite = defaultSprite;

            Debug.LogWarning(
                $"未知の感情: {emotion} → defaultに変更"
            );
        }
    }

    // ============================================================
    // 複数感情から最も強い感情を取得
    // ============================================================

    private string GetDominantEmotion(EmotionScores emotions)
    {
        var values = new Dictionary<string, float>
        {
            { "happy", emotions.happy },
            { "sad", emotions.sad },
            { "angry", emotions.angry },
            { "surprised", emotions.surprised },
            { "neutral", emotions.neutral },
            { "amused", emotions.amused },
            { "caring", emotions.caring },
            { "curious", emotions.curious },
            { "embarrassed", emotions.embarrassed },
            { "excited", emotions.excited },
            { "playful", emotions.playful },
            { "thoughtful", emotions.thoughtful },
        };

        string result = "neutral";
        float maxValue = 0f;

        foreach (var pair in values)
        {
            if (pair.Value > maxValue)
            {
                maxValue = pair.Value;
                result = pair.Key;
            }
        }

        return result;
    }

    // ============================================================
    // 毎フレーム処理
    // ============================================================

    private void Update()
    {
#if !UNITY_WEBGL || UNITY_EDITOR
        if (!useWebSocket) return;

        if (websocket != null)
        {
            websocket.DispatchMessageQueue();
        }

        TryReconnect();
#endif
    }

    // ============================================================
    // 再接続
    // ============================================================
    // Unity を Flutter より先に起動した場合、Start() の1回きりでは
    // 永久に繋がらないため、閉じている間は一定間隔で再試行する。

    private void TryReconnect()
    {
        if (quitting) return;
        if (reconnectInterval <= 0f) return;
        if (isConnecting) return;

        bool needsConnect =
            websocket == null ||
            websocket.State == WebSocketState.Closed;

        if (!needsConnect)
        {
            reconnectTimer = 0f;
            return;
        }

        reconnectTimer -= Time.deltaTime;
        if (reconnectTimer > 0f) return;

        reconnectTimer = reconnectInterval;
        Debug.Log("WebSocket再接続を試みます");
        _ = ConnectWebSocket();
    }

    // ============================================================
    // 終了処理
    // ============================================================

    private async void OnApplicationQuit()
    {
        quitting = true;

        if (websocket != null)
        {
            await websocket.Close();
        }
    }
}

// ================================================================
// JSONデータクラス
// ================================================================

[Serializable]
public class EmotionMessage
{
    public string type;
    public string text;
    public string emotion;
    public float intensity;
}

[Serializable]
public class MessageType
{
    public string type;
}

[Serializable]
public class TextChunkMessage
{
    public string type;
    public string text;
    public bool is_filler;
    public bool is_final;
}

[Serializable]
public class ChatEndMessage
{
    public string type;
    public string full_text;
}

[Serializable]
public class ToolStateMessage
{
    public string type;
    public bool is_using_tool;
    public string description;
}

[Serializable]
public class EmotionsMessage
{
    public string type;
    public EmotionScores emotions;
    public float overall_intensity;
}

[Serializable]
public class EmotionScores
{
    public float happy;
    public float sad;
    public float angry;
    public float surprised;
    public float neutral;
    public float amused;
    public float caring;
    public float curious;
    public float embarrassed;
    public float excited;
    public float playful;
    public float thoughtful;
}