// WidgetAnimationController.swift — port of updateAnimations() and its
// supporting per-frame accumulators in renderer/widget.js. Owns exactly the
// mutable state that has to persist frame to frame (shake/ring/Zzz timers,
// the wander walk); everything else WidgetRenderer needs is derived fresh
// from WidgetLayout's pure functions. The caller (WidgetPixelView's frame
// timer) supplies dt and the current timer/settings state each tick.
import PomoppiCore
import PomoppiSprites

public final class WidgetAnimationController {
    public private(set) var snapshot = WidgetAnimationSnapshot()

    private var shakeTime: Double = 0
    private var zFrameTime: Double = 0
    private var wanderFrameIndex: Int?

    public init() {}

    public func tick(dt: Double, state: TimerState, settings: PomoppiSettings) {
        snapshot.animClock += dt

        if state.ringing {
            shakeTime = (shakeTime + dt).truncatingRemainder(dividingBy: 320)
            if shakeTime < 80 { snapshot.shakeOffset = -1 }
            else if shakeTime < 160 { snapshot.shakeOffset = 0 }
            else if shakeTime < 240 { snapshot.shakeOffset = 1 }
            else { snapshot.shakeOffset = 0 }
            snapshot.ringTime += dt
        } else {
            snapshot.shakeOffset = 0
            shakeTime = 0
            snapshot.ringTime = 0
        }

        let isBreak = WidgetLayout.isBreak(state)
        if isBreak {
            zFrameTime += dt
            let frameCount = max(1, GeneratedSprites.zzzFrames.count)
            snapshot.zFrameIndex = Int(zFrameTime / 500) % frameCount
        } else {
            zFrameTime = 0
            snapshot.zFrameIndex = 0
        }

        // Steps once per friend pose change, not per tick, and only while a
        // session is actually running — a break is deliberately exempt even
        // while running (asleep isn't a time to be pacing), and so is idle
        // (no wandering before a session has started, request: wander only
        // once a timer is going). Every time wandering (re)starts it resets
        // to centred/dir 1/up-first rather than picking up stale state from
        // whatever a previous session left behind — that stale carryover was
        // what made the up/down step order look inverted from one session to
        // the next.
        let poseIndex = WidgetLayout.friendFrameIndex(state: state, ringTime: snapshot.ringTime, animClock: snapshot.animClock)
        let wandering = state.running && !isBreak
        if wandering {
            if snapshot.wanderX == nil {
                snapshot.wanderX = WidgetLayout.wanderMinX
                snapshot.wanderDir = 1
                snapshot.wanderUp = true
                wanderFrameIndex = nil
            }
            if let previousPose = wanderFrameIndex, poseIndex != previousPose {
                var next = snapshot.wanderX! + snapshot.wanderDir * WidgetLayout.wanderStepPx
                if next >= WidgetLayout.wanderMaxX {
                    next = WidgetLayout.wanderMaxX
                    snapshot.wanderDir = -1
                } else if next <= WidgetLayout.wanderMinX {
                    next = WidgetLayout.wanderMinX
                    snapshot.wanderDir = 1
                }
                snapshot.wanderX = next
                snapshot.wanderUp.toggle()
            }
            wanderFrameIndex = poseIndex
        } else {
            snapshot.wanderX = nil
            snapshot.wanderDir = 1
            snapshot.wanderUp = true
            wanderFrameIndex = nil
        }
    }
}
