# Harbor motion system

Harbor is a patient keeper, not a narrator or comedian. Motion should make
him feel present without competing with the envelope, the people, or the
security decision on screen.

## Character rules

- Harbor looks at the user directly or at the object he is protecting.
- His brows stay soft and level. No side-eye, smirks, or sharp brow angles.
- He moves slowly and with weight. The envelope always moves more lightly.
- Release is careful and solemn. It is never a celebration.
- Security decisions use little or no mascot motion.
- Respect Reduce Motion. Show the most informative resting frame instead.

## Core loops

### Idle

- Use: onboarding pauses, empty states, and quiet home surfaces.
- Length: 5 to 7 seconds with an irregular blink interval.
- Motion: 1.5 percent chest rise, 1 percent head rise, slow blink, and a small
  medallion follow-through.
- Repeat: continuous only while the surface is otherwise idle.

### Listening

- Use: interview prompts and moments where the app is waiting for an answer.
- Length: 1.2 seconds into a held pose.
- Motion: head turns 4 degrees, one brow softens, and whiskers follow.
- Repeat: no. Return to idle after 4 seconds.

### Waiting

- Use: long-term sealed state and pending agreement.
- Length: 1.8 seconds into the curled resting pose.
- Motion: Harbor draws the envelope under one flipper and closes his eyes.
- Repeat: the resting frame breathes at half the normal idle amplitude.

### Receive and protect

- Use: after an envelope is sealed successfully.
- Length: 2.4 seconds.
- Motion: the envelope slides in, Harbor notices it, receives it with one
  flipper, draws it to his chest, then settles around it.
- Repeat: no.

### Release

- Use: only after the release decision is complete.
- Length: 2.8 seconds.
- Motion: Harbor checks the envelope, looks at the recipient, offers it with
  both flippers, and lets it glide forward. His expression stays composed.
- Repeat: no.

### Edge peek

- Use: tips, optional explanations, and small secondary confirmations.
- Length: 0.6 seconds in, hold, 0.45 seconds out.
- Motion: head first, then one flipper. No bounce.
- Repeat: no.

## Screen placement

| Surface | Pose | Placement | Motion |
|---|---|---|---|
| Onboarding | full resting Harbor | lower third | idle, then listening |
| Empty envelope list | Harbor beside envelope | below copy | idle |
| Envelope sealed | receive and protect | centered below confirmation | one shot |
| Waiting for key holders | curled around envelope | bottom edge | half-speed breath |
| Release complete | offering envelope | centered | one shot |
| Tip or explanation | edge peek | left or right edge | one shot |
| Compact status card | head and shoulders | trailing edge | blink only |
| Security decision | none or still portrait | secondary | no loop |
| Sensitive error | still resting Harbor | below explanation | no animation |

## Production approach

The existing `SealFigure` already provides SwiftUI breathing and blinking.
The production version should extend it with a `HarborState` enum and separate
animatable layers for body, head, eyelids, brows, whiskers, front flippers,
medallion, and envelope. This avoids shipping GIFs and keeps dark mode,
resolution, accessibility, and timing under native control.

Suggested states:

```swift
enum HarborState {
    case idle
    case listening
    case waiting
    case receiving
    case protecting
    case releasing
    case edgePeek
    case still
}
```

The GIF files in this folder are timing previews only. The PNG sheets are the
visual keyframes for the native rig.
