---
name: wn-mac-design
description: Design and implement White Noise macOS UI, UX, interactions, copy, and shared components with the iOS monochrome identity and native SwiftUI/AppKit patterns. Use for Mac design-refresh work and bounded Mac interface changes, not iOS implementation or backend work.
---

# White Noise Mac design

Keep the White Noise family resemblance: monochrome controls and message surfaces,
clear hierarchy, familiar wording. Adapt the experience to a Mac with native
windows, menus, keyboard navigation, pointer interaction, and resizable layouts.
This is a native macOS app, not a Catalyst port or an enlarged iPhone screen.

## Read for the task

- Read the organization mapping and foundations in the canonical
  [macOS UI patterns guide](../../../docs/macos-ui-patterns.md), then its relevant
  entries. It specifies Apple HIG/API links, native containers and controls,
  grouping, keyboard/pointer behavior, presentation, states, motion, and fallbacks.
- Keep iOS terminology, feature categories, and content relationships. Use the
  guide's explicit Mac adaptations for windows, Settings, sidebar, inspector,
  menus and desktop input. Do not copy iPhone metrics or UIKit implementation.
- For implementation planning, read [delivery](references/delivery.md): repository
  integration, issue ownership, existing work, and permission-aware verification.
- For a requested design review, use
  [wn-mac-design-review](../wn-mac-design-review/SKILL.md) too. Ordinary implementation
  does not start a separate review workflow or authorize delegation.

## Working decisions

1. Identify one screen or bounded flow and its existing actions, state owner, and
   loading/error paths. Choose the applicable pattern IDs from the guide. Inspect
   related open work before changing shared code.
2. Use a native SwiftUI component when it fits, then AppKit for a real platform
   gap. Reuse the existing WN wrapper if it already provides that native behavior.
   Keep wrappers thin; do not build a competing design system.
3. Use the monochrome roles and Apple's text styles. No colour-theme model,
   accent picker, colour presets, theme persistence, or speculative theme engine.
4. For a material platform choice, read the current Apple HIG and API page linked
   in that pattern entry. Check the repository's actual deployment floor. An Apple
   example is not permission to replace existing account, storage, or action logic.
5. Preserve production semantics. A clearer button can invoke the same action;
   a redesign cannot silently change consent, notifications, synchronization,
   retention, keychain access, retries, or MDK ownership. Describe unavailable
   behavior as a dependency instead of presenting a working-looking placeholder.
6. Validate the actual diff using permitted checks. Do not build, launch, capture,
   or operate an app just because a skill or GitHub issue lists visual acceptance.

Before editing, resolve the container, control, content grouping, action target,
selection/commit/cancel behavior, keyboard/focus route, error/progress state, and
motion owner for the requested interaction. Native components own their motion;
custom transitions follow M01–M10. A departure from iOS organization needs a
concrete Mac benefit; a custom control needs a gap in the native component.
Explain material choices in the change description, not a new per-task report.

The current user instruction and current issue body take precedence over older
mockups and comments. The November 2026 refresh is monochrome only. Earlier
teal-accent Mono, coloured bubbles, colour blending recipes, and theme pickers are
historical references, not implementation requirements.
