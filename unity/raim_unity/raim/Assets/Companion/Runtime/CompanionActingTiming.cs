using UnityEngine;
namespace RAiM.Companion
{
    public static class CompanionActingTiming
    {
        static readonly float[] Times={0,.10f,.23f,.43f,.70f,1};
        static readonly float[] Values={0,-.16f,1,.90f,0,0};
        public static float Phrase(float p)
        {
            for(int i=1;i<Times.Length;i++)if(p<=Times[i])return Mathf.Lerp(Values[i-1],Values[i],Mathf.SmoothStep(0,1,Mathf.InverseLerp(Times[i-1],Times[i],p)));
            return 0;
        }
    }
}
