using System;
using UnityEngine;

namespace RAiM.NightOffice.Compatible
{
    /// <summary>Night Office's replaceable interpretation of a device-local time of day.</summary>
    [DefaultExecutionOrder(-100), DisallowMultipleComponent]
    public sealed class NightOfficeTimeVisual : MonoBehaviour, ITimeOfDayBackgroundTarget
    {
        private static readonly int NightWeightId = Shader.PropertyToID("_NightWeight");
        private static readonly int SkyZenithId = Shader.PropertyToID("_SkyZenith");
        private static readonly int SkyHorizonId = Shader.PropertyToID("_SkyHorizon");
        private static readonly int EmissionColorId = Shader.PropertyToID("_EmissionColor");

        [Header("Background only")]
        [SerializeField] private Renderer[] skyRenderers = Array.Empty<Renderer>();
        [SerializeField] private Renderer[] cityRenderers = Array.Empty<Renderer>();
        [SerializeField] private Light roomDaylight;
        [Min(0f), SerializeField] private float correctionFadeSeconds = 3f;

        [Header("Time in hours; 0 and 24 must match")]
        [SerializeField] private AnimationCurve nightWeight = new AnimationCurve(
            new Keyframe(0f, 1f), new Keyframe(5f, 1f), new Keyframe(7.5f, 0f),
            new Keyframe(17f, 0f), new Keyframe(19.5f, 1f), new Keyframe(24f, 1f));
        [SerializeField] private AnimationCurve cityEmission = new AnimationCurve(
            new Keyframe(0f, 1f), new Keyframe(5f, 1f), new Keyframe(7.5f, 0.08f),
            new Keyframe(17f, 0.08f), new Keyframe(19.5f, 1f), new Keyframe(24f, 1f));
        [SerializeField] private AnimationCurve daylightIntensity = new AnimationCurve(
            new Keyframe(0f, 0f), new Keyframe(5f, 0f), new Keyframe(7.5f, 0.45f),
            new Keyframe(12f, 0.7f), new Keyframe(17f, 0.45f),
            new Keyframe(19.5f, 0f), new Keyframe(24f, 0f));

        [SerializeField] private Gradient skyZenith = CreateGradient(
            new GradientColorKey(new Color(0.07f, 0.16f, 0.30f), 0f),
            new GradientColorKey(new Color(0.30f, 0.55f, 0.85f), 0.32f),
            new GradientColorKey(new Color(0.19f, 0.46f, 0.83f), 0.5f),
            new GradientColorKey(new Color(0.30f, 0.55f, 0.85f), 0.68f),
            new GradientColorKey(new Color(0.07f, 0.16f, 0.30f), 1f));
        [SerializeField] private Gradient skyHorizon = CreateGradient(
            new GradientColorKey(new Color(0.17f, 0.18f, 0.30f), 0f),
            new GradientColorKey(new Color(1f, 0.56f, 0.34f), 0.25f),
            new GradientColorKey(new Color(0.73f, 0.85f, 1f), 0.35f),
            new GradientColorKey(new Color(0.76f, 0.88f, 1f), 0.65f),
            new GradientColorKey(new Color(1f, 0.48f, 0.30f), 0.75f),
            new GradientColorKey(new Color(0.17f, 0.18f, 0.30f), 1f));

        private MaterialPropertyBlock block;
        private Color cityNightEmission = new Color(1.8f, 1.8f, 1.8f, 1.8f);
        private float currentNightWeight = 1f;
        private float currentCityEmission = 1f;
        private float currentDaylightIntensity;
        private Color currentZenith;
        private Color currentHorizon;
        private Quaternion currentSunRotation;
        private bool initialized;

        private static Gradient CreateGradient(params GradientColorKey[] keys)
        {
            var gradient = new Gradient();
            gradient.SetKeys(keys, new[] { new GradientAlphaKey(1f, 0f), new GradientAlphaKey(1f, 1f) });
            return gradient;
        }

        private void Awake()
        {
            block = new MaterialPropertyBlock();
            foreach (var renderer in cityRenderers)
            {
                if (!renderer || !renderer.sharedMaterial || !renderer.sharedMaterial.HasProperty(EmissionColorId)) continue;
                cityNightEmission = renderer.sharedMaterial.GetColor(EmissionColorId);
                break;
            }
        }

        private void OnEnable()
        {
            // The original room is authored for night. No device clock means night remains visible.
            initialized = false;
            ApplyTimeOfDay(0f, 0f, true);
        }

        public void ApplyTimeOfDay(float dayFraction, float unscaledDeltaTime, bool immediate)
        {
            float hour = Mathf.Repeat(dayFraction, 1f) * 24f;
            float nextNight = Mathf.Clamp01(nightWeight.Evaluate(hour));
            float nextCity = Mathf.Max(0f, cityEmission.Evaluate(hour));
            float nextLight = Mathf.Max(0f, daylightIntensity.Evaluate(hour));
            Color nextZenith = skyZenith.Evaluate(hour / 24f);
            Color nextHorizon = skyHorizon.Evaluate(hour / 24f);
            Quaternion nextRotation = Quaternion.Euler(dayFraction * 360f - 90f, -30f, 0f);
            float blend = immediate || !initialized || correctionFadeSeconds <= 0f
                ? 1f
                : 1f - Mathf.Exp(-Mathf.Max(0f, unscaledDeltaTime) * 4.6f / correctionFadeSeconds);

            currentNightWeight = Mathf.Lerp(currentNightWeight, nextNight, blend);
            currentCityEmission = Mathf.Lerp(currentCityEmission, nextCity, blend);
            currentDaylightIntensity = Mathf.Lerp(currentDaylightIntensity, nextLight, blend);
            currentZenith = Color.Lerp(currentZenith, nextZenith, blend);
            currentHorizon = Color.Lerp(currentHorizon, nextHorizon, blend);
            currentSunRotation = Quaternion.Slerp(currentSunRotation, nextRotation, blend);
            initialized = true;

            // Read the existing block first: RoomBakedLighting stores custom SH coefficients in it.
            foreach (var renderer in skyRenderers)
            {
                if (!renderer) continue;
                renderer.GetPropertyBlock(block);
                block.SetFloat(NightWeightId, currentNightWeight);
                block.SetColor(SkyZenithId, currentZenith);
                block.SetColor(SkyHorizonId, currentHorizon);
                renderer.SetPropertyBlock(block);
            }
            foreach (var renderer in cityRenderers)
            {
                if (!renderer) continue;
                renderer.GetPropertyBlock(block);
                block.SetColor(EmissionColorId, cityNightEmission * currentCityEmission);
                renderer.SetPropertyBlock(block);
            }
            if (roomDaylight)
            {
                roomDaylight.transform.localRotation = currentSunRotation;
                roomDaylight.intensity = currentDaylightIntensity;
                roomDaylight.enabled = currentDaylightIntensity > 0.001f;
            }
        }
    }
}
