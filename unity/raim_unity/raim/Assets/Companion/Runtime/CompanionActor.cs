using System;
using System.Collections.Generic;
using Newtonsoft.Json.Linq;
using UniVRM10;
using UnityEngine;

namespace RAiM.Companion
{
    // Animator -> local upper-body offsets -> UniVRM look-at/springs -> one facial writer.
    [DefaultExecutionOrder(12000)]
    public sealed class CompanionActor : MonoBehaviour
    {
        public Vrm10Instance model;
        public Animator animator;
        public EmotionProfile profile;
        public NCharacterExpressions authoredFace;
        public PerformanceLibrary performanceLibrary;
        public CompanionPerformancePlayer Performance { get; private set; }
        CompanionArmClearance armClearance;
        public bool automaticBlink = true;
        public bool automaticGaze = true;
        public bool demoMouth;
        [Range(0, 1)] public float manualBlink;
        public EmotionSnapshot Target { get; private set; } = EmotionSnapshot.Neutral;
        public readonly CompanionState State = new CompanionState();
        public readonly float[] Smoothed = new float[12];
        public bool Ready { get; private set; }
        public bool Sleeping { get; private set; }
        private float sleepWeight;
        private bool stateHeartbeat;
        public IReadOnlyDictionary<string, float> Applied => applied;
        public string LastRejection { get; private set; } = "";
        public string ActiveReaction => reaction;
        public event Action ReadyChanged;
        private readonly Dictionary<string, float> applied = new Dictionary<string, float>();
        private readonly Dictionary<string, int> shapeIndices = new Dictionary<string, int>();
        private readonly Dictionary<string, FaceRegion> regions = new Dictionary<string, FaceRegion>();
        private SkinnedMeshRenderer face;
        private Transform head, chest, leftArm, rightArm;
        private Transform gazeLeftEye, gazeRightEye;
        private Camera gazeCamera;
        private Vector2 cameraGaze;
        private CompanionPoseRig poseRig;
        private CompanionGestureDirector performance;
        public float ChinContactError => poseRig?.ChinContactError ?? 0;
        public float ThinkingContactWeight => performance?.ThinkingWeight ?? 0;
        public Vector4 LeftFingerClosure => performance?.LeftGrip ?? Vector4.zero;
        public Vector4 RightFingerClosure => performance?.RightGrip ?? Vector4.zero;
        public float FootPlantError => poseRig?.FootError ?? 0;
        private float lastEmotion, lastState, time, reactionClock, cooldown;
        private CompanionBlinkScheduler blinkScheduler;
        private string reaction = "";
        private BehaviorState previousState = (BehaviorState)(-1);
        private static readonly int IdleVariant = Animator.StringToHash("IdleVariant");
        private string[] controlledShapes;
        private Transform[] boundsBones;
        public Bounds ModelBounds
        {
            get
            {
                // Imported SkinnedMeshRenderer bounds can contain stale bind-pose extents.
                // For this model's desktop hit region, follow the posed humanoid instead.
                if (boundsBones == null)
                {
                    var list = new List<Transform>();
                    foreach (HumanBodyBones bone in Enum.GetValues(typeof(HumanBodyBones)))
                        if (bone != HumanBodyBones.LastBone && model.TryGetBoneTransform(bone,out var t)) list.Add(t);
                    boundsBones = list.ToArray();
                }
                var b = new Bounds(boundsBones[0].position, Vector3.zero);
                foreach (var t in boundsBones) b.Encapsulate(t.position);
                if (model.TryGetBoneTransform(HumanBodyBones.Head,out var h)) b.Encapsulate(h.position + model.transform.up * .18f);
                b.Expand(new Vector3(.12f,.08f,.16f));
                return b;
            }
        }
        private void Awake()
        {
            if (model == null || profile == null || animator == null) { LastRejection = "Missing model/profile/Animator"; return; }
            profile = Instantiate(profile); // live tuning cannot dirty the source asset
            model.UpdateType = Vrm10Instance.UpdateTypes.None;
            animator.applyRootMotion = false;
            animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
            if (authoredFace != null) face = authoredFace.Initialize(model.transform, profile);
            else foreach (var r in model.GetComponentsInChildren<SkinnedMeshRenderer>())
                if (r.sharedMesh != null && r.sharedMesh.GetBlendShapeIndex("Fcl_MTH_A") >= 0) { face = r; break; }
            if (face == null) { LastRejection = "Selected model lacks expected face shapes; configure its own profile"; return; }
            foreach (var pose in profile.emotions)
                foreach (var s in pose.shapes)
                {
                    int index = face.sharedMesh.GetBlendShapeIndex(s.shape);
                    if (index < 0) { LastRejection = "Missing shape: " + s.shape; return; }
                    shapeIndices[s.shape] = index; regions[s.shape] = s.region; applied[s.shape] = 0;
                }
            foreach (string key in authoredFace != null ? authoredFace.Names : new[] { "Fcl_EYE_Close", "Fcl_MTH_A" })
            { shapeIndices[key] = face.sharedMesh.GetBlendShapeIndex(key); applied[key] = 0; }
            controlledShapes = new string[applied.Count]; applied.Keys.CopyTo(controlledShapes, 0);
            model.TryGetBoneTransform(HumanBodyBones.Head, out head);
            model.TryGetBoneTransform(HumanBodyBones.LeftEye, out gazeLeftEye);
            model.TryGetBoneTransform(HumanBodyBones.RightEye, out gazeRightEye);
            model.TryGetBoneTransform(HumanBodyBones.Chest, out chest);
            model.TryGetBoneTransform(HumanBodyBones.LeftUpperArm, out leftArm);
            model.TryGetBoneTransform(HumanBodyBones.RightUpperArm, out rightArm);
            poseRig = new CompanionPoseRig(transform,model);
            performance = new CompanionGestureDirector(poseRig);
            if(performanceLibrary!=null){if(!performanceLibrary.standingPortraitMode)armClearance=new CompanionArmClearance(transform,poseRig,model);Performance=new CompanionPerformancePlayer(animator,performanceLibrary);}
            Smoothed[0] = 1; lastEmotion = lastState = Time.unscaledTime;
            blinkScheduler = new CompanionBlinkScheduler(Guid.NewGuid().GetHashCode());
        }
        private void Start()
        {
            Ready = face != null && controlledShapes != null;
            if (Ready) { _ = model.Runtime; ReadyChanged?.Invoke(); }
        }
        public bool ReceiveEmotions(string json)
        {
            if (!EmotionSnapshot.TryParse(json, out var snapshot)) { LastRejection = "Invalid emotion payload (previous snapshot retained)"; return false; }
            Target = snapshot; lastEmotion = Time.unscaledTime; Performance?.NotifyActivity(); LastRejection = ""; return true;
        }
        public bool ReceiveState(string json)
        {
            if (!State.TryApply(json)) { LastRejection = "Invalid or stale state snapshot"; return false; }
            stateHeartbeat = true;
            if (State.Current != BehaviorState.Idle) Performance?.NotifyActivity();
            lastState = Time.unscaledTime; LastRejection = ""; return true;
        }
        public void SetSleeping(bool sleeping)
        {
            Sleeping = sleeping;
            Performance?.NotifyActivity();
            Target = EmotionSnapshot.Neutral;
            State.ClearActivity();
            reaction = "";
        }
        public void ReceiveLegacyEmotion(string value)
        {
            ReceiveEmotions(new JObject { ["emotion"] = value, ["intensity"] = 0.5 }.ToString());
        }
        public void ReceiveToolState(string json)
        {
            try
            {
                var j = JObject.Parse(json);
                if (j["is_using_tool"]?.Type == JTokenType.Boolean)
                { State.ExternalWork = j["is_using_tool"].Value<bool>(); lastState = Time.unscaledTime; Performance?.NotifyActivity(); }
            }
            catch (Newtonsoft.Json.JsonException) { LastRejection = "Invalid tool state"; }
        }
        public void TransportReset() { State.ResetTransport(); stateHeartbeat = false; reaction = ""; lastState = Time.unscaledTime; }
        public void Disconnected() { State.ClearActivity(); reaction = ""; }
        public void NotifyActivity() { Performance?.NotifyActivity(); }
        public bool React(string kind)
        {
            if (cooldown > 0 || (kind != "nod" && kind != "discovery" && kind != "surprise")) return false;
            reaction = kind; reactionClock = 0; cooldown = Math.Max(2.5f, profile.gestureInterval * 0.6f); return true;
        }
        private void OnApplicationPause(bool paused)
        {
            if (paused) { State.ClearActivity(); reaction = ""; }
            else { State.ResetTransport(); ReadyChanged?.Invoke(); }
        }
        private void Update() { if(Performance==null)poseRig?.RestoreBase(); }
        private void OnDestroy(){Performance?.Dispose();}
        private void LateUpdate()
        {
            if (!Ready) return;
            float dt = Mathf.Min(Time.unscaledDeltaTime, 0.1f); time += dt; cooldown -= dt;
            if (profile.neutralTimeout > 0 && Time.unscaledTime - lastEmotion > profile.neutralTimeout) Target = EmotionSnapshot.Neutral;
            // State is refreshed by a local heartbeat. Never erase valid live work merely because g=0.
            if (stateHeartbeat && profile.neutralTimeout > 0 && Time.unscaledTime - lastState > profile.neutralTimeout) State.ClearActivity();
            sleepWeight = Mathf.MoveTowards(sleepWeight, Sleeping ? 1 : 0, dt * 3);
            // main's research portrait uses a focused, open-eyed expression;
            // retain Target so the previous emotion returns after tool use.
            bool focusingOnPhone = !Sleeping && (State.ExternalWork || State.Current == BehaviorState.Researching);
            var expression = Sleeping || focusingOnPhone ? EmotionSnapshot.Neutral : Target;
            float alpha = 1 - Mathf.Exp(-profile.smoothing * dt);
            for (int i = 0; i < 12; i++) Smoothed[i] = Mathf.Lerp(Smoothed[i], expression.Effective[i], alpha);
            var state = Sleeping ? BehaviorState.Idle : State.Current;
            if (Performance==null && state != previousState)
            { animator.CrossFadeInFixedTime(state.ToString(), 0.28f); previousState = state; }
            if(Performance==null)animator.SetFloat(IdleVariant, (Mathf.Sin(time * 0.11f) + 1));

            poseRig.CaptureBase();
            Vector2 gaze = Vector2.zero;
            if(Performance!=null)
            {
                if (!string.IsNullOrEmpty(reaction)) { reactionClock += dt; if (reactionClock >= 1.8f) reaction = ""; }
                gaze=Performance.Apply(Smoothed,state,profile,dt,reaction,expression.Normalized,!Sleeping && State.ExternalWork,Sleeping);
                armClearance?.ApplyRuntime(dt);
            }
            else if (profile.fullBodyActing)
            {
                if (!string.IsNullOrEmpty(reaction)) { reactionClock += dt; if (reactionClock >= 1.8f) reaction = ""; }
                gaze = performance.Apply(profile, Smoothed, state, time, dt, reaction, Mathf.Clamp01(reactionClock / 1.8f));
            }
            else
            {
            Vector3 leftOffset=Vector3.zero,rightOffset=Vector3.zero;
            float fingerCurl=0;
            Vector3 headOffset = Vector3.zero, chestOffset = Vector3.zero;
            for (int i = 1; i < 12; i++)
            {
                headOffset += profile.emotions[i].headDegrees * Smoothed[i];
                chestOffset += profile.emotions[i].chestDegrees * Smoothed[i];
                gaze += profile.emotions[i].gaze * Smoothed[i];
                leftOffset += profile.emotions[i].leftHandOffset * Smoothed[i];
                rightOffset += profile.emotions[i].rightHandOffset * Smoothed[i];
                fingerCurl += profile.emotions[i].fingerCurl * Smoothed[i];
            }
            // State gestures are present even at zero emotion intensity.
            if (state == BehaviorState.Researching) gaze += new Vector2(Mathf.Sin(time * 0.8f) * 16, -7);
            else if (state == BehaviorState.Thinking) gaze += new Vector2(10 + Mathf.Sin(time * 0.2f) * 4, 7);
            else if (state == BehaviorState.Listening) headOffset.x += Mathf.Max(0, Mathf.Sin(time * 0.8f)) * 2;
            else if (state == BehaviorState.Speaking)
            {
                float gesture = Mathf.Pow(Mathf.Max(0, Mathf.Sin(time * Mathf.PI * 2 / profile.gestureInterval)), 6) * profile.gestureStrength;
                rightOffset += new Vector3(.055f,.11f,.08f)*gesture;
                headOffset.y += Mathf.Sin(time * 0.7f) * 1.2f;
            }
            if (!string.IsNullOrEmpty(reaction))
            {
                reactionClock += dt;
                float k = CompanionActingTiming.Phrase(Mathf.Clamp01(reactionClock / 1.8f));
                if (reaction == "nod") headOffset.x += k * 20;
                if (reaction == "discovery") { headOffset.x -= k * 16; rightOffset += new Vector3(.025f,.35f,.10f)*k; }
                if (reaction == "surprise") { headOffset.x -= k * 19; chestOffset.x -= k * 8; leftOffset += new Vector3(-.1f,.35f,.15f)*k; rightOffset += new Vector3(.1f,.28f,.15f)*k; }
                if (reactionClock >= 1.8f) reaction = "";
            }
            head.localRotation *= Quaternion.Euler(headOffset*profile.bodyGain);
            chest.localRotation *= Quaternion.Euler(chestOffset*profile.bodyGain);
            poseRig.Arm(true,poseRig.Hand(true)+leftOffset*profile.bodyGain);
            poseRig.Arm(false,poseRig.Hand(false)+rightOffset*profile.bodyGain);
            poseRig.CurlFingers(fingerCurl * profile.bodyGain);
            poseRig.Feet();
            }
            // Keep eye contact as the animated head moves. Phone and sleep poses retain
            // their authored gaze, with the change blended during the transition.
            if (automaticGaze && authoredFace != null && performanceLibrary != null && performanceLibrary.standingPortraitMode)
            {
                Vector2 target = CameraEyeContact();
                cameraGaze = Vector2.Lerp(cameraGaze, target, 1 - Mathf.Exp(-6 * dt));
                float phoneWeight = Performance != null ? Performance.PhoneWeight : (focusingOnPhone ? 1 : 0);
                gaze += cameraGaze * (1 - Mathf.Clamp01(phoneWeight)) * (1 - sleepWeight);
            }
            else cameraGaze = Vector2.zero;
            blinkScheduler.Tick(profile, dt, automaticBlink);
            float gazeBlink=CurrentBlink();
            gaze *= 1-gazeBlink;
            if (authoredFace != null) authoredFace.Gaze = automaticGaze ? gaze : Vector2.zero;
            if (automaticGaze && authoredFace == null)
                model.Runtime.LookAt.LookAtInput = new LookAtInput { YawPitch = new LookAtEyeDirection(gaze.x, gaze.y) };
            else model.Runtime.LookAt.LookAtInput = new LookAtInput { YawPitch = new LookAtEyeDirection(0, 0) };
            // Keep imported expressions at zero; atomic shape compositor owns the face.
            foreach (var key in model.Runtime.Expression.ExpressionKeys) model.Runtime.Expression.SetWeight(key, 0);
            model.Runtime.Process();
            ComposeFace(dt);
        }
        private Vector2 CameraEyeContact()
        {
            if (!head || !gazeLeftEye || !gazeRightEye) return Vector2.zero;
            if (!gazeCamera || !gazeCamera.isActiveAndEnabled) gazeCamera = Camera.main;
            if (!gazeCamera) return Vector2.zero;
            Vector3 eyeAxis = gazeLeftEye.position - gazeRightEye.position;
            if (eyeAxis.sqrMagnitude < 1e-10f) return Vector2.zero;
            eyeAxis.Normalize();
            Vector3 up = Vector3.ProjectOnPlane(head.up, eyeAxis);
            if (up.sqrMagnitude < 1e-10f) return Vector2.zero;
            up.Normalize();
            Vector3 forward = Vector3.Cross(up, eyeAxis).normalized;
            Vector3 towardCamera = gazeCamera.orthographic ? -gazeCamera.transform.forward :
                gazeCamera.transform.position - (gazeLeftEye.position + gazeRightEye.position) * .5f;
            if (towardCamera.sqrMagnitude < 1e-10f) return Vector2.zero;
            towardCamera.Normalize();
            float facing = Vector3.Dot(forward, towardCamera);
            if (facing <= .15f) return Vector2.zero;
            float yaw = -Mathf.Atan2(Vector3.Dot(towardCamera, eyeAxis), facing) * Mathf.Rad2Deg;
            float pitch = Mathf.Asin(Mathf.Clamp(Vector3.Dot(towardCamera, up), -1, 1)) * Mathf.Rad2Deg;
            return new Vector2(Mathf.Clamp(yaw, -8, 8), Mathf.Clamp(pitch, -7, 7));
        }
        private float CurrentBlink()
        {
            return Mathf.Max(sleepWeight, Mathf.Max(manualBlink, automaticBlink ? blinkScheduler.Value : 0));
        }
        private void ComposeFace(float dt)
        {
            if (authoredFace != null)
            {
                float authoredAmplitude = State.Playing ? State.Amplitude : 0;
                if (demoMouth) authoredAmplitude = 0.45f * Mathf.Max(0, Mathf.Sin(time * 9)) * (0.6f + 0.4f * Mathf.Sin(time * 3));
                authoredFace.Compose(profile, Smoothed, CurrentBlink(), Mathf.Clamp01(authoredAmplitude) * .7f, applied, dt, sleepWeight);
                return;
            }
            foreach (string name in controlledShapes) applied[name] = 0;
            for (int i = 1; i < 12; i++) foreach (var s in profile.emotions[i].shapes) applied[s.shape] += Smoothed[i] * s.amount * profile.faceGain;
            float brows = 0, eyes = 0, mouth = 0;
            foreach (var p in regions)
            {
                if (p.Value == FaceRegion.Brow) brows += applied[p.Key];
                if (p.Value == FaceRegion.Eye) eyes += applied[p.Key];
                if (p.Value == FaceRegion.Mouth) mouth += applied[p.Key];
            }
            float blink = CurrentBlink();
            float amplitude = State.Playing ? State.Amplitude : 0;
            if (demoMouth) amplitude = 0.45f * Mathf.Max(0, Mathf.Sin(time * 9)) * (0.6f + 0.4f * Mathf.Sin(time * 3));
            float opening = Mathf.Clamp01(amplitude) * 0.7f;
            foreach (var p in regions)
            {
                float budget = p.Value == FaceRegion.Brow ? profile.browBudget : p.Value == FaceRegion.Eye ? profile.eyeBudget : profile.mouthBudget;
                float sum = p.Value == FaceRegion.Brow ? brows : p.Value == FaceRegion.Eye ? eyes : mouth;
                applied[p.Key] *= Mathf.Min(1, budget / Mathf.Max(0.001f, sum));
                if (p.Value == FaceRegion.Eye) applied[p.Key] *= 1 - blink;
                if (p.Value == FaceRegion.Mouth) applied[p.Key] *= 1 - opening;
            }
            applied["Fcl_EYE_Close"] = blink;
            applied["Fcl_MTH_A"] = opening;
            foreach (string name in controlledShapes) face.SetBlendShapeWeight(shapeIndices[name], Mathf.Clamp01(applied[name]) * 100);
        }
    }
}
