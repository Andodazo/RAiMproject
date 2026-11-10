using System;
using System.Collections.Generic;
using UniVRM10;
using UnityEngine;

namespace RAiM.Companion
{
    // Small model-local two-bone solver: independent of Humanoid muscle evaluation.
    // Used both when baking real clips and after runtime upper-body offsets.
    public sealed class CompanionPoseRig
    {
        public readonly Dictionary<HumanBodyBones,Transform> Bones = new Dictionary<HumanBodyBones,Transform>();
        readonly Transform root;
        readonly Transform[] transforms;
        readonly Quaternion[] rest, previous;
        readonly Vector3 hipsRest;
        Vector3 previousHips;
        readonly Vector3 leftFoot, rightFoot;
        readonly Vector3 leftToe, rightToe;
        readonly Quaternion leftFootRotation, rightFootRotation;
        sealed class FingerBend
        {
            public Transform bone;
            public Vector3 localAxis;
            public int joint;
            public int digit;
            public bool left;
            public Quaternion restRotation;
        }
        readonly List<FingerBend> fingers = new List<FingerBend>();
        Vector3 animatedLeftFoot, animatedRightFoot, animatedLeftToe, animatedRightToe;
        Quaternion animatedLeftRotation, animatedRightRotation;
        readonly Dictionary<HumanBodyBones,Quaternion> restByBone = new Dictionary<HumanBodyBones,Quaternion>();
        readonly Quaternion[] handBases = new Quaternion[2];
        public float ChinContactError { get; private set; }
        bool captured;
        public float FootError { get; private set; }
        public CompanionPoseRig(Transform root, Vrm10Instance model)
        {
            this.root=root;
            foreach(HumanBodyBones bone in Enum.GetValues(typeof(HumanBodyBones)))
                if(bone!=HumanBodyBones.LastBone && model.TryGetBoneTransform(bone,out var t)) Bones[bone]=t;
            transforms=new Transform[Bones.Count];Bones.Values.CopyTo(transforms,0);
            rest=new Quaternion[transforms.Length];previous=new Quaternion[transforms.Length];
            for(int i=0;i<transforms.Length;i++)rest[i]=transforms[i].localRotation;
            hipsRest=Bones[HumanBodyBones.Hips].localPosition;
            leftFoot=root.InverseTransformPoint(Bones[HumanBodyBones.LeftFoot].position);
            rightFoot=root.InverseTransformPoint(Bones[HumanBodyBones.RightFoot].position);
            leftToe=root.InverseTransformPoint(Bones[HumanBodyBones.LeftToes].position);
            rightToe=root.InverseTransformPoint(Bones[HumanBodyBones.RightToes].position);
            leftFootRotation=Quaternion.Inverse(root.rotation)*Bones[HumanBodyBones.LeftFoot].rotation;
            rightFootRotation=Quaternion.Inverse(root.rotation)*Bones[HumanBodyBones.RightFoot].rotation;
            CacheFingerAxes(true);
            CacheFingerAxes(false);
            foreach (var pair in Bones) restByBone[pair.Key] = pair.Value.localRotation;
        }
        void CacheFingerAxes(bool left)
        {
            var hand = Bones[left ? HumanBodyBones.LeftHand : HumanBodyBones.RightHand];
            var starts = left
                ? new[] { HumanBodyBones.LeftIndexProximal, HumanBodyBones.LeftMiddleProximal, HumanBodyBones.LeftRingProximal, HumanBodyBones.LeftLittleProximal }
                : new[] { HumanBodyBones.RightIndexProximal, HumanBodyBones.RightMiddleProximal, HumanBodyBones.RightRingProximal, HumanBodyBones.RightLittleProximal };
            if (!Bones.TryGetValue(starts[0], out var index) || !Bones.TryGetValue(starts[1], out var middle)
                || !Bones.TryGetValue(starts[3], out var little)
                || !Bones.TryGetValue(left ? HumanBodyBones.LeftThumbProximal : HumanBodyBones.RightThumbProximal, out var thumb)) return;
            // Determine the palmar side from the imported rest geometry. Left/right
            // names do not define rotation signs after VRM coordinate conversion.
            var palm = Vector3.Cross(middle.position - hand.position, little.position - index.position).normalized;
            if (Vector3.Dot(palm, thumb.position - hand.position) < 0) palm = -palm;
            handBases[left ? 0 : 1] = Quaternion.LookRotation(hand.InverseTransformDirection(palm), hand.InverseTransformDirection(middle.position - hand.position));
            for (int digit = 0; digit < starts.Length; digit++)
            {
                var start = starts[digit];
                for (int joint = 0; joint < 3; joint++)
                {
                    if (!Bones.TryGetValue((HumanBodyBones)((int)start + joint), out var bone)) continue;
                    Vector3 direction;
                    if (joint < 2 && Bones.TryGetValue((HumanBodyBones)((int)start + joint + 1), out var next)) direction = next.position - bone.position;
                    else if (joint == 2 && Bones.TryGetValue((HumanBodyBones)((int)start + 1), out var prior)) direction = bone.position - prior.position;
                    else continue;
                    var axis = Vector3.Cross(direction.normalized, palm).normalized;
                    if (axis.sqrMagnitude < .5f) continue;
                    fingers.Add(new FingerBend { bone = bone, joint = joint, digit = digit, left = left, restRotation = bone.localRotation, localAxis = bone.InverseTransformDirection(axis) });
                }
            }
        }
        public void ResetRest()
        {
            for(int i=0;i<transforms.Length;i++)transforms[i].localRotation=rest[i];
            Bones[HumanBodyBones.Hips].localPosition=hipsRest;
        }
        public void CaptureBase()
        {
            for(int i=0;i<transforms.Length;i++)previous[i]=transforms[i].localRotation;
            previousHips=Bones[HumanBodyBones.Hips].localPosition;captured=true;
            animatedLeftFoot=root.InverseTransformPoint(Bones[HumanBodyBones.LeftFoot].position);
            animatedRightFoot=root.InverseTransformPoint(Bones[HumanBodyBones.RightFoot].position);
            animatedLeftToe=root.InverseTransformPoint(Bones[HumanBodyBones.LeftToes].position);
            animatedRightToe=root.InverseTransformPoint(Bones[HumanBodyBones.RightToes].position);
            animatedLeftRotation=Quaternion.Inverse(root.rotation)*Bones[HumanBodyBones.LeftFoot].rotation;
            animatedRightRotation=Quaternion.Inverse(root.rotation)*Bones[HumanBodyBones.RightFoot].rotation;
        }
        public void RestoreBase()
        {
            if(!captured)return;
            for(int i=0;i<transforms.Length;i++)transforms[i].localRotation=previous[i];
            Bones[HumanBodyBones.Hips].localPosition=previousHips;captured=false;
        }
        public void Rotate(HumanBodyBones bone,Vector3 angles)
        {if(Bones.TryGetValue(bone,out var t))t.localRotation*=Quaternion.Euler(angles);}
        public void Hips(Vector3 offset,Vector3 rotation)
        {Bones[HumanBodyBones.Hips].position+=root.TransformVector(offset);Rotate(HumanBodyBones.Hips,rotation);}
        public Vector3 Hand(bool left)=>root.InverseTransformPoint(Bones[left?HumanBodyBones.LeftHand:HumanBodyBones.RightHand].position);
        public Vector3 ToLocal(Vector3 world)=>root.InverseTransformPoint(world);
        public void Arm(bool left,Vector3 localTarget,Vector3? localHint=null)
        {
            var upper=Bones[left?HumanBodyBones.LeftUpperArm:HumanBodyBones.RightUpperArm];
            var lower=Bones[left?HumanBodyBones.LeftLowerArm:HumanBodyBones.RightLowerArm];
            var hand=Bones[left?HumanBodyBones.LeftHand:HumanBodyBones.RightHand];
            float side=Mathf.Sign(root.InverseTransformPoint(upper.position).x);
            Solve(upper,lower,hand,root.TransformPoint(localTarget),root.TransformPoint(localHint ?? new Vector3(side*.48f,.91f,-.12f)));
        }
        public void Feet()
        {
            Solve(Bones[HumanBodyBones.LeftUpperLeg],Bones[HumanBodyBones.LeftLowerLeg],Bones[HumanBodyBones.LeftFoot],root.TransformPoint(leftFoot),root.TransformPoint(new Vector3(leftFoot.x,.5f,.6f)));
            Solve(Bones[HumanBodyBones.RightUpperLeg],Bones[HumanBodyBones.RightLowerLeg],Bones[HumanBodyBones.RightFoot],root.TransformPoint(rightFoot),root.TransformPoint(new Vector3(rightFoot.x,.5f,.6f)));
            Bones[HumanBodyBones.LeftFoot].rotation=root.rotation*leftFootRotation;
            Bones[HumanBodyBones.RightFoot].rotation=root.rotation*rightFootRotation;
            FootError=Mathf.Max(Vector3.Distance(Bones[HumanBodyBones.LeftFoot].position,root.TransformPoint(leftFoot)),Vector3.Distance(Bones[HumanBodyBones.RightFoot].position,root.TransformPoint(rightFoot)));
        }
        public void MovingFeet(Vector3 leftOffset, Vector3 rightOffset, Vector3 leftAngles, Vector3 rightAngles, bool fromAnimation = true, float authoredMotion = 1)
        {
            FootError = 0;
            MovingFoot(true, leftOffset, leftAngles, fromAnimation, authoredMotion);
            MovingFoot(false, rightOffset, rightAngles, fromAnimation, authoredMotion);
        }
        void MovingFoot(bool left, Vector3 offset, Vector3 angles, bool fromAnimation, float authoredMotion)
        {
            Vector3 home = fromAnimation ? (left ? animatedLeftFoot : animatedRightFoot) : (left ? leftFoot : rightFoot);
            Quaternion baseRotation = fromAnimation ? (left ? animatedLeftRotation : animatedRightRotation) : (left ? leftFootRotation : rightFootRotation);
            if(fromAnimation) {
                home=Vector3.Lerp(left?leftFoot:rightFoot,home,authoredMotion);
                baseRotation=Quaternion.Slerp(left?leftFootRotation:rightFootRotation,baseRotation,authoredMotion);
            }
            var delta = Quaternion.Euler(angles);
            if (angles.x > 0)
            {
                Vector3 toe = fromAnimation ? Vector3.Lerp(left?leftToe:rightToe,left ? animatedLeftToe : animatedRightToe,authoredMotion) : (left ? leftToe : rightToe);
                Vector3 lever = toe - home;
                offset += lever - delta * lever;
            }
            Vector3 target = root.TransformPoint(home + offset);
            var foot = Bones[left ? HumanBodyBones.LeftFoot : HumanBodyBones.RightFoot];
            Solve(Bones[left ? HumanBodyBones.LeftUpperLeg : HumanBodyBones.RightUpperLeg], Bones[left ? HumanBodyBones.LeftLowerLeg : HumanBodyBones.RightLowerLeg], foot,
                target, root.TransformPoint(new Vector3(home.x, .5f, .6f)));
            foot.rotation = root.rotation * delta * baseRotation;
            FootError = Mathf.Max(FootError, Vector3.Distance(foot.position, target));
        }
        public void HandShape(bool left, Vector4 closure, float thumb)
        {
            foreach (var finger in fingers)
            {
                if (finger.left != left) continue;
                float amount = Mathf.Clamp01(closure[finger.digit]);
                float degrees = finger.joint == 0 ? Mathf.Lerp(5, 76, amount) : finger.joint == 1 ? Mathf.Lerp(8, 100, amount) : Mathf.Lerp(4, 50, amount);
                finger.bone.localRotation = finger.restRotation * Quaternion.AngleAxis(degrees, finger.localAxis);
            }
            // Fold the thumb across the outside of the curled fingers, using model-local
            // landmarks rather than a mirrored Euler sign.
            var baseKey = left ? HumanBodyBones.LeftThumbProximal : HumanBodyBones.RightThumbProximal;
            var midKey = left ? HumanBodyBones.LeftThumbIntermediate : HumanBodyBones.RightThumbIntermediate;
            var tipKey = left ? HumanBodyBones.LeftThumbDistal : HumanBodyBones.RightThumbDistal;
            if (!Bones.TryGetValue(baseKey, out var b) || !Bones.TryGetValue(midKey, out var m) || !Bones.TryGetValue(tipKey, out var t)) return;
            b.localRotation=restByBone[baseKey]; m.localRotation=restByBone[midKey]; t.localRotation=restByBone[tipKey];
            var hand= Bones[left ? HumanBodyBones.LeftHand : HumanBodyBones.RightHand];
            var middle= Bones[left ? HumanBodyBones.LeftMiddleProximal : HumanBodyBones.RightMiddleProximal];
            Vector3 center=hand.InverseTransformPoint(middle.position);
            Vector3 desired=hand.TransformPoint(new Vector3(center.x * .82f, -.035f, .002f));
            var original=b.rotation;
            var targetRotation=Quaternion.FromToRotation(t.position-b.position,desired-b.position)*b.rotation;
            b.rotation=Quaternion.Slerp(original,targetRotation,Mathf.Clamp01(thumb));
        }
        public void OrientHand(bool left, Vector3 forward, Vector3 palm, float amount=1)
        {
            var hand = Bones[left ? HumanBodyBones.LeftHand : HumanBodyBones.RightHand];
            Vector3 up=root.TransformDirection(forward).normalized;
            Vector3 normal=Vector3.ProjectOnPlane(root.TransformDirection(palm),up).normalized;
            if (up.sqrMagnitude < .5f || normal.sqrMagnitude < .5f) return;
            var rotation=Quaternion.LookRotation(normal,up)*Quaternion.Inverse(handBases[left ? 0 : 1]);
            hand.rotation=Quaternion.Slerp(hand.rotation,rotation,Mathf.Clamp01(amount));
        }
        public Vector3 KnuckleCenter(bool left)
            => (Bones[left ? HumanBodyBones.LeftIndexProximal : HumanBodyBones.RightIndexProximal].position + Bones[left ? HumanBodyBones.LeftMiddleProximal : HumanBodyBones.RightMiddleProximal].position) * .5f;
        public void ThinkingContact(Vector3 chinLocal, float amount)
        {
            if (amount < .001f) { ChinContactError=0; return; }
            var head= Bones[HumanBodyBones.Head];
            Vector3 target=head.TransformPoint(chinLocal);
            OrientHand(false, new Vector3(.1f,1,.05f), new Vector3(-1,0,-.2f), amount);
            var hand=Bones[HumanBodyBones.RightHand];
            var rotation=hand.rotation;
            Vector3 desiredWrist=hand.position + target - (KnuckleCenter(false) + root.up * .012f);
            Arm(false, root.InverseTransformPoint(Vector3.Lerp(hand.position,desiredWrist,amount)),new Vector3(.3f,1.04f,.22f));
            hand.rotation=rotation;
            ChinContactError=Vector3.Distance(KnuckleCenter(false)+root.up*.012f,target);
            // The opposite palm supports the elbow, making the silhouette readable.
            var elbow=Bones[HumanBodyBones.RightLowerArm];
            // Fingers wrap behind the elbow instead of projecting sideways like a tray.
            OrientHand(true,new Vector3(.15f,0,-1),Vector3.up,amount);
            var support=Bones[HumanBodyBones.LeftHand]; var supportRotation=support.rotation;
            var middle=Bones[HumanBodyBones.LeftMiddleProximal];
            var palmCenter=(support.position+middle.position)*.5f;
            Vector3 supportTarget=elbow.position-root.up*.024f+root.forward*.025f;
            Arm(true,root.InverseTransformPoint(Vector3.Lerp(support.position,support.position+supportTarget-palmCenter,amount)),new Vector3(-.28f,.98f,.25f));
            support.rotation=supportRotation;
        }
        public void CurlFingers(float amount)
        {
            amount = Mathf.Clamp01(amount);
            BendFingers(18 * amount, 28 * amount, 16 * amount);
        }
        public void RelaxFingers() => BendFingers(8, 14, 8);
        void BendFingers(float proximal, float intermediate, float distal)
        {
            foreach (var finger in fingers)
            {
                float degrees = finger.joint == 0 ? proximal : finger.joint == 1 ? intermediate : distal;
                finger.bone.localRotation *= Quaternion.AngleAxis(degrees, finger.localAxis);
            }
        }
        public static void Solve(Transform upper,Transform lower,Transform tip,Vector3 target,Vector3 hint)
        {
            Vector3 start=upper.position;float a=Vector3.Distance(start,lower.position),b=Vector3.Distance(lower.position,tip.position);
            Vector3 direction=target-start;float distance=Mathf.Clamp(direction.magnitude,Mathf.Abs(a-b)+.0001f,a+b-.0001f);
            direction=direction.normalized;
            Vector3 bend=Vector3.ProjectOnPlane(hint-start,direction).normalized;
            if(bend.sqrMagnitude<.1f)bend=Vector3.Cross(direction,Vector3.right).normalized;
            float adjacent=(a*a+distance*distance-b*b)/(2*distance);
            Vector3 elbow=start+direction*adjacent+bend*Mathf.Sqrt(Mathf.Max(0,a*a-adjacent*adjacent));
            upper.rotation=Quaternion.FromToRotation(lower.position-start,elbow-start)*upper.rotation;
            lower.rotation=Quaternion.FromToRotation(tip.position-lower.position,target-lower.position)*lower.rotation;
        }
    }
}
