using System;
using System.Collections.Generic;
using System.Linq;
using UnityEngine;

namespace RAiM.Companion
{
    // Authored atomic recipes share weights across matching renderers so the lip
    // rim and mouth cavity stay joined. Eyelid pose choices resolve separately.
    public sealed class NCharacterExpressions : MonoBehaviour
    {
        public Vector2 Gaze { get; set; }
        public string[] Names { get; private set; }
        struct Binding { public SkinnedMeshRenderer renderer; public int index; public string name; }
        readonly List<Binding> bindings = new List<Binding>();
        Eyelid leftLid, rightLid;
        Transform leftEye, rightEye;
        Camera viewCamera;
#if UNITY_STANDALONE_WIN
        readonly Dictionary<Material, Material> windowsSkinMaterials = new Dictionary<Material, Material>();
        readonly HashSet<SkinnedMeshRenderer> windowsSkinRenderers = new HashSet<SkinnedMeshRenderer>();
#endif

        // A closed-eye smile or wink is a pose choice, not a fractional blink.
        // Hysteresis avoids flutter when streamed emotion weights hover near the boundary.
        struct Eyelid
        {
            bool closing;
            float amount, start, elapsed, duration;
            public float Evaluate(float request, float deltaTime)
            {
                if (deltaTime <= 0) {
                    closing = request >= .75f;
                    amount = start = closing ? 1 : 0;
                    elapsed = duration = 1;
                    return amount;
                }
                bool next = request >= .75f || (closing && request > .6001f);
                if (next != closing) {
                    closing = next; start = amount; elapsed = 0;
                    duration = closing ? .14f : .22f;
                }
                elapsed += deltaTime;
                float progress = duration > 0 ? Mathf.Clamp01(elapsed / duration) : 1;
                amount = Mathf.Lerp(start, closing ? 1 : 0, Mathf.SmoothStep(0, 1, progress));
                return amount;
            }
        }

        public SkinnedMeshRenderer Initialize(Transform model, EmotionProfile profile)
        {
            bindings.Clear();
            leftLid = default; rightLid = default;
            leftEye = rightEye = null;
            viewCamera = Camera.main;
            var vrm = model.GetComponent<UniVRM10.Vrm10Instance>();
            if (vrm != null) {
                vrm.TryGetBoneTransform(HumanBodyBones.LeftEye, out leftEye);
                vrm.TryGetBoneTransform(HumanBodyBones.RightEye, out rightEye);
            }
            var skins = model.GetComponentsInChildren<SkinnedMeshRenderer>(true);
            var head = skins.FirstOrDefault(r => r.sharedMesh != null
                && r.sharedMesh.GetBlendShapeIndex("EyeBlinkLeft") >= 0
                && r.sharedMesh.GetBlendShapeIndex("JawOpen") >= 0);
            if (head == null) throw new InvalidOperationException("N facial mesh is missing");
            Names = Enumerable.Range(0, head.sharedMesh.blendShapeCount).Select(head.sharedMesh.GetBlendShapeName).ToArray();
            foreach (string required in profile.emotions.SelectMany(e => e.shapes).Select(s => s.shape)
                .Concat(new[] { "EyeBlinkLeft", "EyeBlinkRight", "JawOpen", "EyeLookLeft", "EyeLookRight", "EyeLookUp", "EyeLookDown" }))
                if (!Names.Contains(required)) throw new InvalidOperationException("N face shape missing: " + required);
            foreach (var skin in skins)
                foreach (string name in Names)
                {
                    int index = skin.sharedMesh.GetBlendShapeIndex(name);
                    if (index >= 0) bindings.Add(new Binding { renderer = skin, index = index, name = name });
                }
#if UNITY_STANDALONE_WIN
            ApplyWindowsSkinTone(skins);
#endif
            return head;
        }

#if UNITY_STANDALONE_WIN
        // The desktop overlay makes the shared mobile tint look overly pink.
        // Use per-instance materials so Android and the source assets stay unchanged.
        void ApplyWindowsSkinTone(SkinnedMeshRenderer[] skins)
        {
            foreach (var skin in skins) {
                var materials = skin.sharedMaterials;
                bool changed = false;
                for (int i = 0; i < materials.Length; i++) {
                    var original = materials[i];
                    if (!original || windowsSkinMaterials.ContainsValue(original) ||
                        (original.name != "N Face_Skin" && original.name != "N Hands_Skin") ||
                        !original.HasProperty("_Color")) continue;
                    if (!windowsSkinMaterials.TryGetValue(original, out var corrected)) {
                        corrected = new Material(original) { name = original.name + " (Windows)" };
                        var color = original.GetColor("_Color");
                        color.r *= .97f;
                        corrected.SetColor("_Color", color);
                        windowsSkinMaterials.Add(original, corrected);
                    }
                    materials[i] = corrected;
                    changed = true;
                }
                if (changed) {
                    skin.sharedMaterials = materials;
                    windowsSkinRenderers.Add(skin);
                }
            }
        }

        void OnDestroy()
        {
            foreach (var skin in windowsSkinRenderers) {
                if (!skin) continue;
                var materials = skin.sharedMaterials;
                bool changed = false;
                for (int i = 0; i < materials.Length; i++)
                    foreach (var entry in windowsSkinMaterials)
                        if (materials[i] == entry.Value) {
                            materials[i] = entry.Key;
                            changed = true;
                            break;
                        }
                if (changed) skin.sharedMaterials = materials;
            }
            windowsSkinRenderers.Clear();
            foreach (var material in windowsSkinMaterials.Values)
                if (material) Destroy(material);
            windowsSkinMaterials.Clear();
        }
#endif

        public void Compose(EmotionProfile profile, float[] effective, float blink, float speechOpening,
            Dictionary<string,float> values, float deltaTime = 0, float sleeping = 0)
        {
            foreach (string name in Names) values[name] = 0;
            // Effective weights already contain overall_intensity; do not apply it twice.
            for (int i = 1; i < EmotionSnapshot.Keys.Length; i++)
                foreach (var shape in profile.emotions[i].shapes)
                    values[shape.shape] += effective[i] * shape.amount * profile.faceGain;
            foreach (string name in Names) values[name] = Mathf.Clamp01(values[name]);
            foreach (string side in new[] { "Left", "Right" })
            {
                float request = values["EyeBlink" + side];
                float expression = side == "Left" ? leftLid.Evaluate(request, deltaTime) : rightLid.Evaluate(request, deltaTime);
                // Natural blinks retain their complete continuous curve.
                float closed = 1 - (1 - Mathf.Clamp01(blink)) * (1 - expression);
                values["EyeBlink" + side] = closed;
                // The natural blink meets near the lower lid. A held smile or
                // wink adds the authored smile closure without changing timing.
                string smileCorrection = "EyeSmileClosureCorrection" + side;
                if (values.ContainsKey(smileCorrection)) {
                    // A relaxed sleeping lid is flatter than the natural blink's
                    // deepest point. Introduce it only near full closure so the
                    // ordinary blink and the entry/exit transition remain intact.
                    float settledSleep = Mathf.Clamp01(sleeping) * Mathf.SmoothStep(0, 1, Mathf.InverseLerp(.65f, 1f, closed));
                    values[smileCorrection] = Mathf.Max(expression, .5f * settledSleep);
                }
                // The authored wide target stretches the dark lash geometry
                // much more than the eye opening. Compress its response smoothly
                // for every expression and mixture while retaining small changes.
                float wide = values["EyeWide" + side] * (1 - closed);
                values["EyeWide" + side] = wide / (1 + 2 * wide);
                values["EyeSquint" + side] *= 1 - closed;
            }
            float open = Mathf.Clamp01(speechOpening);
            values["JawOpen"] = 1 - (1 - values["JawOpen"]) * (1 - open);
            values["MouthPress"] *= 1 - open;
            Add(values,"EyeLookLeft", Mathf.Max(0,-Gaze.x)/25);
            Add(values,"EyeLookRight",Mathf.Max(0, Gaze.x)/25);
            Add(values,"EyeLookUp",Mathf.Max(0,Gaze.y)/18);
            Add(values,"EyeLookDown",Mathf.Max(0,-Gaze.y)/18);
            ApplyProfileCorrections(values);
            foreach (var binding in bindings)
                binding.renderer.SetBlendShapeWeight(binding.index, values[binding.name] * 100);
        }

        // Keep the original frontal expression and the entire resting mesh
        // unchanged. The far eyelid and jaw receive small, smoothly blended
        // corrections only when the corresponding expression is active.
        void ApplyProfileCorrections(Dictionary<string,float> values)
        {
            if (!values.ContainsKey("ProfileEyeLeftHalf") && !values.ContainsKey("ProfileJawOpen")) return;
            if (!viewCamera || !viewCamera.isActiveAndEnabled) viewCamera = Camera.main;
            if (!viewCamera || !leftEye || !rightEye) return;
            Vector3 axis = leftEye.position - rightEye.position;
            if (axis.sqrMagnitude < 1e-10f) return;
            Vector3 towardCamera = viewCamera.orthographic ? -viewCamera.transform.forward :
                viewCamera.transform.position - (leftEye.position + rightEye.position) * .5f;
            if (towardCamera.sqrMagnitude < 1e-10f) return;
            float facing = Vector3.Dot(axis.normalized, towardCamera.normalized);
            float leftFar = ProfileAmount(-facing), rightFar = ProfileAmount(facing);
            ApplyEyeCorrection(values, true, leftFar);
            ApplyEyeCorrection(values, false, rightFar);
            float round = values.TryGetValue("MouthRound", out float r) ? r : 0;
            SetIfPresent(values, "ProfileJawOpen", Mathf.Max(leftFar, rightFar) * values["JawOpen"] * (1 - .75f * round));
        }

        static float ProfileAmount(float facing) =>
            Mathf.SmoothStep(0, 1, Mathf.InverseLerp(.25f, .70f, facing));

        static void ApplyEyeCorrection(Dictionary<string,float> values, bool left, float profile)
        {
            float closed = values[left ? "EyeBlinkLeft" : "EyeBlinkRight"];
            float smile = values.TryGetValue(left ? "EyeSmileClosureCorrectionLeft" : "EyeSmileClosureCorrectionRight", out float s) ? s : 0;
            float closing = Mathf.SmoothStep(0, 1, Mathf.InverseLerp(0, .5f, closed));
            float fullyClosed = Mathf.SmoothStep(0, 1, Mathf.InverseLerp(.5f, 1, closed));
            SetIfPresent(values, left ? "ProfileEyeLeftHalf" : "ProfileEyeRightHalf", profile * closing * (1 - fullyClosed));
            SetIfPresent(values, left ? "ProfileEyeLeftClosed" : "ProfileEyeRightClosed", profile * fullyClosed * (1 - smile));
            SetIfPresent(values, left ? "ProfileEyeLeftSmile" : "ProfileEyeRightSmile", profile * fullyClosed * smile);
        }

        static void SetIfPresent(Dictionary<string,float> values, string name, float amount)
        {
            if (values.ContainsKey(name)) values[name] = amount;
        }
        static void Add(Dictionary<string,float> values,string name,float amount) =>
            values[name] = Mathf.Clamp01(values[name]+amount);
    }
}
