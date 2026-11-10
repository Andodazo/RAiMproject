using System;
using System.Collections.Generic;
using UniVRM10;
using UnityEngine;

namespace RAiM.Companion
{
    // A conservative avatar-sized torso envelope. Applied after animation mixing,
    // so crossfades cannot interpolate an otherwise safe forearm through the chest.
    // Joint lengths, finger curves and world-space hand orientation are preserved.
    public sealed class CompanionArmClearance
    {
        readonly CompanionPoseRig rig;
        readonly Transform chest;
        readonly Quaternion restBasis;
        float minY,maxY,step;
        readonly Vector3[] sections=new Vector3[36]; // half width, back Z, front Z
        readonly List<Vector3> probes=new List<Vector3>(16);
        sealed class TorsoPoint {public Transform[] bones;public Vector3[] local;public float[] weights;}
        readonly List<TorsoPoint> torsoPoints=new List<TorsoPoint>();
        Quaternion basis,inverse;
        readonly Vector3[] elbowOffset=new Vector3[2];
        readonly Vector3[] wristOffset=new Vector3[2];
        readonly bool[] hasPrevious=new bool[2];
        float delta;
        bool live;
        readonly Quaternion[] runtimeSource=new Quaternion[6];
        readonly Quaternion[] displayedPose=new Quaternion[6];
        bool displayedPoseReady;
        readonly Quaternion[] correction={Quaternion.identity,Quaternion.identity,Quaternion.identity,Quaternion.identity,Quaternion.identity,Quaternion.identity};
        readonly HumanBodyBones[] armBones={HumanBodyBones.LeftUpperArm,HumanBodyBones.LeftLowerArm,HumanBodyBones.LeftHand,HumanBodyBones.RightUpperArm,HumanBodyBones.RightLowerArm,HumanBodyBones.RightHand};
        public float MaxWristAdjustment {get;private set;}
        public float RemainingPenetration {get;private set;}
        public CompanionArmClearance(Transform root,CompanionPoseRig rig,Vrm10Instance model)
        {
            this.rig=rig;chest=rig.Bones[HumanBodyBones.Chest];
            restBasis=Quaternion.Inverse(chest.rotation)*root.rotation;
            UpdateBasis();
            minY=Local(rig.Bones[HumanBodyBones.Hips].position).y-.16f;
            maxY=Local(rig.Bones[HumanBodyBones.Neck].position).y-.035f;
            step=(maxY-minY)/(sections.Length-1);
            var trunk=new HashSet<Transform>{rig.Bones[HumanBodyBones.Hips],rig.Bones[HumanBodyBones.Spine],chest};
            if(rig.Bones.TryGetValue(HumanBodyBones.UpperChest,out var upper))trunk.Add(upper);
            var points=new List<Vector3>();var baked=new Mesh();
            foreach(var skin in model.GetComponentsInChildren<SkinnedMeshRenderer>()) {
                var weights=skin.sharedMesh.boneWeights;if(weights.Length==0)continue;
                var bind=skin.sharedMesh.bindposes;var restVertices=skin.sharedMesh.vertices;
                skin.BakeMesh(baked,true);var vertices=baked.vertices;
                for(int i=0;i<vertices.Length;i++) {
                    var w=weights[i];float total=0;
                    if(trunk.Contains(skin.bones[w.boneIndex0]))total+=w.weight0;
                    if(trunk.Contains(skin.bones[w.boneIndex1]))total+=w.weight1;
                    if(trunk.Contains(skin.bones[w.boneIndex2]))total+=w.weight2;
                    if(trunk.Contains(skin.bones[w.boneIndex3]))total+=w.weight3;
                    if(total>.65f) {
                        points.Add(Local(skin.transform.TransformPoint(vertices[i])));
                        var ids=new[]{w.boneIndex0,w.boneIndex1,w.boneIndex2,w.boneIndex3};
                        var sample=new TorsoPoint{bones=new Transform[4],local=new Vector3[4],weights=new[]{w.weight0,w.weight1,w.weight2,w.weight3}};
                        for(int k=0;k<4;k++){sample.bones[k]=skin.bones[ids[k]];sample.local[k]=bind[ids[k]].MultiplyPoint3x4(restVertices[i]);}
                        torsoPoints.Add(sample);
                    }
                }
            }
            if(Application.isPlaying)UnityEngine.Object.Destroy(baked);else UnityEngine.Object.DestroyImmediate(baked);
            for(int j=0;j<sections.Length;j++) {
                float y=minY+j*step,x=.065f,back=0,front=0;int found=0;
                foreach(var p in points)if(Mathf.Abs(p.y-y)<step*1.6f){x=Mathf.Max(x,Mathf.Abs(p.x));back=Mathf.Min(back,p.z);front=Mathf.Max(front,p.z);found++;}
                sections[j]=found>0?new Vector3(x+.006f,back-.006f,front+.006f):new Vector3(.10f,-.065f,.085f);
            }
        }
        void UpdateEnvelope()
        {
            // Track the torso skin through bends/twists, instead of moving a rigid
            // chest-sized collider over an independently moving abdomen and hips.
            minY=Local(rig.Bones[HumanBodyBones.Hips].position).y-.16f;
            maxY=Local(rig.Bones[HumanBodyBones.Neck].position).y-.035f;step=(maxY-minY)/(sections.Length-1);
            for(int j=0;j<sections.Length;j++)sections[j]=new Vector3(.065f,0,0);
            foreach(var sample in torsoPoints) {
                Vector3 world=Vector3.zero;for(int k=0;k<4;k++)if(sample.weights[k]>.0001f)world+=sample.bones[k].TransformPoint(sample.local[k])*sample.weights[k];
                var p=Local(world);int middle=Mathf.RoundToInt((p.y-minY)/step);
                for(int j=Mathf.Max(0,middle-2);j<=Mathf.Min(sections.Length-1,middle+2);j++) {
                    var s=sections[j];s.x=Mathf.Max(s.x,Mathf.Abs(p.x)+.008f);s.y=Mathf.Min(s.y,p.z-.008f);s.z=Mathf.Max(s.z,p.z+.008f);sections[j]=s;
                }
            }
            for(int j=0;j<sections.Length;j++)if(sections[j].z-sections[j].y<.04f)sections[j]=new Vector3(.10f,-.065f,.085f);
        }
        void UpdateBasis(){basis=chest.rotation*restBasis;inverse=Quaternion.Inverse(basis);}
        Vector3 Local(Vector3 p)=>inverse*(p-chest.position);
        Vector3 World(Vector3 p)=>chest.position+basis*p;
        bool Section(Vector3 local,out Vector3 s,out float zCenter)
        {
            s=Vector3.zero;zCenter=0;
            float f=(Mathf.Clamp(local.y,minY,maxY)-minY)/step;int i=Mathf.Min((int)f,sections.Length-2);
            s=Vector3.Lerp(sections[i],sections[i+1],f-i);zCenter=(s.y+s.z)*.5f;return true;
        }
        float Clearance(Vector3 world,float radius)
        {
            var p=Local(world);if(!Section(p,out var s,out float center))return 1;
            float a=s.x,b=Mathf.Max(.025f,(s.z-s.y)*.5f),x=Mathf.Abs(p.x/a),z=Mathf.Abs((p.z-center)/b);
            // A rounded rectangle covers breasts/abdomen more faithfully than a thin ellipse.
            float rho=Mathf.Pow(x*x*x*x+z*z*z*z,.25f);
            float vertical=Mathf.Max(minY-p.y,p.y-maxY);
            return Mathf.Max((rho-1)*Mathf.Min(a,b),vertical)-radius;
        }
        Vector3 Outside(Vector3 world,float radius)
        {
            var p=Local(world);if(Clearance(world,radius)>=0)return world;Section(p,out var s,out float center);
            var vertical=p;vertical.y=p.y<(minY+maxY)*.5f?minY-radius:maxY+radius;
            float a=s.x,b=Mathf.Max(.025f,(s.z-s.y)*.5f),x=p.x/a,z=(p.z-center)/b;
            float rho=Mathf.Pow(x*x*x*x+z*z*z*z,.25f),required=1+radius/Mathf.Min(a,b);
            if(rho>=required)return world;
            if(rho<.01f)p.z=center+b*required;
            else {p.x*=required/rho;p.z=center+(p.z-center)*required/rho;}
            return Vector3.Distance(World(vertical),world)<Vector3.Distance(World(p),world)?World(vertical):World(p);
        }
        float ArmClearance(Vector3 shoulder,Vector3 elbow,Vector3 wrist)
        {
            float value=1;
            // The first third of the upper arm meets the shoulder by construction.
            // The shoulder blend belongs to both arm and torso. Treating it as a
            // separate capsule produces impossible constraints and elbow flips.
            for(int i=0;i<=8;i++)value=Mathf.Min(value,Clearance(Vector3.Lerp(elbow,wrist,i/8f),Mathf.Lerp(.034f,.028f,i/8f)));
            return value;
        }
        public void Reset(){hasPrevious[0]=hasPrevious[1]=false;displayedPoseReady=false;for(int i=0;i<correction.Length;i++)correction[i]=Quaternion.identity;}
        public void ApplyRuntime(float dt)
        {
            var source=runtimeSource;for(int i=0;i<6;i++)source[i]=rig.Bones[armBones[i]].localRotation;
            live=true;Apply(dt);live=false;
            for(int i=0;i<6;i++) {
                var bone=rig.Bones[armBones[i]];var offset=bone.localRotation*Quaternion.Inverse(source[i]);
                correction[i]=Quaternion.Slerp(correction[i],offset,1-Mathf.Exp(-dt*18));
                var target=correction[i]*source[i];
                // Stabilize the final displayed pose, including noise already in
                // the retargeted track. Large intentional strokes respond faster.
                float response=Mathf.Lerp(14,28,Mathf.SmoothStep(0,1,(Quaternion.Angle(displayedPose[i],target)-5)/20));
                displayedPose[i]=displayedPoseReady?Quaternion.Slerp(displayedPose[i],target,1-Mathf.Exp(-dt*response)):target;
                bone.localRotation=displayedPose[i];
            }
            displayedPoseReady=true;
        }
        public void Apply(float dt=1f/30)
        {
            delta=dt;UpdateBasis();UpdateEnvelope();MaxWristAdjustment=0;RemainingPenetration=0;Correct(true);Correct(false);
        }
        void Correct(bool left)
        {
            var shoulder=rig.Bones[left?HumanBodyBones.LeftUpperArm:HumanBodyBones.RightUpperArm];
            var elbow=rig.Bones[left?HumanBodyBones.LeftLowerArm:HumanBodyBones.RightLowerArm];
            var hand=rig.Bones[left?HumanBodyBones.LeftHand:HumanBodyBones.RightHand];
            Vector3 s=shoulder.position,e=elbow.position,original=hand.position,w=original;
            int side=left?0:1;
            Vector3 preferred=e+(hasPrevious[side]?elbowOffset[side]*Mathf.Exp(-delta*15):Vector3.zero);
            if(hasPrevious[side])w+=wristOffset[side]*Mathf.Exp(-delta*10);
            var rotation=hand.rotation;
            float a=Vector3.Distance(s,e),b=Vector3.Distance(e,w);
            probes.Clear();probes.Add(Vector3.zero);
            var first=left?HumanBodyBones.LeftIndexProximal:HumanBodyBones.RightIndexProximal;
            for(int digit=0;digit<4;digit++)for(int joint=0;joint<3;joint++) {
                var key=(HumanBodyBones)((int)first+digit*3+joint);
                if(rig.Bones.TryGetValue(key,out var bone))probes.Add(bone.position-original);
            }
            foreach(var key in left?new[]{HumanBodyBones.LeftThumbProximal,HumanBodyBones.LeftThumbIntermediate,HumanBodyBones.LeftThumbDistal}:new[]{HumanBodyBones.RightThumbProximal,HumanBodyBones.RightThumbIntermediate,HumanBodyBones.RightThumbDistal})
                if(rig.Bones.TryGetValue(key,out var thumb))probes.Add(thumb.position-original);
            if(live) {
                float distance=ArmClearance(s,e,original);
                foreach(var probe in probes)distance=Mathf.Min(distance,Clearance(original+probe,.014f));
                // Baked safe poses need no second projection. A 5mm dead band in
                // the padded envelope prevents a contact boundary from chattering.
                if(distance>-.005f){elbowOffset[side]=wristOffset[side]=Vector3.zero;hasPrevious[side]=false;return;}
            }
            for(int pass=0;pass<3;pass++) {
                Vector3 push=Vector3.zero;
                foreach(var probe in probes){var d=Outside(w+probe,.014f)-(w+probe);if(d.sqrMagnitude>push.sqrMagnitude)push=d;}
                w+=push;w=s+Vector3.ClampMagnitude(w-s,a+b-.002f);
            }
            Vector3 best=e;float bestClear=-1;
            for(int move=0;move<18;move++) {
                Vector3 axis=(w-s).normalized;float d=Mathf.Clamp(Vector3.Distance(w,s),Mathf.Abs(a-b)+.001f,a+b-.001f);
                float along=(a*a+d*d-b*b)/(2*d),height=Mathf.Sqrt(Mathf.Max(0,a*a-along*along));
                Vector3 center=s+axis*along,radial=Vector3.ProjectOnPlane(e-center,axis).normalized*height;
                if(radial.sqrMagnitude<.00001f)radial=Vector3.Cross(axis,basis*Vector3.up).normalized*height;
                best=center+radial;bestClear=ArmClearance(s,best,w);float bestAngle=0;
                if(bestClear<0||Vector3.Distance(preferred,e)>.001f) {
                    bool safe=false;
                    float score=float.PositiveInfinity;
                    for(int degrees=-180;degrees<=180;degrees+=4) {
                        var candidate=center+Quaternion.AngleAxis(degrees,axis)*radial;
                        float clear=ArmClearance(s,candidate,w);
                        if(!safe&&clear>bestClear){bestClear=clear;best=candidate;bestAngle=degrees;}
                        float cost=(candidate-preferred).sqrMagnitude;
                        if(clear>=0&&cost<score){best=candidate;bestAngle=degrees;bestClear=clear;safe=true;score=cost;}
                    }
                    if(safe) {
                        for(float sub=bestAngle-4;sub<=bestAngle+4;sub+=.25f){var candidate=center+Quaternion.AngleAxis(sub,axis)*radial;float clear=ArmClearance(s,candidate,w);float cost=(candidate-preferred).sqrMagnitude;if(clear>=0&&cost<score){best=candidate;bestClear=clear;score=cost;}}
                    }
                }
                // Preserve the current elbow branch. Move the hand around the
                // obstruction before allowing a large jump to a distant orbit.
                if((bestClear>=-.001f&&Vector3.Distance(best,preferred)<.055f)||move==17)break;
                // Only when the wrist itself traps the forearm, move it gently away
                // from the torso. Chin contacts above the torso keep their target.
                var local=Local(w);Section(local,out var section,out float middleZ);
                Vector3 outward=new Vector3(local.x,0,local.z-middleZ).normalized;
                Vector3 shift=basis*outward*.012f;
                w=s+Vector3.ClampMagnitude(w+shift-s,a+b-.002f);
            }
            if((w-original).sqrMagnitude>.00000001f||Vector3.Distance(e,best)>.0001f) {
                rig.Arm(left,rig.ToLocal(w),rig.ToLocal(best));hand.rotation=rotation;
            }
            MaxWristAdjustment=Mathf.Max(MaxWristAdjustment,Vector3.Distance(original,hand.position));
            RemainingPenetration=Mathf.Max(RemainingPenetration,-ArmClearance(s,elbow.position,hand.position));
            elbowOffset[side]=elbow.position-e;hasPrevious[side]=true;
            wristOffset[side]=hand.position-original;
        }
    }
}
