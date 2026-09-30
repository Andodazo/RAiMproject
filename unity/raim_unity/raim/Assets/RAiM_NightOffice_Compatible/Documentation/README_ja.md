# RAiM 夜景オフィス v4 — 既存カメラ・Windows透過対応

この版は、既存の Main Camera と `character` を残して部屋を追加する構成です。Windowsの透過表示では部屋を表示しません。元のMain Cameraを削除する必要はありません。

## 導入

1. `RAiM_NightOffice_WindowsCompatible.unitypackage` をインポートします。追加先は `Assets/RAiM_NightOffice_Compatible` です。旧版と異なるGUIDを使っています。
2. 対象Sceneの作業コピーに `Prefabs/RAiM_NightOffice_Compatible.prefab` を置きます。Transformは位置0・回転0・スケール1を基本とします。
3. Prefab最上位の `Night Office Presentation` の **Main Camera** に既存のカメラを、**Character** に既存の `character` のSpriteRendererを割り当てます。既存のカメラ・AudioListener・characterを削除したり、部屋の子に移したりしないでください。
4. **Hide While Room Visible** に、部屋を表示する間だけ隠す元の背景などを指定します。元の背景オブジェクトを登録すると、部屋表示時に重ならず、透過モードへ戻すと直前の状態へ復元されます。WindowsOverlay、UI、カメラ、characterは登録しません。
5. **Mode = Automatic** のまま使います。WindowsOverlayControllerとUniWindowController、既存のPC用Render Pipeline設定はそのまま使います。新しいパイプラインへの交換は不要です。

旧v3の `RAiM_NightOffice_Stage3D` が同じSceneにある場合、そのインスタンスと内蔵カメラを併用しないでください。Sceneのコピーで旧インスタンスを外し、元のMain Cameraとcharacterを元の2D状態から使ってください。v4は「部屋表示直前の設定」を保存するため、すでにv3用へ変更済みの座標から本来の2D設定を推測して戻す機能はありません。元Sceneは自動変更しません。

## 表示モード

| Mode | 部屋・照明・Volume | 既存カメラ・character |
|---|---|---|
| Automatic / Windows向け | 非表示 | 起動時の設定に触れない |
| Automatic / Android・iOS等の他の対象 | 表示 | 室内用の視点・立ち位置へ一時的に変更 |
| Desktop Overlay | 非表示 | 直前に部屋表示していれば保存状態へ戻す |
| Room | 表示 | 室内用の視点・立ち位置へ一時的に変更 |

Windows向けのEditor再生もAutomaticでは透過側です。これはRAiMの既存WindowsOverlayControllerのコンパイル条件に合わせています。Editorで部屋を見るときは、同梱の `Scenes/NightOffice_RoomPreview.unity` を開いてください。この専用SceneはRoomモードで、確認用カメラがPrefabの外にあります。既存Scene上でRoomを強制する場合、Windowsの透過制御と同時にカメラを操作させない検証環境が必要です。本版は既存のWindows制御を勝手に無効化しません。

## 構成

```
既存Scene
├─ Main Camera             ← 既存の1台・AudioListenerを維持
├─ character               ← 既存SpriteRenderer・表情受信処理を維持
├─ WindowsOverlay          ← 従来どおり
└─ RAiM_NightOffice_Compatible
   ├─ NightOfficePresentation
   └─ RoomContent          ← 保存状態では非アクティブ
      ├─ 室内・家具・小物・夜景
      ├─ ライト・Reflection Probe・Volume
      ├─ RoomBakedLighting
      └─ AvatarAnchor
```

Prefab内にCamera、AudioListener、EventSystemはありません。表示に常設のRenderTextureや追加カメラを使いません。モード切替用の新規コンポーネントは部屋側にのみ追加しています。

部屋表示では既存カメラを位置 `(4.10, 1.40, 0.25)`、注視点 `(2.75, 1.15, 2.95)`、垂直FOV 54度に設定します。Unity座標でYが上です。`character` は `(2.80, 0, 2.75)` のAnchorへ置き、表情ごとの透明余白を考慮して可視身長1.65mにそろえます。画像・マテリアル・オブジェクト名・表情受信処理は変更しません。身振り・影・立体感は2Dスプライトのままです。既存13種類以外の画像は透明余白プロファイルへの追加が必要です。

部屋を隠す際はカメラの座標・投影方式・FOV・クリップ範囲・背景色・ポスト処理・Volume参照と、characterの座標・回転・スケール、指定した旧背景の有効状態を復元します。部屋Prefabや切替コンポーネントを無効にした場合も同じ復元を行います。Room以外の状態で既存アプリがカメラを動かした場合、次に部屋へ入る直前の新しい状態を保存します。

Windowsの起動時は、部屋を隠すだけでカメラの取得・変更やcharacterの再配置をしません。従来のWindowsOverlayControllerによるカメラオフセットと、UniWindowControllerによる透過背景設定を維持する設計です。部屋は初めから非アクティブなので、起動直後に一瞬表示されることも避けています。

## 照明と設定の扱い

静的な照明は同梱のライトマップをRoomContent有効時だけ登録します。他のシーンのライトマップを全置換しません。背景46メッシュ・66,114三角形・22マテリアル、ライトマップ対象37Renderer、リアルタイム影1灯です。PrefabはRenderSettings、QualitySettings、GraphicsSettingsを変更しません。URPのパイプライン設定ファイルも同梱しません。既存のPC用HDR無効・アルファ出力有効設定をそのまま使ってください。

11灯のうち、ベイク用の10灯は設定を残したままLightコンポーネントを無効にしています。移植先のPlayerで余分なリアルタイム光にならないための措置です。再ベイクする作業Sceneではその10灯を有効にし、Bake TypeがBakedであることを確認してください。配布時はベイク用ライトを再び無効にします。影用の1灯は有効です。

大きく部屋を変形・回転させる場合や他の静的シーンとまとめて再ベイクする場合、ライトマップ、Probe、照明条件の再検証が必要です。既存の他のVolumeと重なる場合も見た目を確認してください。SceneのLighting Settings等はPrefabだけで完全に引き継がれるものではありません。

## 検証範囲

Unity 6000.0.76f1 / URP 17.0.4の別プロジェクトで検証します。検証結果と証拠ファイルは `validation_report.md` と `evidence/` に記録します。対象コードはリモートRAiMprojectのmain `a5a0ef62691a3bac39177407cd1e8c184320f06e` を参照しています。リモートmanifestにはURP17.3.0、lockには17.0.4が記載されていたため、全アプリの依存解決を検証済みとは扱いません。

実際のWindowsデスクトップ合成、クリック透過、Flutterとの接続、モバイル実機はこの部屋単体の検証と別です。検証用Playerは既存のカメラオフセットを模擬しますが、認証・通信・ネイティブ透過プラグインは起動しません。既存アプリの本番Scene・UI・通信スクリプト・Build Settingsは変更していません。

`work/` は隔離した制作・検証用プロジェクトとPlayerです。配布に必要なのはunitypackageです。検証用キャラクター画像やRAiMの認証・通信コードはunitypackageに含みません。制作原本と以前のv1〜v3はそのまま残しています。
