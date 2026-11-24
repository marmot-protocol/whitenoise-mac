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
and its current issue bodies describe the monochrome refresh. Old images are
historical composition references; their theme colours, hand-built controls and
superseded layout details are not acceptance targets.

| Issue | Bounded ownership |
| --- | --- |
| #1034 | Monochrome semantic foundation; no visible switch, theme model, picker or preference |
| #1035 | Apply monochrome/native surfaces and shared neutral control roles; migrate touched text styles |
| #1036 | Native Settings scene/panes; Appearance and Language using existing preferences, no colour themes |
| #1037 | Native sidebar, account selector, list, search placement/filter context; shell menu routing |
| #1038 | Native conversation toolbar/title/retention summary |
| #1039 | Transcript grouping, metadata, reply quotes and reactions; may be split |
| #1040 | Expiry presentation from existing message retention data |
| #1041 | GitHub cards as a separately scoped feature, including consent-gated requests |
| #1042 | Native chat inspector and Conversation commands, existing actions only |
| #1043 | Search result presentation and Edit > Find integration |
| #1044 | Shared media inspector content, links, file presentation, compatible previews |

Tracker #1033 and children #1034–#1044 were aligned with this guide on 2026-11-24.
In particular, #1036 now specifies a native category sidebar inside the separate
Settings window, preserving iOS relationships and supported Mac-only categories.
`TabView` remains appropriate for a small settings surface, not every category
in one horizontal strip.

The [Figma layouts and common patterns](https://www.figma.com/design/6UkyXHp2ZioiNI7TBd5nhw)
contain six high-level review proposals: main window, chat inspector, search,
Settings, edit sheet, and common patterns. Each issue links its relevant frames.
Use these for containment and grouping, not exact dimensions, final control
styling, animation timing, or permission to add capabilities. Native components
and the detailed pattern guide own implementation decisions.

Read live issue/PR state before implementation. At preparation time, draft
[PR #1088](https://github.com/marmot-protocol/whitenoise-mac/pull/1088) overlaps
#1039 and #1038 (grouping, delivery indicators, timestamps and retention summary).
Inspect its current diff before duplicating work; issue-open status alone does
not prove that no code exists. #1022 is the reported reaction popover reachability
bug, not a theme task.

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
