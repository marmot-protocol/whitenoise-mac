---
name: wn-mac-design-review
description: Review a requested White Noise macOS screen, flow, or UI diff for monochrome brand consistency, native Mac components and interactions, and preservation of existing behavior. Use for focused Mac design review; not as an automatic multi-agent code review or permission to run the app.
---

# White Noise Mac design review

Use [wn-mac-design](../wn-mac-design/SKILL.md) and only its task-relevant
references. Read the current user request and `AGENTS.md` first. Review-only
requests authorize inspection, not fixes, GitHub comments, builds or launches.
This skill does not invoke the iOS review cycle or independent reviewers.

## Establish evidence

Inspect the complete requested diff, including relevant new local files, and the
current issue body. Check related PRs when ownership overlaps. For a screenshot
review, distinguish what the image shows from what only code or interaction can
establish. If no running-app evidence was requested or supplied, review the source
and state that boundary; do not launch or capture the app to fill it in.

Check the [approved Mac design decisions](../../../docs/macos-ui-patterns.md#approved-mac-design-decisions) that apply to the change. Cite the affected decision and visible consequence. A future decision outside this PR is not a defect in the PR.

## Review lenses

Use the concrete IDs in the
[macOS UI patterns guide](../../../docs/macos-ui-patterns.md). Check only the
applicable patterns, rather than turning the catalog into an app-wide audit:

| Requested surface | Review against |
| --- | --- |
| Shared styling | F01–F08: semantic pairs, typography, native metrics and meaningful color exceptions |
| Shell/navigation | Organization map, N01–N09, K01–K10: iOS relationships, Mac panes, selection and command routing |
| Form/settings/inspector | G01–G08, C01–C14, S01–S08: sections versus boxes, control semantics, category/parent relationships |
| Modal/editor | P01–P07, E02–E04: task ownership, default/cancel, focus return, truthful commit and recovery |
| Conversation/media | T01–T12, D01–D08: grouping, text interaction, existing behavior, file/consent lifetime |
| Motion/feedback | M01–M10, E01–E07: native motion, bounded transitions, no animation-driven completion or lost state |

Name the violated pattern and visible consequence in a finding. A documented
Mac adaptation is not an iOS consistency defect. A common category renamed or
reparented without a Mac reason is a consistency concern. Existing source and
historical mockups are evidence of the current implementation, not automatic
design requirements.

Also check the guide's availability table against the actual deployment target,
localized copy, feature-model ownership, and required previews. Verify action and
enablement parity across menu/toolbar/context menu, account targeting, draft
retention, IME handling, and attachment lifetime where the diff affects them.
Do not label runtime behavior verified from source inspection alone or require
architectural cleanup unrelated to the diff.

Native controls should retain their existing accessibility support. Dedicated
accessibility, VoiceOver or extreme-text-size QA needs an explicit request; it is
not an automatic review stage or a pending follow-up.

## Deliver useful findings

For each verified finding, name the concrete mismatch, the affected interaction,
evidence (file/line or supplied capture), and the smallest correction within scope.
Separate product defects from optional taste and missing runtime evidence. Do not
report deliberate system-colour exceptions as monochrome violations or stale
theme mockups as requirements. Avoid duplicate findings on one shared cause.

Report when no actionable findings remain. Summarize only checks actually run.
If fixes are explicitly requested, make bounded local changes in the task worktree
and re-review changed areas; do not repeat unchanged checks or start mandatory
review rounds. Never infer commit, push, PR, build or app-operation approval.
