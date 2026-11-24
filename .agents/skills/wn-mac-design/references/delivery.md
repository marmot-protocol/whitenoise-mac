# Integration and delivery

The [macOS UI patterns guide](../../../../docs/macos-ui-patterns.md) is the
canonical design reference. Use its iOS organization mapping and pattern IDs;
this file owns repository workflow and issue context only.

## Existing boundaries

Inspect these relative to the actual task worktree; filenames are navigation aids,
not permission to edit all of them:

- `Views/Palette/WNColor.swift`, `WNNSColor.swift`: shared semantic colour pairs.
- `Views/Palette/WNAccentColorSet.swift`: identity colours, not app themes.
- `Views/Palette/WNTextStyle.swift`: legacy type ladder; adopt native text styles
  in the touched component, preserve callers until migrated.
- `Views/SidebarViews.swift`, `Views/MessengerShellView.swift`: existing shell.
- `Views/TranscriptTableView.swift`: transcript virtualization and scroll behavior.
- `Views/ComposerViews.swift`: native text input bridge and existing actions.
- `Views/Settings/AppearanceSettingsView.swift`, `Core/NativeAppearanceController.swift`:
  current appearance and language behavior.
- `Session/AccountScope.swift`, `Features/`: account lifetime and feature models.
- `Core/AppFlavor.swift`, `Config/Development.xcconfig`: development isolation.
- `Core/AttachmentHandoff.swift`: file handoff and lifetime; not UI-owned storage.

Paths above are under `whitenoise-mac/` unless starting with `Config/`.
The target is not an app-wide rewrite. Reuse actions and current data contracts.
Keep new feature state in an `@MainActor @Observable` model passed through `init`;
do not add state or features to frozen `WorkspaceState`. Every new view gets a
`#Preview` with sample data; no new computed `var …: some View` helpers.

## Issue ownership

[Tracker #1033](https://github.com/marmot-protocol/whitenoise-mac/issues/1033)
is the authoritative work order and completion tree. Its current child bodies
specify what to keep, remove and introduce, acceptance criteria, source starting
points and pattern IDs. Read current issue/PR state before implementing; historical
comments and drawings are superseded where the tracker says so.

The plan was audited against master `f0ee021` on 2026-11-24. Monochrome surfaces,
conversation grouping/delivery/timestamps (#1088), substring highlighting (#1086),
chat batch selection (#1084/#1089), message-selection exits (#1085) and group-image
creation (#1087) already exist. The refresh preserves these contracts while
replacing presentation. Open #1095–#1098 must be checked for overlap before work.
Do not treat an open design issue as proof that no implementation exists.

### Mandatory refresh work

Dependencies are in the tracker and each issue. #1035 supplies bounded shared
control/type slices; it is not a gate requiring an app-wide migration first.
Window/focus and command contracts precede a separate Settings scene. Keep old
entry points reachable until their native replacements work. #1039 owns the base
transcript presentation; coordinate overlapping message/expiry/media changes.

| Issue | Bounded ownership |
| --- | --- |
| [#1034](https://github.com/marmot-protocol/whitenoise-mac/issues/1034) | Audit and define native monochrome semantic roles |
| [#1035](https://github.com/marmot-protocol/whitenoise-mac/issues/1035) | Native shared controls and semantic typography |
| [#1101](https://github.com/marmot-protocol/whitenoise-mac/issues/1101) | Native menu commands and focused-window routing |
| [#1115](https://github.com/marmot-protocol/whitenoise-mac/issues/1115) | Native window chrome and split-view shell |
| [#1112](https://github.com/marmot-protocol/whitenoise-mac/issues/1112) | Persistent notices, errors and empty states |
| [#1116](https://github.com/marmot-protocol/whitenoise-mac/issues/1116) | Mac refresh prerequisite: Settings window context and presentation ownership |
| [#1037](https://github.com/marmot-protocol/whitenoise-mac/issues/1037) | Native chat list, existing filters and account selector |
| [#1038](https://github.com/marmot-protocol/whitenoise-mac/issues/1038) | Native conversation toolbar and contextual title |
| [#1105](https://github.com/marmot-protocol/whitenoise-mac/issues/1105) | New Chat, direct-chat choice and group creation |
| [#1106](https://github.com/marmot-protocol/whitenoise-mac/issues/1106) | Sign-in, sign-up, setup and profile chooser layouts |
| [#1036](https://github.com/marmot-protocol/whitenoise-mac/issues/1036) | Separate Settings window, category navigation and Appearance |
| [#1107](https://github.com/marmot-protocol/whitenoise-mac/issues/1107) | Profile, Profile Keys and account-action forms |
| [#1108](https://github.com/marmot-protocol/whitenoise-mac/issues/1108) | Privacy and notification preference forms |
| [#1109](https://github.com/marmot-protocol/whitenoise-mac/issues/1109) | Linked-device and security review presentations |
| [#1110](https://github.com/marmot-protocol/whitenoise-mac/issues/1110) | Data Usage and Manage Storage layouts |
| [#1111](https://github.com/marmot-protocol/whitenoise-mac/issues/1111) | Relay and advanced-settings native forms |
| [#1102](https://github.com/marmot-protocol/whitenoise-mac/issues/1102) | Composer text, reply/edit context and staged attachments |
| [#1103](https://github.com/marmot-protocol/whitenoise-mac/issues/1103) | Voice recording and dictation controls |
| [#1039](https://github.com/marmot-protocol/whitenoise-mac/issues/1039) | Transcript typography, bubble surfaces and reply presentation |
| [#1104](https://github.com/marmot-protocol/whitenoise-mac/issues/1104) | Message actions, selection and reaction popovers |
| [#1113](https://github.com/marmot-protocol/whitenoise-mac/issues/1113) | Existing rich-message cards and media states |
| [#1118](https://github.com/marmot-protocol/whitenoise-mac/issues/1118) | Emoji, sticker, GIF and poll composition tools |
| [#1040](https://github.com/marmot-protocol/whitenoise-mac/issues/1040) | Per-message expiry indicator from existing retention data |
| [#1042](https://github.com/marmot-protocol/whitenoise-mac/issues/1042) | Native chat inspector and focused information editors |
| [#1043](https://github.com/marmot-protocol/whitenoise-mac/issues/1043) | Native sidebar search, global results and Find integration |
| [#1044](https://github.com/marmot-protocol/whitenoise-mac/issues/1044) | Shared Media and Files library with safe native file presentation |
| [#1022](https://github.com/marmot-protocol/whitenoise-mac/issues/1022) | Verify/fix the original reaction picker reachability bug; coordinate message-actions integration |

### Independent follow-ups

These are outside the mandatory tracker tree and cannot block the existing
Media/Files or monochrome refresh:

- [#1100](https://github.com/marmot-protocol/whitenoise-mac/issues/1100): Later: Explore optional colour themes after the monochrome Mac refresh.
- [#1041](https://github.com/marmot-protocol/whitenoise-mac/issues/1041): Optional feature: GitHub issue and PR cards with preview consent.
- [#1114](https://github.com/marmot-protocol/whitenoise-mac/issues/1114): Mac refresh follow-up: Shared Links inventory and safe presentation.
- [#1117](https://github.com/marmot-protocol/whitenoise-mac/issues/1117): Later: Expose shared-media expiry and complete category totals.

Existing System/Light/Dark appearance remains. No theme enum, picker, persistence
or preparatory engine belongs in the refresh. The attachment projection currently
has neither a complete Links inventory nor per-attachment expiry/full category
totals. Omit unsupported adornments; do not invent a host-side crawler or cache.
Quick Look remains conditional on safe existing attachment-handoff ownership.

### Layout references

The [Figma layouts and common patterns](https://www.figma.com/design/6UkyXHp2ZioiNI7TBd5nhw)
and six images attached to the tracker/related issues are rough representations
of main window, inspector, search, Settings, editing and common patterns. They
show containment and grouping, not final control styling, fixed dimensions,
animation timing or new capabilities. Apple native components and the pattern
guide own those decisions. Images and the static preview are not repository files.

## Scope and validation

Work only in a dedicated task worktree and matching branch/folder. Keep app code
local until commit/push approval. Updating planning issues or creating these
skills is not approval to implement every issue.

Use source review, `git diff --check`, documentation/link checks, and focused
non-building checks by default. New tests need a realistic product failure,
not assertions that a view contains a certain API name. Existing CI gates remain
in force, but a skill does not authorize locally running `just test`, `just
precommit`, a build, or an app. Even `just sanity` invokes Xcode; inspect commands
before treating them as lightweight checks.

Build/run permission is separate. When explicitly authorized, use the development
flavor by default: scheme `whitenoise-mac (Production)`, configuration `Debug`,
product **White Noise Dev**, bundle ID `dev.ipf.whitenoise.mac.dev`. The scheme name
alone is misleading; configuration chooses the development identity. Verify the
current project settings. Never launch, stop, overwrite, reset, or test the user's
installed production app for design work. Do not operate a Simulator or connected
phone for a native Mac design task.

For an authorized visual check, keep it to the changed interactions, normal text
sizes, and permitted appearance/window states. Do not add accessibility QA,
VoiceOver, extreme text-size checks, or a broad matrix without explicit request.
Preserve existing accessibility semantics and native system behavior in code.
Do not routinely ask to build after a documentation or UI edit; suggest it only
to resolve a concrete uncertainty that inspection cannot settle.

Localize new product copy through the existing catalog/helpers. Use calm, precise
Mac language (Settings…, New Chat, Find in Conversation…). Keep errors persistent
and close to the relevant field/action; don't claim success before confirmation.
Retain drafts on failure and existing cancellation/consent paths. Changing a
control's location or style must not change the operation it performs.

Report the changed behavior, your actual checks, any user-reported testing, and
concrete dependencies separately. Do not invent visual acceptance or label the
user's manual testing pending. Put per-change validation in the PR description,
not new repository reports. Screenshots belong in PR attachments, not Git.
