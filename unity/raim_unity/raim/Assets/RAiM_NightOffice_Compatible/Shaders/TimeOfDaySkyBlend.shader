Shader "RAiM/TimeOfDaySkyBlend"
{
    Properties
    {
        _NightTex ("Original night sky", 2D) = "black" {}
        _NightWeight ("Night weight", Range(0, 1)) = 1
        _SkyZenith ("Day zenith", Color) = (0.19, 0.46, 0.83, 1)
        _SkyHorizon ("Day horizon", Color) = (0.73, 0.85, 1, 1)
    }
    SubShader
    {
        Tags { "RenderType"="Opaque" "RenderPipeline"="UniversalPipeline" "Queue"="Geometry" }
        Pass
        {
            Name "SkyBlend"
            Tags { "LightMode"="SRPDefaultUnlit" }
            Cull Back
            ZWrite On

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            struct Attributes { float4 positionOS : POSITION; float2 uv : TEXCOORD0; };
            struct Varyings { float4 positionCS : SV_POSITION; float2 uv : TEXCOORD0; };
            TEXTURE2D(_NightTex);
            SAMPLER(sampler_NightTex);
            CBUFFER_START(UnityPerMaterial)
                float4 _NightTex_ST;
                half4 _SkyZenith;
                half4 _SkyHorizon;
                half _NightWeight;
            CBUFFER_END

            Varyings Vert(Attributes input)
            {
                Varyings output;
                output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                output.uv = input.uv * _NightTex_ST.xy + _NightTex_ST.zw;
                return output;
            }

            half4 Frag(Varyings input) : SV_Target
            {
                half3 night = SAMPLE_TEXTURE2D(_NightTex, sampler_NightTex, input.uv).rgb;
                half3 day = lerp(_SkyHorizon.rgb, _SkyZenith.rgb, saturate(input.uv.y));
                return half4(lerp(day, night, saturate(_NightWeight)), 1);
            }
            ENDHLSL
        }
    }
}
