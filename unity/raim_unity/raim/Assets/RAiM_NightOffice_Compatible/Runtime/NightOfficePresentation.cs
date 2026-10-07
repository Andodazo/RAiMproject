using System;
using UnityEngine;
using UnityEngine.Rendering.Universal;

namespace RAiM.NightOffice.Compatible {
    /// <summary>One existing camera, with a room that is absent in the Windows desktop mode.</summary>
    [DefaultExecutionOrder(-9000), DisallowMultipleComponent]
    public sealed class NightOfficePresentation : MonoBehaviour {
        public enum DisplayMode { Automatic, Room, DesktopOverlay }
        [Tooltip("Automatic: Windows builds (including Editor Play with Windows target) keep desktop overlay; other targets show the room.")]
        public DisplayMode mode=DisplayMode.Automatic;
        [Tooltip("Existing Main Camera. If empty, Camera.main is resolved only when entering Room mode.")]
        public Camera mainCamera;
        [Tooltip("Existing character SpriteRenderer. Its object name, sprites and receiver scripts are unchanged.")]
        public SpriteRenderer character;
        public GameObject roomContent;
        public Transform avatarAnchor;
        public TextAsset placementProfile;
        [Min(.1f)] public float visibleHeight=1.65f;
        // スマホで、ライムの頭のてっぺんを画面の上から何割の位置に置くか（0〜0.6）。
        // 0 なら合わせない（visibleHeight の大きさのまま）。
        // 画面の高さに対する割合なので、端末が変わっても見え方が同じになる。
        // Flutter が「新しい会話」のバーのすぐ下の位置を送ってくる（SetHeadTopFromScreenTop）。
        // 届くまではこの値を使う。
        [Range(0f,.6f)] public float headTopFromScreenTop=.22f;
        public Vector3 roomCameraPosition=new Vector3(4.1f,1.4f,.25f);
        public Vector3 roomCameraTarget=new Vector3(2.75f,1.15f,2.95f);
        [Range(10,120)] public float roomVerticalFov=54;
        [Tooltip("Only assigned old backgrounds/lights are hidden in Room mode, then restored. Leave Windows overlay objects out of this list.")]
        public GameObject[] hideWhileRoomVisible=Array.Empty<GameObject>();
        public bool IsRoomVisible=>roomApplied;
        public bool AutomaticUsesDesktopOverlay {
            get {
#if UNITY_STANDALONE_WIN
                return true;
#else
                return Application.platform==RuntimePlatform.WindowsPlayer;
#endif
            }
        }

        [Serializable] sealed class Region {public float x,y,width,height;}
        [Serializable] sealed class Entry {public string spriteName;public Region visibleRect;}
        [Serializable] sealed class Profile {public Entry[] sprites;}
        struct Pose {
            public Vector3 position,scale;public Quaternion rotation;
            public static Pose Read(Transform t)=>new Pose {position=t.localPosition,rotation=t.localRotation,scale=t.localScale};
            public void Restore(Transform t) {if(!t)return;t.localPosition=position;t.localRotation=rotation;t.localScale=scale;}
        }
        sealed class CameraState {
            public Camera camera;public Pose pose;public bool orthographic;public float fov,near,far;
            public CameraClearFlags clearFlags;public Color background;public UniversalAdditionalCameraData additional;
            public bool post;public LayerMask volumeMask;public Transform volumeTrigger;
            public CameraState(Camera c) {
                camera=c;pose=Pose.Read(c.transform);orthographic=c.orthographic;fov=c.fieldOfView;near=c.nearClipPlane;far=c.farClipPlane;
                clearFlags=c.clearFlags;background=c.backgroundColor;additional=c.GetComponent<UniversalAdditionalCameraData>();
                if(additional) {post=additional.renderPostProcessing;volumeMask=additional.volumeLayerMask;volumeTrigger=additional.volumeTrigger;}
            }
            public void Restore() {
                if(!camera)return;pose.Restore(camera.transform);camera.orthographic=orthographic;camera.fieldOfView=fov;
                camera.nearClipPlane=near;camera.farClipPlane=far;camera.clearFlags=clearFlags;camera.backgroundColor=background;
                if(additional) {additional.renderPostProcessing=post;additional.volumeLayerMask=volumeMask;additional.volumeTrigger=volumeTrigger;}
            }
        }
        bool roomApplied;
        DisplayMode lastMode;
        CameraState savedCamera;
        SpriteRenderer savedCharacter;
        Pose savedCharacterPose;
        GameObject[] savedHidden=Array.Empty<GameObject>();
        bool[] savedActive=Array.Empty<bool>();
        Profile profile;
        Sprite lastSprite;
        int lastScreenWidth,lastScreenHeight;

        void OnEnable() {if(Application.isPlaying)ApplyMode();}
        void OnDisable() {if(Application.isPlaying)LeaveRoom();}
        void LateUpdate() {
            if(!Application.isPlaying)return;
            if(mode!=lastMode)ApplyMode();
            if(roomApplied && savedCharacter && savedCharacter.sprite!=lastSprite)PlaceSprite();
            // 画面の大きさが変わったら（回転・分割表示など）頭の位置を合わせ直す
            else if(roomApplied && (Screen.width!=lastScreenWidth || Screen.height!=lastScreenHeight))PlaceSprite();
        }
        /// <summary>
        /// 頭のてっぺんの位置（画面の上からの割合）を変える。Flutter から呼ばれる。
        /// </summary>
        public void SetHeadTopFromScreenTop(float value) {
            headTopFromScreenTop=Mathf.Clamp(value,0f,.6f);
            if(roomApplied)PlaceSprite();
        }
        public void SetMode(DisplayMode value) {mode=value;if(Application.isPlaying && isActiveAndEnabled)ApplyMode();}
        public void ApplyMode() {
            if(!Application.isPlaying)return;
            lastMode=mode;
            bool show=mode==DisplayMode.Room || mode==DisplayMode.Automatic && !AutomaticUsesDesktopOverlay;
            if(show)EnterRoom();else LeaveRoom();
        }
        bool ValidateReferences(Camera camera,SpriteRenderer sprite) {
            if(!roomContent || roomContent==gameObject || !roomContent.transform.IsChildOf(transform) || !avatarAnchor || !camera) {
                Debug.LogWarning("NightOffice: assign the existing camera and room references. Room stays hidden.",this);return false;
            }
            if(camera.transform.IsChildOf(roomContent.transform) || sprite && sprite.transform.IsChildOf(roomContent.transform)) {
                Debug.LogWarning("NightOffice: camera and character must stay outside RoomContent.",this);return false;
            }
            var parentScale=sprite && sprite.transform.parent?sprite.transform.parent.lossyScale:Vector3.one;
            if(parentScale.x<=0 || Mathf.Abs(parentScale.x-parentScale.y)>.0001f || Mathf.Abs(parentScale.x-parentScale.z)>.0001f) {
                Debug.LogWarning("NightOffice: character parent must have a positive uniform scale.",this);return false;
            }
            foreach(var target in hideWhileRoomVisible) if(target && (transform.IsChildOf(target.transform) ||
                camera.transform.IsChildOf(target.transform) || sprite && sprite.transform.IsChildOf(target.transform))) {
                Debug.LogWarning("NightOffice: a hide target contains the camera, character or mode controller.",this);return false;
            }
            return true;
        }
        void EnterRoom() {
            if(roomApplied)return;
            var camera=mainCamera?mainCamera:Camera.main;
            var sprite=character;
            if(!sprite) {var existing=GameObject.Find("character");if(existing)sprite=existing.GetComponent<SpriteRenderer>();}
            if(!ValidateReferences(camera,sprite)) {if(roomContent)roomContent.SetActive(false);return;}
            savedCamera=new CameraState(camera);savedCharacter=sprite;if(sprite)savedCharacterPose=Pose.Read(sprite.transform);
            savedHidden=(GameObject[])hideWhileRoomVisible.Clone();savedActive=new bool[savedHidden.Length];
            for(int i=0;i<savedHidden.Length;i++)if(savedHidden[i]) {savedActive[i]=savedHidden[i].activeSelf;savedHidden[i].SetActive(false);}
            roomApplied=true;
            camera.transform.position=transform.TransformPoint(roomCameraPosition);
            camera.transform.LookAt(transform.TransformPoint(roomCameraTarget),transform.up);
            camera.orthographic=false;camera.fieldOfView=roomVerticalFov;camera.nearClipPlane=.03f;camera.farClipPlane=350;
            camera.clearFlags=CameraClearFlags.SolidColor;camera.backgroundColor=new Color(.01f,.02f,.04f,1);
            if(savedCamera.additional) {
                savedCamera.additional.renderPostProcessing=true;
                savedCamera.additional.volumeLayerMask=savedCamera.volumeMask.value | (1<<roomContent.layer);
                savedCamera.additional.volumeTrigger=camera.transform;
            }
            if(profile==null && placementProfile)profile=JsonUtility.FromJson<Profile>(placementProfile.text);
            PlaceSprite();roomContent.SetActive(true);
        }
        void PlaceSprite() {
            if(!savedCharacter || !savedCharacter.sprite || !avatarAnchor)return;
            var sprite=savedCharacter.sprite;var region=new Region {x=0,y=0,width=1,height=1};
            if(profile?.sprites!=null)foreach(var entry in profile.sprites)if(entry.spriteName==sprite.name) {region=entry.visibleRect;break;}
            var size=sprite.rect.size/sprite.pixelsPerUnit;var pivot=sprite.pivot/sprite.pixelsPerUnit;
            if(region==null || size.y<=0 || region.height<=0 || visibleHeight<=0)return;
            float scale=visibleHeight/(size.y*region.height)*HeadFitFactor();
            var parentScale=savedCharacter.transform.parent?savedCharacter.transform.parent.lossyScale:Vector3.one;
            if(parentScale.x<=0 || Mathf.Abs(parentScale.x-parentScale.y)>.0001f || Mathf.Abs(parentScale.x-parentScale.z)>.0001f)return;
            savedCharacter.transform.localScale=Vector3.one*(scale/parentScale.x);
            savedCharacter.transform.rotation=avatarAnchor.rotation;
            var offset=new Vector3((pivot.x-size.x*(region.x+region.width*.5f))*scale,(pivot.y-size.y*region.y)*scale,0);
            savedCharacter.transform.position=avatarAnchor.position+avatarAnchor.rotation*offset;
            lastSprite=sprite;
            lastScreenWidth=Screen.width;lastScreenHeight=Screen.height;
        }
        /// <summary>
        /// 頭のてっぺんが headTopFromScreenTop の高さに来るよう、足元を基準に何倍にするか。
        ///
        /// 足元（avatarAnchor）は動かさず、上へ伸ばす。カメラは遠近法なので
        /// 拡大率と画面上の高さは比例しない。二分探索で合わせる。
        /// 画面の高さに対する割合で決めるので、端末の解像度や縦横比が変わっても
        /// 頭の位置は同じ割合になる（縦の画角は固定のため）。
        /// </summary>
        float HeadFitFactor() {
            var camera=savedCamera!=null?savedCamera.camera:null;
            if(!camera || !avatarAnchor || headTopFromScreenTop<=0f)return 1f;
            float target=1f-headTopFromScreenTop; // ビューポートは下が0・上が1
            Vector3 feet=avatarAnchor.position,up=avatarAnchor.up;
            float TopY(float k) {
                var p=camera.WorldToViewportPoint(feet+up*(visibleHeight*k));
                return p.z>0?p.y:float.PositiveInfinity;
            }
            // 極端な値にならないよう、元の大きさの 0.5〜2.5 倍の範囲で合わせる
            float lo=.5f,hi=2.5f;
            if(TopY(lo)>=target)return lo;
            if(TopY(hi)<=target)return hi;
            for(int i=0;i<24;i++) {float mid=(lo+hi)*.5f;if(TopY(mid)<target)lo=mid;else hi=mid;}
            return (lo+hi)*.5f;
        }
        void LeaveRoom() {
            if(roomContent)roomContent.SetActive(false);
            if(!roomApplied)return; // Windows Automatic startup never touches an existing camera or sprite.
            roomApplied=false;savedCamera?.Restore();
            if(savedCharacter)savedCharacterPose.Restore(savedCharacter.transform);
            for(int i=0;i<savedHidden.Length;i++)if(savedHidden[i])savedHidden[i].SetActive(savedActive[i]);
            savedCamera=null;savedCharacter=null;lastSprite=null;savedHidden=Array.Empty<GameObject>();savedActive=Array.Empty<bool>();
        }
    }
}
