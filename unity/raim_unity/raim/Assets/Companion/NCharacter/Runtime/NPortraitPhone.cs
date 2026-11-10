using UnityEngine;
namespace RAiM.Companion
{
    [DefaultExecutionOrder(12080)]
    public sealed class NPortraitPhone : MonoBehaviour
    {
        public CompanionActor actor;
        public Transform phone;
        public SkinnedMeshRenderer body;
        Vector3 scale;
        void Awake(){if(phone!=null){scale=phone.localScale;phone.gameObject.SetActive(false);}}
        void LateUpdate()
        {
            if(phone==null||actor?.Performance==null)return;
            SetGrip(actor.Performance.PhoneWeight);
            float reveal=Mathf.SmoothStep(0,1,Mathf.InverseLerp(.55f,.93f,actor.Performance.PhoneWeight));
            phone.gameObject.SetActive(reveal>.001f);
            phone.localScale=scale*Mathf.Max(.001f,reveal);
        }
        public void SetGrip(float weight)
        {
            if(body==null)return;
            int index=body.sharedMesh.GetBlendShapeIndex("PhoneGrip");
            if(index>=0)body.SetBlendShapeWeight(index,100*Mathf.SmoothStep(0,1,Mathf.InverseLerp(.7f,.995f,weight)));
        }
    }
}
