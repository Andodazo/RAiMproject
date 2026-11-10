using UnityEngine;
namespace RAiM.Companion
{
    [DefaultExecutionOrder(12100)]
    public sealed class CompanionComicAccents : MonoBehaviour
    {
        public CompanionActor actor;
        public ComicAccentLibrary library;
        [Min(0)] public float verticalOffset = .18f;
        public bool previewHold;
        public int VisibleCount { get; private set; }
        public string CurrentKeys { get; private set; }="";
        static readonly string[] EmotionMarks={"","sparkle","sweat","anger","exclamation","heart","sweat","rays","question","music","ellipsis","sparkle"};
        sealed class Slot { public Transform root; public MeshFilter fill,outline; public MeshRenderer color,border; public string key=""; public float start; }
        readonly Slot[] slots=new Slot[2];
        Transform head;
        MaterialPropertyBlock block;
        string lastReaction="";
        float reactionUntil;
        string forced="";
        void Start()
        {
            if(actor==null||library==null){enabled=false;return;}
            actor.model.TryGetBoneTransform(HumanBodyBones.Head,out head);block=new MaterialPropertyBlock();
            for(int i=0;i<2;i++) {
                var s=new Slot();s.root=new GameObject("Comic accent "+i).transform;s.root.SetParent(transform,false);
                s.fill=new GameObject("Color",typeof(MeshFilter),typeof(MeshRenderer)).GetComponent<MeshFilter>();s.fill.transform.SetParent(s.root,false);s.color=s.fill.GetComponent<MeshRenderer>();
                s.outline=new GameObject("Outline",typeof(MeshFilter),typeof(MeshRenderer)).GetComponent<MeshFilter>();s.outline.transform.SetParent(s.root,false);s.outline.transform.localPosition=new Vector3(0,0,.003f);s.border=s.outline.GetComponent<MeshRenderer>();
                s.color.shadowCastingMode=s.border.shadowCastingMode=UnityEngine.Rendering.ShadowCastingMode.Off;
                slots[i]=s;s.root.gameObject.SetActive(false);
            }
        }
        public void Trigger(string key) {forced=key;reactionUntil=Time.unscaledTime+2.5f;}
        void LateUpdate()
        {
            if(!actor.Ready||slots[0]==null)return;
            if(actor.ActiveReaction!=lastReaction) {
                lastReaction=actor.ActiveReaction;
                if(lastReaction=="surprise")Trigger("exclamation");else if(lastReaction=="discovery")Trigger("rays");
            }
            int first=0,second=0;
            for(int i=1;i<12;i++) {if(actor.Smoothed[i]>actor.Smoothed[first]||first==0){second=first;first=i;}else if(second==0||actor.Smoothed[i]>actor.Smoothed[second])second=i;}
            string a=actor.Smoothed[first]>.13f?EmotionMarks[first]:"",b=second>0&&actor.Smoothed[second]>.16f?EmotionMarks[second]:"";
            if(a==b)b="";
            if(string.IsNullOrEmpty(a))a=actor.State.Background==BehaviorState.Thinking?"ellipsis":actor.State.Background==BehaviorState.Researching?"question":"";
            if(Time.unscaledTime<reactionUntil){a=forced;b="";}
            VisibleCount=0;CurrentKeys="";
            Show(slots[0],a,0);Show(slots[1],b,1);
        }
        void Show(Slot slot,string key,int side)
        {
            var camera=Camera.main;
            if(!actor.profile.comicMarks||string.IsNullOrEmpty(key)||camera==null){slot.root.gameObject.SetActive(false);return;}
            if(key!=slot.key) {
                var art=System.Array.Find(library.marks,x=>x.key==key);if(art==null)return;
                slot.fill.sharedMesh=art.fill;slot.outline.sharedMesh=art.outline;slot.color.sharedMaterial=art.color;slot.border.sharedMaterial=art.border;
                slot.key=key;slot.start=Time.unscaledTime;
            }
            float age=Time.unscaledTime-slot.start;
            if(age>6){slot.start=Time.unscaledTime;age=0;}
            float duration=actor.profile.comicDuration;
            if(!previewHold&&age>duration){slot.root.gameObject.SetActive(false);return;}
            slot.root.gameObject.SetActive(true);VisibleCount++;CurrentKeys+=key+" ";
            float pop=age<.25f?Mathf.Lerp(.4f,1.18f,Mathf.Sin(age/.25f*Mathf.PI*.5f)):Mathf.Lerp(1.18f,1,Mathf.Clamp01((age-.25f)/.22f));
            float fade=previewHold?1:Mathf.Clamp01((duration-age)/.4f);
            var c=slot.color.sharedMaterial.GetColor("_BaseColor");c.a=fade;block.SetColor("_BaseColor",c);slot.color.SetPropertyBlock(block);
            c=slot.border.sharedMaterial.GetColor("_BaseColor");c.a=fade;block.SetColor("_BaseColor",c);slot.border.SetPropertyBlock(block);
            slot.root.position=head.position+camera.transform.right*(side==0?.235f:-.235f)+camera.transform.up*(verticalOffset+Mathf.Sin(age*3)*.015f)+(-camera.transform.forward)*.04f;
            slot.root.rotation=camera.transform.rotation*Quaternion.Euler(0,0,(side==0?-10:12)+Mathf.Sin(age*5)*4);
            slot.root.localScale=Vector3.one*actor.profile.comicSize*pop;
        }
        void OnDestroy(){foreach(var s in slots)if(s?.root!=null)Destroy(s.root.gameObject);}
    }
}
