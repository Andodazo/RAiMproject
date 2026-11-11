using UnityEngine;

namespace RAiM.Companion
{
    [DefaultExecutionOrder(12050)]
    public sealed class NUpperArmCorrectives : MonoBehaviour
    {
        public CompanionActor actor;
        public SkinnedMeshRenderer body;
        [Range(0,1)] public float strength=1;
        Transform chest;
        readonly Transform[] upper=new Transform[2],lower=new Transform[2];
        readonly int[] at90=new int[2],at135=new int[2];
        public Vector2 Elevation { get; private set; }
        void Start()
        {
            if(actor==null||body==null){enabled=false;return;}
            actor.model.TryGetBoneTransform(HumanBodyBones.Chest,out chest);
            for(int i=0;i<2;i++) {
                actor.model.TryGetBoneTransform(i==0?HumanBodyBones.LeftUpperArm:HumanBodyBones.RightUpperArm,out upper[i]);
                actor.model.TryGetBoneTransform(i==0?HumanBodyBones.LeftLowerArm:HumanBodyBones.RightLowerArm,out lower[i]);
                at90[i]=body.sharedMesh.GetBlendShapeIndex("UpperArm_Raise_90_"+(i==0?"L":"R"));
                at135[i]=body.sharedMesh.GetBlendShapeIndex("UpperArm_Raise_135_"+(i==0?"L":"R"));
            }
        }
        void LateUpdate()
        {
            if(chest==null)return;
            var angles=Vector2.zero;
            for(int i=0;i<2;i++) {
                if(upper[i]==null||lower[i]==null||at90[i]<0||at135[i]<0)continue;
                float angle=Vector3.Angle(-chest.up,lower[i].position-upper[i].position);
                angles[i]=angle;
                float high=Ease((angle-90)/45);
                body.SetBlendShapeWeight(at90[i],100*strength*Ease((angle-30)/55)*(1-high));
                body.SetBlendShapeWeight(at135[i],100*strength*high);
            }
            Elevation=angles;
        }
        static float Ease(float t)=>.5f-.5f*Mathf.Cos(Mathf.PI*Mathf.Clamp01(t));
    }
}
