# White Noise macOS UI patterns

**Apple's macOS Human Interface Guidelines and public SwiftUI/AppKit components
are the interface standard. White Noise keeps its iOS monochrome identity,
terminology, feature organization, and content hierarchy.** Adapt the container
and interaction where the Mac benefits: resizable windows, persistent panes,
menu commands, keyboard focus, pointer interaction, and native presentations.

This is the implementation reference for the design refresh, not a description
of everything already implemented. Existing screenshots, wrappers, and issue
mockups can contain departures from this target. The decisions below are White
Noise's application of Apple's guidance; Apple does not prescribe our bubble
palette, feature order, or product behavior. Use public controls rather than
reverse-engineering private implementations in Messages, Mail, Notes, or Settings.

Reference baseline: Mac `e2a6a00`, iOS `b4bd66bc`; Apple documentation consulted
2026-11-24. The Mac deployment floor is **15.6**. Check the current project and the
exact API overload before implementation; a current SDK example may require a
newer OS. A design reference never grants build, app-operation, or publication
permission. Follow [AGENTS.md](../AGENTS.md).

For high-level composition, see the
[Figma layouts and common patterns](https://www.figma.com/design/6UkyXHp2ZioiNI7TBd5nhw):
main window, chat inspector, search, Settings, edit sheet, and common patterns.
These are review proposals for containment and grouping, not final visual
approval, exact metrics, or new feature requirements. The guide below specifies
the detailed native behavior. The updated
[refresh tracker](https://github.com/marmot-protocol/whitenoise-mac/issues/1033)
and child issues link the relevant frames.

## Find a pattern

- [iOS organization and Mac adaptations](#ios-organization-and-mac-adaptations)
- [Foundations and monochrome roles](#foundations-and-monochrome-roles) — F01–F08
- [Windows, navigation, and toolbars](#windows-navigation-and-toolbars) — N01–N09
- [Sections, groups, and content layout](#sections-groups-and-content-layout) — G01–G08
- [Buttons, choices, and text input](#buttons-choices-and-text-input) — C01–C14
- [Menus, keyboard, pointer, and focus](#menus-keyboard-pointer-and-focus) — K01–K10
- [Sheets, popovers, alerts, and panels](#sheets-popovers-alerts-and-panels) — P01–P07
- [Chat list, transcript, and composer](#chat-list-transcript-and-composer) — T01–T12
- [Settings, identity, and chat information](#settings-identity-and-chat-information) — S01–S08
- [Files, media, and system experiences](#files-media-and-system-experiences) — D01–D08
- [Feedback, progress, and recovery](#feedback-progress-and-recovery) — E01–E07
- [Transitions and animation](#transitions-and-animation) — M01–M10
- [API availability and native fallbacks](#api-availability-and-native-fallbacks)
- [Source map and implementation decisions](#source-map-and-implementation-decisions)

Read the organization and foundations first, then the relevant pattern entries.
Each ID is a stable review reference. Follow the linked HIG for the design and
the API link for actual behavior; a type name alone does not specify the UX.

## iOS organization and Mac adaptations

The pinned [iOS design guide][ios-design], [Settings][ios-settings],
[Group Details][ios-group], and [User Profile][ios-profile] establish the family
structure. They are source references, not a claim about the latest shipped app.
An iOS-only feature does not become a Mac requirement merely by appearing here.
Preserve supported Mac capabilities and their existing account/app scope.

| Area | Keep aligned with iOS | Explicit Mac adaptation |
| --- | --- | --- |
| Main experience | Chats → selected conversation → information about that conversation. Keep chat names, previews, unread meaning, drafts, and available filters recognizable. | Native sidebar beside transcript; optional trailing inspector. No phone tab bar, full-screen push for each chat, or swipe-only route. |
| Identity | Profile identity, public identifiers, sharing, profile switching, and Add Profile remain related. Keep the active identity obvious before an account-scoped action. | Compact account `Menu`/`Picker` in the sidebar; account actions remain reachable in Settings. Do not create another runtime for a Settings window. |
| Settings categories | Profile, Profile Keys, Notifications, Appearance, Privacy & Security, Data Usage, Manage Storage, Relays, AI Agents, then support/Donate/Developer Tools; preserve categories only where the Mac has the feature. | Separate `Settings` scene. For the current large category inventory, use a native category sidebar and grouped forms (S01), preserving this relative order. The explicit order is Profile, Profile Keys, Devices, Notifications, Appearance, Privacy & Security, Data Usage, Relays, AI Agents, Preferences, Support, Donate, Developer Tools, subject to existing capability gates. No settings takeover of the chat transcript. |
| Mac-only settings | Retain existing Devices, startup/window Preferences, and capability-gated tools. | Devices follows Profile Keys. Put Mac startup/window options in Preferences after the shared feature categories; keep nested technical tools under Developer Tools. Never invent iOS equivalents. |
| Nested settings | Blocked Users belongs to Privacy & Security; technical key packages and quarantine tools belong to Developer Tools. | Retain those parent relationships in selection/breadcrumbs. Manage Storage stays nested under Data Usage. Rename the existing Storage category to Data Usage and Developer mode category to Developer Tools as localized copy changes using separate keys; retain Storage section headings, the Developer mode preference and all stored values unchanged. Do not change its persistence scope to match a category name. |
| Destructive account actions | Keep Delete Profile, Sign Out, and Erase App Data distinct by object, scope, and confirmation. | Separate terminal action section associated with the active profile. An all-device-data action stays with privacy/device-data controls where already supported, never masquerades as Sign Out. |
| Group information | Identity → meaningful status → quick actions → shared content → chat settings → members → advanced information → destructive actions. Keep available moderation/developer capabilities gated. | Trailing inspector with `Form`/`Section`; frequent actions also in toolbar/Conversation menu. Editors open a sheet from the inspector. Status requiring a decision stays near identity, not buried below members. |
| Direct chat information | Person identity, About/contact actions, Shared in Chat, Chat Actions. Distinguish the person from the conversation. | Inspector for conversation information; a member/person detail destination preserves a return route to the originating group. No grid of enlarged phone action tiles. |
| Profile editing | Identity and privacy explanation → named editable fields → validation → Save/Cancel. Preserve the draft and existing visibility/consent statements. | Native fields and aligned form rows in a bounded sheet or Settings pane. No phone keyboard-dismiss backdrop gesture or compulsory full-width pill buttons. |
| Shared content | Preserve current Media/Files, chronology, and the selected chat. Links needs the separately scoped data contract in D04. | Inspector section leads to a larger library when needed; native segmented category choice and grid/list. Keep the transcript reachable and restore selection when returning. |
| Conversation content | Same sender, reply, reaction, delivery, retention, and failure meanings; same monochrome relationship between sent and received. | Desktop typography/density, selectable text, contextual commands, native scrolling and Find. Do not copy iPhone dimensions or touch overlay gestures. |
| Onboarding | Same supported sequence, decisions, terminology, consent, and recovery. | Content-sized window steps with native controls and explicit Back/Continue/Cancel where supported; no simulated phone frame, pagination dots, or forced full-screen wizard. |

**Structure rule:** retain the iOS category/content relationship unless a specific
Mac container or interaction makes a different structure useful. The exceptions
above are intentional. For a new exception, name the iOS relationship, the Mac
replacement, and the benefit in the change description; do not introduce an
unrelated information architecture under the label “native.” This concerns UI
organization, not mirroring iOS source directories or changing Mac architecture.

## Foundations and monochrome roles

Apple references: [Designing for macOS][h-mac], [Layout][h-layout],
[Color][h-color], [Dark Mode][h-dark], [Typography][h-type],
[Materials][h-materials], [SF Symbols][h-symbols], [Accessibility][h-accessibility].

| ID / decision | White Noise rule and API |
| --- | --- |
| **F01 — One brand palette** | Monochrome in both light and dark. No teal accent, colored outgoing bubbles, color presets, theme selector, theme model, or unused theme persistence. Keep the existing System/Light/Dark preference and saved selection; default System. Call it Appearance. iOS [button][ios-button] and [bubble palette][ios-bubbles] establish the relationship, not the Mac metrics. |
| **F02 — Semantic surface pairs** | Use the role table below through existing `WNColor`/`WNNSColor` owners. Keep each custom surface and foreground together. Use [NSColor UI element colors][a-colors]; do not scatter literal grays, opacity recipes, or per-screen appearance branches. |
| **F03 — Native materials** | Let the window, sidebar, toolbar, menus, sheets, and inspector draw their own material. Content forms, transcript, cards, and fields inside cards stay content surfaces. No material on every rectangle, nested glass, custom blur behind native chrome, or extra glass circle behind a toolbar glyph. See [Material][a-material] and the availability table for Liquid Glass. |
| **F04 — Type hierarchy** | Use [Font][a-font] semantic styles or `NSFont.preferredFont(forTextStyle:)`: `.body` for messages/ordinary reading, `.headline` for chat/section emphasis, `.subheadline`/`.caption` for supporting metadata, `.title3` for a standalone content heading. Native labels/controls keep their own font. Do not copy the legacy fixed `WNTextStyle` ladder or apply one font to a whole Form. Use `.monospacedDigit()` only for changing time/count alignment; keys may use monospaced text. |
| **F05 — Density and spacing** | Native controls own height, internal padding, baseline, focus ring, and shape. Use `.controlSize(.regular)` by default; `.small` for compact inspector accessories, never `.mini` for primary reading/action paths. Let `Form`, `List`, `Grid`, `.scenePadding()` and native toolbars own their spacing. Reuse existing composition metrics for bubbles/avatars; no universal iOS 44/50-point height, 20-point card inset, invented Apple spacing scale, or fixed screen-width layout. |
| **F06 — Symbols and identity** | Use [Label][a-label] and SF Symbols for actions; prefer `square.and.pencil` for New Chat, `magnifyingglass` for search, `sidebar.left` for sidebar visibility, `info.circle` for information, `ellipsis` for more, `paperclip` for attachments. Verify the exact symbol's deployment availability. Keep labels in menus and `.help` for icon-only controls. Do not draw circular borders into every symbol. Photos/initials/brand artwork retain their existing owners and identity assignments. |
| **F07 — Meaning and state** | Keep system focus/selection/find/link colors, semantic destructive/error colors, avatar colors, media, and emoji. Monochrome is the app identity, not a pixel-level ban on color. Keep native names, values, roles, focus, disabled/pressed drawing, Reduce Motion and transparency behavior. Do not remove semantics while restyling. This is an implementation rule, not authorization for dedicated accessibility QA. |
| **F08 — Copy and localization** | Match iOS feature names and consequence language; adapt physical actions to Mac (“click”, keyboard shortcuts, “this Mac”) where needed. Use concise action verbs and visible field labels. Localize through the existing catalog and helpers. Never copy iPhone-specific permissions text or promise an unsupported action. [Writing][h-writing] and [Labels][h-labels]. |

| Surface / state | Native Mac mapping |
| --- | --- |
| Window / reading surface | `NSColor.windowBackgroundColor` / `controlBackgroundColor`; native containers may supply these themselves. |
| Sidebar / toolbar / inspector | System container material and chrome, including active/inactive window changes. |
| Primary brand control | Black in light appearance, white in dark, opposite foreground; tint only the intended control. Keep native disabled/pressed rendering. |
| Sent bubble | Neutral dark fill/light text in light appearance; neutral light fill/dark text in dark. Pair all text, symbols, links, metadata, quotes, and selection with that surface. |
| Received bubble | `NSColor.secondarySystemFill` with `labelColor` over the transcript surface. This is our semantic Mac translation of iOS gray, not an Apple-prescribed message color. |
| Secondary action in content | Neutral native `.bordered`/standard AppKit button with normal text; destructive role/text when applicable. Never black-tinted outline or glass inside a card. |
| Main / supporting / placeholder text | `labelColor`, `secondaryLabelColor`, `tertiaryLabelColor`, `placeholderTextColor`; outgoing-bubble metadata instead derives from the paired bubble foreground. |
| Dividers | Native separators or `separatorColor`; no decorative outline around every group. |
| Selection / focus / find | Native selection including inactive state; `keyboardFocusIndicatorColor` and `findHighlightColor` where bridging AppKit. Do not replace these with branding. |
| Links / status | Native link semantics and `linkColor` where legible; system error/destructive meaning plus text/symbol. An inverted bubble needs its own readable link treatment. |
| Switch on-state | Neutral tint only when it preserves thumb and state contrast; use a neutral gray instead of white when white would erase the native white thumb in dark appearance. |

Keep appearance changes to colors/materials. They must not change layout,
spacing, font sizes, or control placement. Preserve necessary neutral overlays on
media. Do not change avatar hashing to copy iOS; [identity color][ios-identity]
is distinct from app theming. The [iOS gray button][ios-gray] is the semantic
reference for secondary actions, not an instruction to import UIKit.

## Windows, navigation, and toolbars

| ID / pattern | Use in White Noise; interaction contract | Apple guidance / public API |
| --- | --- | --- |
| **N01 — Main window** | Retain the existing single main `Window`. Use native title bar, traffic lights, resizing, full screen and window menus. Keep New Chat distinct from New Window; no `WindowGroup` conversion as part of styling. Do not draw fake traffic lights, force a screen size, or alter close/quit/session lifetime. | [Windows][h-windows], [Full screen][h-fullscreen] · [Window][a-window], [NSWindow][a-nswindow] |
| **N02 — Sidebar and detail** | `NavigationSplitView` owns the sidebar/content divider. Conversation selection drives detail through stable IDs. Resize the native divider; do not add an overlaid drag-handle approximation. Preserve draft and scroll ownership when a column hides or reappears. Set meaningful column minima from the contents; do not resize the app window to force all columns visible. | [Split views][h-split], [Sidebars][h-sidebars] · [NavigationSplitView][a-split], [SidebarCommands][a-sidebarcommands] |
| **N03 — Chat list** | Native `List(selection:)` with sidebar styling; row artwork may be custom. Name/preview lead, date/status trail; use stable row identity. Preserve the existing batch-selection model and actions; the open conversation and bulk-selected set are distinct. Native selection remains separate from unread emphasis. Arrow keys navigate the focused list. Preserve whole-query Select All, hidden search selection and paging semantics; do not replace them with selection of only loaded rows. Bind open-chat selection separately and route modifier-click/range/batch actions through the existing model. If native List cannot preserve that contract, retain working click routing and document the AppKit integration gap. | [Lists and tables][h-lists] · [List][a-list], [NSTableView][a-table] |
| **N04 — Window and conversation title** | Selected conversation name is the title; existing retention/status is concise secondary information. Long titles truncate before commands disappear; full identity remains in info. Keep title selection separate from the Info action and do not render a second custom header beneath a native toolbar. | [Toolbars][h-toolbars] · [navigationTitle][a-navigationtitle], [navigationSubtitle][a-navigationsubtitle] |
| **N05 — Toolbar grouping** | Leading: navigation/sidebar. Conversation actions: search and existing contextual commands. Trailing: inspector and More. New Chat belongs to the chat-list context. Use `ToolbarItem`, `ToolbarItemGroup`, and `ControlGroup` for related actions; let native overflow handle secondary commands. Keep text actions visually separate from adjacent symbol groups. At most one emphasized completion action in an editing context. | [Toolbars][h-toolbars] · [ToolbarItem][a-toolbaritem], [ToolbarItemGroup][a-toolbargroup], [ControlGroup][a-controlgroup] |
| **N06 — Inspector** | `.inspector(isPresented:)` on the conversation container; its data follows the selected conversation. Toolbar toggle and View menu use the same visibility state. Content scrolls within the inspector. Opening/hiding it does not clear the composer or navigate away. Use native inspector width constraints, not an overlay covering messages. | [Panels][h-panels] · [inspector][a-inspector], [inspectorColumnWidth][a-inspectorwidth], [InspectorCommands][a-inspectorcommands] |
| **N07 — Nested destinations** | A member profile, relay detail, or complete media library has a named destination and return route to its parent. Use `NavigationStack` inside the owning pane for genuine hierarchy; selecting another chat is sibling selection, not a push. Avoid pushing a succession of modal sheets. | [Navigation and search][h-navigation] · [NavigationStack][a-stack], [NavigationLink][a-navigationlink] |
| **N08 — Global search** | Use `.searchable` with sidebar placement for the conversation directory. Preserve its five filters: Chats, Unread, Invites, Archived, Left chats. Distinguish chat filtering from global message results and local Find; do not invent Groups/DMs/Media search scopes. Preserve the selected conversation while filtering; empty query restores the normal list and filter. The installed SDK controls whether the field appears inline or in the toolbar/sidebar header; do not imitate another OS version's position. | [Searching][h-searching], [Search fields][h-searchfields] · [searchable][a-searchable], [sidebar placement][a-searchsidebar] |
| **N09 — In-conversation Find** | Command-F reveals the conversation's find UI, with query, result count, previous/next, and close. Keep existing async search/history semantics and message-ID navigation. Use `NSTextFinder` only if a real text/range client can describe the transcript; an `NSTableView` is not automatically a text document. Otherwise keep the search model and native search controls. | [Searching][h-searching] · [NSTextFinder][a-textfinder], [NSSearchField][a-searchfield] |

## Sections, groups, and content layout

| ID / pattern | Exact selection rule and White Noise use | Apple guidance / public API |
| --- | --- | --- |
| **G01 — Grouped form section** | Settings and inspector preferences use `Form { Section { … } header/footer }` with `.formStyle(.grouped)`. One section answers one question: appearance, notifications, retention, membership, or identity. Keep help/consequence copy with that section. Do not draw a rounded background around every form row. | [Settings][h-settings], [Layout][h-layout] · [Form][a-form], [Section][a-section], [grouped form][a-groupedform] |
| **G02 — Labeled value** | Use `LabeledContent` for a noneditable value such as retention summary, app version, or public identifier. Editable values use real input controls. A copy command is an adjacent Button; selecting text must not trigger navigation. Keep labels aligned with their value column. | [Labels][h-labels] · [LabeledContent][a-labeledcontent], [Grid][a-grid] |
| **G03 — Group box** | Use `GroupBox` for a self-contained group outside a Form, such as a compact preview with related controls. Prefer a Section inside a Form. Never nest boxes to manufacture card hierarchy or place a whole Settings pane in one box. | [Boxes][h-boxes] · [GroupBox][a-groupbox], [NSBox][a-nsbox] |
| **G04 — Disclosure** | Use `DisclosureGroup` for optional advanced information in the same context, such as technical identifiers. It expands content; a navigation row changes destination. Don't use the same chevron for both meanings or hide errors/required choices in collapsed content. | [Disclosure controls][h-disclosure] · [DisclosureGroup][a-disclosure] |
| **G05 — Related controls** | `ControlGroup` represents related commands such as media actions. `Picker(.segmented)` represents one mutually exclusive value. `ToolbarItemGroup` is toolbar placement. `Group` only composes SwiftUI views; it creates no visual section. Choose by semantics, not by desired capsule shape. | [Toolbars][h-toolbars], [Segmented controls][h-segments] · [ControlGroup][a-controlgroup], [Picker][a-picker], [Group][a-group] |
| **G06 — Separators and row alignment** | Let native list/form containers draw boundaries. Use `Divider` between distinct custom content regions, not between every text label. Align row titles, supporting copy, fields, and validation on their content edge, not unrelated avatar edges. Avoid separator plus border plus shadow for the same boundary. | [Layout][h-layout] · [Divider][a-divider], [Grid][a-grid] |
| **G07 — Collection versus table** | Media thumbnails use `LazyVGrid`/native collection behavior; files/links use lists. Use SwiftUI `Table` for genuinely comparable columns, not a chat list or form. Virtualized transcript stays `NSTableView`. Do not render all messages in a nonvirtualized stack for styling convenience. | [Collections][h-collections], [Lists and tables][h-lists] · [LazyVGrid][a-lazygrid], [Table][a-swifttable], [NSTableView][a-table] |
| **G08 — Scrolling and resize** | One vertical scroll owner per pane; multiline composer may scroll within its existing bounded height. Let native scroll indicators and elasticity work. No nested vertical ScrollViews around a Form/List and no geometry polling to fake a sidebar. Resizing changes available line width without resetting selection or scroll position. | [Scroll views][h-scroll] · [ScrollView][a-scrollview], [NSScrollView][a-nsscrollview] |

## Buttons, choices, and text input

| ID / control | White Noise selection and behavior | Apple guidance / public API |
| --- | --- | --- |
| **C01 — Primary action** | One dominant action for the task: Send, Save, Continue, or Create. Use native `.borderedProminent` with local monochrome tint. A standalone elevated action may use `.glassProminent` on 26+ with the native fallback; do not put glass in grouped content. Keep label/size stable during progress and preserve native disabled states. | [Buttons][h-buttons] · [Button][a-button], [borderedProminent][a-prominent], [glassProminent][a-glassprominent] |
| **C02 — Secondary action** | Cancel, Edit, Copy, Choose File and similar secondary content actions use native neutral `.bordered` or automatic AppKit treatment. No black-outline substitute for iOS gray buttons. Do not add manual shadow, pressed-scale effect, or focus drawing. | [Buttons][h-buttons] · [bordered][a-bordered], [NSButton][a-nsbutton] |
| **C03 — Toolbar/icon action** | A native toolbar Button with `Label` and contextual symbol; `.help` supplies a short explanation. Native toolbar owns background, hover, hit target and grouping. For standalone icon actions use a real Button, not `Image.onTapGesture`. | [Toolbars][h-toolbars], [Buttons][h-buttons] · [Label][a-label], [help][a-help] |
| **C04 — Destructive action** | Use `Button(role: .destructive)` and a specific label. Preserve confirmation and scope: Delete for Me, Delete for Everyone, Leave, End Group, Sign Out and Delete Profile are different operations. Do not make irreversible loss the Return default or bury it among benign quick actions. | [Alerts][h-alerts], [Buttons][h-buttons] · [ButtonRole][a-buttonrole] |
| **C05 — Default and cancel** | `.keyboardShortcut(.defaultAction)` only on the valid, safe completion action in the active dialog; `.cancelAction` on Cancel. Native placement follows locale. Disabled Save cannot still execute through a keyboard handler. In the composer preserve Return/newline/IME rules rather than applying dialog defaults. | [Keyboards][h-keyboards], [Alerts][h-alerts] · [keyboardShortcut][a-keyboardshortcut] |
| **C06 — Toggle** | Binary preference: native `Toggle`. Keep native grouped-form switches for immediate independent on/off rows; use explicit checkboxes for grouped options or subordinate choices. Name the choice for the pane instead of forcing one style on every Toggle. Give a positive label and nearby explanation for scope; disabling a dependent row must not erase its saved value. No custom sliding thumb. | [Toggles][h-toggles] · [Toggle][a-toggle], [ToggleStyle][a-togglestyle] |
| **C07 — Pop-up choice** | Mutually exclusive setting with more options than comfortably fit inline: `Picker` with `.menu` (e.g. language). Current value stays visible; selection updates only through the existing setting action. A `Menu` containing arbitrary commands is not a replacement for a value picker. | [Pop-up buttons][h-popup] · [Picker][a-picker], [MenuPickerStyle][a-menupicker] |
| **C08 — Segmented choice** | Few short mutually exclusive modes, such as current Media/Files or an existing list filter (Links only after D04’s contract exists). Use `.pickerStyle(.segmented)` and retain selection. Do not use segments as independent action buttons, a multi-select filter, or tiny truncated labels. Appearance System/Light/Dark can use this when labels fit. | [Segmented controls][h-segments] · [SegmentedPickerStyle][a-segmentedpicker] |
| **C09 — Radio choice** | Few mutually exclusive options that need visible explanatory text, such as an existing notification policy. Use `.radioGroup` on Mac. Do not imitate iOS circle/check rows with tap gestures. Use a menu instead when a long option list would dominate the pane. | [Toggles][h-toggles] · [RadioGroupPickerStyle][a-radiopicker] |
| **C10 — Text field** | `TextField` for one line, `SecureField` for secrets. Use native field styling, persistent labels, appropriate input validation, standard selection/edit menus and undo. Use a filled semantic field in a custom content card; never glass there. Placeholder is an example, not the only label. Preserve the beginning of a pasted URL except during deliberate cursor navigation. | [Text fields][h-textfields], [Entering data][h-entry] · [TextField][a-textfield], [SecureField][a-securefield] |
| **C11 — Multiline editor** | `TextEditor` for ordinary long form content; retain the `NSTextView` composer bridge for rich desktop editing needs. Preserve marked text, spelling, substitutions, selection, paste and undo. No root tap gesture that clears Mac focus as though dismissing an iPhone keyboard. | [Text views][h-textviews] · [TextEditor][a-texteditor], [NSTextView][a-textview] |
| **C12 — Numeric/date controls** | `Stepper` for bounded discrete values; `Slider` for continuous adjustment with visible value/units; `DatePicker` for a real date/time choice. Use only where the existing feature exposes that value. Retention presets use Picker; do not add unsupported arbitrary expiry dates or sliders. | [Steppers][h-steppers], [Sliders][h-sliders], [Pickers][h-datepickers] · [Stepper][a-stepper], [Slider][a-slider], [DatePicker][a-datepicker] |
| **C13 — Search field** | A search field searches; an editable public identifier/URL remains a labeled TextField unless backed by search. Use native clear and cancel semantics; Escape first cancels the active search context, not the account flow behind it. Keep no-results distinct from loading/error. | [Search fields][h-searchfields] · [searchable][a-searchable], [NSSearchField][a-searchfield] |
| **C14 — Read-only text and links** | Selectable Text or the existing AppKit text renderer for copyable content; `Link` for a validated URL and the existing safe opener. Don't make a read-only key look editable or attach Open URL to an entire row that also contains Copy. Preserve verification and external-navigation consent. | [Labels][h-labels] · [Text][a-text], [Link][a-link], [textSelection][a-textselection] |

## Menus, keyboard, pointer, and focus

| ID / pattern | White Noise rule | Apple guidance / public API |
| --- | --- | --- |
| **K01 — Menu bar** | Retain native App, File, Edit, View, Window, Help structure. App owns Settings; File owns New Chat; Edit owns text editing/Find; View owns sidebar/inspector visibility. A Conversation menu may expose selected-chat commands. Menu, toolbar and context menu must share action, account target, and enablement. Do not replace the entire menu bar to add one command. | [Menu bar][h-menubar] · [Commands][a-commands], [CommandGroup][a-commandgroup], [CommandMenu][a-commandmenu] |
| **K02 — Context menu** | Right-click/Control-click on a chat/message targets that item, not an unrelated previously selected one. Use `.contextMenu`/`NSMenu`; group related commands, separate destructive ones, and preserve capability checks. Essential actions also have a visible/menu route. No phone long-press sheet. | [Context menus][h-context] · [contextMenu][a-contextmenu], [NSMenu][a-nsmenu] |
| **K03 — Menu content** | Action labels describe outcomes; use checkmarks for selected settings, stateful Mute/Unmute labels, and ellipsis only when additional input is required. No ellipsis just because a view opens. Keep useful shortcuts visible, unavailable actions consistently disabled, and dangerous actions separated. | [Menus][h-menus] · [Menu][a-menu], [NSMenuItem][a-menuitem] |
| **K04 — Command routing** | Use `FocusedValue`/`FocusedSceneValue` or existing responder-chain integration for commands that depend on the key window/selection. Settings and modal text fields must retain their own editing commands. Do not install a global key monitor that steals typing, Escape, arrows, or Command-C. | [Keyboards][h-keyboards] · [FocusedValue][a-focusedvalue], [NSResponder][a-responder] |
| **K05 — Focus** | Use `@FocusState` for field focus and native focus traversal. Initial focus goes to the first useful editable field or search only when opening that task. Closing a sheet/popover returns focus to its initiating control/context. Model refreshes, errors and incoming messages must not repeatedly grab focus. | [Focus and selection][h-focus] · [FocusState][a-focusstate] |
| **K06 — Pointer feedback** | Native controls draw hover/pressed feedback and appropriate cursor. Hover-only message accessories remain reachable while moving into their popover/menu and also have keyboard/context-menu access. Don't close a reaction picker because the pointer left the originating row. Hover must not change selection or perform an action. | [Pointing devices][h-pointer] · [onHover][a-onhover], [NSCursor][a-cursor] |
| **K07 — Tooltips** | `.help` explains an icon in a few words, with the action name matching the command. Required warning/consent belongs visibly beside the decision, never only in a tooltip. No custom delayed floating tooltip system. | [Offering help][h-help] · [help][a-help] |
| **K08 — Drag/drop and paste** | Reuse the existing attachment/text validation and staging pipeline. Show a native permitted/prohibited destination; drop stages content and does not send it. Preserve file access/security-scoped lifetimes. Add `Transferable`, `.draggable`/`.dropDestination` only where the existing action supports the data type. | [Drag and drop][h-drag] · [Transferable][a-transferable], [NSDraggingDestination][a-dragdestination] |
| **K09 — Undo/redo** | Retain native text undo in composer and editors. Do not advertise Undo for a sent message, account operation, or deletion without a real existing reversible action. No UI-only rollback that lies about a completed remote mutation. | [Undo and redo][h-undo] · [UndoManager][a-undo] |
| **K10 — Multiple selection** | Preserve existing chat and message selection modes, cancellation, batch actions and capability limits. Use native list/range selection where it fits that contract; expose existing actions in contextual native controls. Keep selection distinct from unread, focus and the open conversation. Do not remove working selection because its current presentation looks mobile, or add new bulk-delete semantics as styling. | [Lists and tables][h-lists], [Focus and selection][h-focus] · [List][a-list], [NSTableView][a-table] |

### Command assignments

These are target routes, not permission to add an unavailable feature. Inspect
existing registrations and resolve collisions before assigning a shortcut.

| Command | Shortcut / routing |
| --- | --- |
| Settings… | Command-comma; native Settings scene, reuse its window. |
| New Chat… | Command-N; existing compose/recipient flow, never a new account/window lifecycle. |
| Find in Conversation… | Command-F when a conversation is the active content. |
| Find Next / Previous | Command-G / Shift-Command-G in active conversation search. |
| Use Selection for Find | Command-E only when the transcript exposes a meaningful selected-text query. |
| Search All Chats | Shift-Command-F when the existing global search route is available. |
| Focus sidebar search | Option-Command-F; use the existing focus route and do not hijack text editing elsewhere. |
| Show/Hide Sidebar | Native `SidebarCommands`; retain its system command behavior. |
| Show/Hide Inspector | Native `InspectorCommands`, **Control-Command-I**. Do not substitute Command-I. |
| Copy/Paste/Cut/Select All/Undo/Redo | Native responder-chain commands in the focused editor or supported selection. |
| Escape / Return | Owned by the current menu, search, popover, sheet or editor; no app-wide unconditional interception. |

## Sheets, popovers, alerts, and panels

| ID / pattern | When to use it and how it ends | Apple guidance / public API |
| --- | --- | --- |
| **P01 — Sheet** | A bounded task tied to the current window: edit profile/group, add members, export keys with existing confirmation. Use `.sheet` with a clear title, content-sized form, and Cancel/Save or task-specific completion. Keep draft on failure; dismiss only on confirmed completion or intentional cancellation. No bottom detents, swipe handle, full-screen cover, or fixed iPhone width. | [Sheets][h-sheets], [Modality][h-modality] · [sheet][a-sheet] |
| **P02 — Popover** | A small contextual choice/details view anchored to the invoking control: reaction picker, compact retention information. Use `.popover` with a real attachment anchor; support keyboard dismissal and movement between anchor/content. Long staged forms belong in a sheet. Essential saving/consent must not depend on clicking outside. | [Popovers][h-popovers] · [popover][a-popover], [NSPopover][a-nspopover] |
| **P03 — Alert** | A blocking error or consequential decision requiring a response. State the object, consequence, and precise action labels; Cancel is safe. Use `.alert`/`NSAlert`, not a custom dimming overlay. Ordinary completion, Copy, and harmless toggles need no alert. | [Alerts][h-alerts] · [alert][a-alert], [NSAlert][a-nsalert] |
| **P04 — Confirmation choice** | A short decision among existing actions can use `.confirmationDialog`. Preserve distinctions such as local/shared deletion and eligibility. Let macOS supply its presentation; do not reproduce an iOS action sheet. Multiple destructive choices still need unambiguous consequences. | [Alerts][h-alerts] · [confirmationDialog][a-confirmationdialog] |
| **P05 — Inspector versus panel** | Selected-chat details use N06's inspector. A separate utility `NSPanel` is reserved for a genuine independently useful nonmodal utility, not a substitute for chat info or a new floating window for every control. Do not change app activation/window lifetime for visual similarity. | [Panels][h-panels] · [NSPanel][a-nspanel] |
| **P06 — Open/save panel** | Let native import/export presentation choose files and destinations through the existing flow; preserve type restrictions, replacement confirmation and errors. Cancel leaves the draft/staged attachments unchanged. No bespoke Finder clone. | [File management][h-files] · [fileImporter][a-fileimporter], [fileExporter][a-fileexporter], [NSOpenPanel][a-openpanel], [NSSavePanel][a-savepanel] |
| **P07 — Presentation ownership** | One owning task presents its current sheet/alert/popover. On account/chat changes, preserve existing dismissal/invalidation rules so a destructive editor cannot act on a newly selected object. Back, Cancel, Close and Save are distinct. Avoid stacking a new sheet merely to escape a cramped form. | [Modality][h-modality], [Managing accounts][h-accounts] · [DismissAction][a-dismiss] |

## Chat list, transcript, and composer

Apple provides containers and interactions, not a complete reusable chat bubble
system. The custom content below is deliberately bounded and reuses White Noise
presentation/data owners. It does not authorize changes to MDK or projection logic.

| ID / pattern | Specific White Noise contract | Native basis / reference |
| --- | --- | --- |
| **T01 — Chat row anatomy** | Avatar; name and latest useful preview; trailing time and unread/delivery indicator. Draft/invitation/failed states use words/symbols, not only color. Preserve existing sorting, pinning and preview calculation. No row recreation on unread changes. | [Lists and tables][h-lists] · N03; `SidebarViews.swift` |
| **T02 — Message surface** | Pair sent/received colors from F02. Body is primary; timestamp/delivery secondary. Keep a readable maximum content width from existing bubble metrics while allowing the transcript to resize. Neutral reply inset and metadata must remain legible on either polarity. No arbitrary iOS pixel copy or colored theme variant. | [Typography][h-type], [Color][h-color] · [iOS bubble palette][ios-bubbles] |
| **T03 — Sender runs** | Keep existing grouping boundaries for sender, day, system event, reply/attachment context, and delivery semantics. Show enough sender/name/avatar context in groups. Do not change timestamps or regroup stored messages to achieve a visual shape. | [Layout][h-layout] · existing transcript presentation owners |
| **T04 — Transcript behavior** | Retain `NSTableView` virtualization, row identity, anchoring, history load, unread boundary, and selection. Incoming activity must not yank a person away from older messages. User-driven jump-to-latest and search navigation use existing scroll intent. No animated reload of the whole transcript. | [Scroll views][h-scroll] · [NSTableView][a-table], [NSScrollView][a-nsscrollview] |
| **T05 — Message actions** | Native context menu for Reply/Copy/Edit/Delete/Forward where available. Reaction affordance may be compact and contextual but stays keyboard/menu reachable. Target the clicked message and retain its permissions. Don't wrap selectable text in a giant Button. | [Context menus][h-context] · K02, K06 |
| **T06 — Reactions and details** | Reuse compact emoji/count controls with visible own-reaction state. Click invokes the existing action; details show who reacted through the existing model. Keep pointer path into the picker open. Do not infer a new click/double-click contract or remove-reaction behavior from another app. | [Popovers][h-popovers], [Buttons][h-buttons] · P02, C03 |
| **T07 — Replies and links** | Quoted sender/content stays distinct from the new message. Jump uses the original message ID and handles unavailable targets truthfully. Link previews retain consent/loading/error logic; a GitHub card is a separate feature if it needs new requests. No auto-fetch created by a visual component. | [Privacy][h-privacy], [Feedback][h-feedback] · existing reply and link-preview models |
| **T08 — Composer anatomy** | Existing `NSTextView`, staged attachments, reply/edit context, accessory actions, and Send form one composition area. Keep text selection, native text menus, spelling and IME. Return follows the existing Send/newline setting; marked text confirmation never accidentally sends. Preserve draft across opening inspector/search. | [Text views][h-textviews] · [NSTextView][a-textview], [NSResponder][a-responder] |
| **T09 — Staged content** | Attachment chips/previews have filename/content identity, individual Remove, and real loading/error state. Remove affects staging, not stored files/messages. Reply Cancel clears the reply target, not the whole draft. Send eligibility follows current validation and pending work. | [Entering data][h-entry], [Feedback][h-feedback] · C01, E02 |
| **T10 — Polls and structured messages** | Use ordinary text and native choice controls inside the existing message card. Keep voting, submitting, results and participant details separate. Do not present results as editable settings or treat a local selection as a completed vote. | [Toggles][h-toggles], [Progress indicators][h-progress] · C06–C09 |
| **T11 — Retention and expiry** | Header shows the current retention summary; message expiry uses existing timing/state. A compact custom pie may be appropriate where no native control fits. Pair it with meaningful text/help; no ticking layout shift, per-row animation loop, or invented deletion countdown. | [Feedback][h-feedback], [Motion][h-motion] · M06 |
| **T12 — Notice versus system message** | Day separators and system events remain transcript content. History-incomplete/recovery notices keep their visible explanation and existing dismissal action. Don't restyle a required acknowledgment into an auto-disappearing toast or imply missing history was recovered. | [Feedback][h-feedback], [Alerts][h-alerts] · E03, E07 |

## Settings, identity, and chat information

| ID / pattern | Structure and behavior | Apple guidance / public API |
| --- | --- | --- |
| **S01 — Settings window** | `Settings` scene opens through App > Settings… / Command-comma and shares the current session/models. The current full category inventory uses `NavigationSplitView` plus a native sidebar `List` and grouped form detail: preserve the iOS order from the organization table. Keep parent selection for nested pages. Retain active-profile/identity-sharing and Add Profile controls above categories, with separated Sign Out/Delete Profile below. Map account-mutation Settings destinations into this scene and retain Add Profile return context without changing account/phase decisions. Native `TabView` panes fit a small bounded settings surface, not a horizontal strip of every existing category. Do not introduce a new persistence mechanism just to remember pane selection. Before enabling the second window, preserve conversation-window visibility/read attribution, focused command routing, shared session callbacks and existing sheet-local advisory hosts. Keep Settings unavailable during onboarding/no account; dismiss stale account editors and return to the existing main chooser/onboarding when its account disappears. | [Settings][h-settings], [Sidebars][h-sidebars] · [Settings][a-settings], [NavigationSplitView][a-split], [TabView][a-tabview] |
| **S02 — Preference groups** | Appearance contains existing System/Light/Dark and Language. Notifications keeps account versus all-profiles/device scope explicit. Privacy retains blocked users/diagnostics relationships. Data Usage and Manage Storage remain discoverable separately. A restyle doesn't add density, theme, synchronization, retention or auto-download preferences copied from iOS. | [Settings][h-settings] · G01, C06–C09 |
| **S03 — Account selector** | Show active profile name/avatar; native menu/picker marks the selected account and groups Add Profile/account-management actions separately. Use the existing switch lifecycle. Opening a menu must not switch profile; cancel leaves the selection unchanged. | [Managing accounts][h-accounts], [Menus][h-menus] · [Menu][a-menu], [Picker][a-picker] |
| **S04 — Profile and keys** | Profile editor preserves iOS identity/privacy/fields/actions order. Public identifiers are selectable/copyable; private keys retain existing reveal/export authentication and warnings. Don't show a secret in a tooltip, automatic preview, search index, or screenshot fixture. | [Privacy][h-privacy], [Entering data][h-entry] · G02, C10, P01 |
| **S05 — Group/contact inspector** | Follow the iOS group/direct hierarchy above; render sections and labeled rows. Mute, retention and notifications show current values; no decorative grid of four oversized phone tiles. Admin/member/ended-group capability states govern action visibility/enablement. Editing opens a bounded sheet and commits only on success. | [Panels][h-panels], [Boxes][h-boxes] · [inspector][a-inspector], [Form][a-form] |
| **S06 — Member list** | Native rows with person identity, membership/role, and contextual existing moderation commands. Open the person without losing the group context. Search/See All controls filter the member list, not global chats. Keep members, linked devices, shared groups, and technical identifiers in distinct sections. | [Lists and tables][h-lists] · [List][a-list], [NavigationStack][a-stack] |
| **S07 — Destructive sections** | Terminal section separated from routine settings, with precise consequences before confirmation. Keep leaving a group, deleting local history, ending a group, and removing a member distinct. Progress/error belongs to the same operation. Do not change confirmation or add recovery claims as copy polish. | [Alerts][h-alerts], [Modality][h-modality] · C04, P03–P04 |
| **S08 — Onboarding and image selection** | Reuse supported account steps and native fields. Profile image menu offers only existing sources. URL validation/download errors stay at the field; show a stable preview while loading. Decode successfully before opening Crop, retain selection on error, and preserve URL/image consent. Use native file/photo picking where the current permission contract supports it. | [Onboarding][h-onboarding], [Entering data][h-entry] · C10, P06, D01 |

## Files, media, and system experiences

| ID / pattern | White Noise use and boundary | Apple guidance / public API |
| --- | --- | --- |
| **D01 — File/photo selection** | Native file importer/open panel for supported attachment types; `PhotosPicker` only for an existing photo-library flow. Use existing validation, image decode, metadata handling, security scope and staging. A native picker does not authorize broader library access or a new upload. | [File management][h-files], [Privacy][h-privacy] · [fileImporter][a-fileimporter], [NSOpenPanel][a-openpanel], [PhotosPicker][a-photospicker] |
| **D02 — File rows** | File-type icon from `NSWorkspace.icon(for:)`/`UTType`, filename, size/type and genuine transfer state. Keep progress/retry adjacent to that file. Never use a decorative generic thumbnail in place of a meaningful failed/download state. | [Lists and tables][h-lists] · [NSWorkspace][a-workspace], [UTType][a-uttype] |
| **D03 — Preview** | Quick Look for supported local content only when existing attachment handoff can safely retain the file for the preview lifetime. Keep current viewer where that contract is unavailable. Do not make a new plaintext cache, discard a lease early, or download content merely on hover. | [Quick Look][a-quicklookui] · [quickLookPreview][a-quicklook], [QLPreviewPanel][a-previewpanel] |
| **D04 — Shared library** | Native Media/Files segmented selector; thumbnails in grid and files in rows. Add Links only after a separately scoped complete link-history contract exists. Current attachment history supplies neither that inventory nor per-attachment expiry or complete category totals; omit unsupported adornments. Selecting opens the appropriate existing viewer/opener. Retain category, selected message/file and return context. For a large library use a content destination instead of squeezing everything into the inspector. | [Collections][h-collections], [Segmented controls][h-segments] · [LazyVGrid][a-lazygrid], [Picker][a-picker] |
| **D05 — Audio/video** | Prefer native playback controls (`VideoPlayer`/`AVPlayerView`) for full media viewing. Compact voice-message chrome can remain custom around the existing player. Show elapsed/duration and real play/pause/seek capability. Don't autoplay remote media or change audio/session behavior as a restyle. | [Playing audio][h-audio], [Playing video][h-video] · [VideoPlayer][a-videoplayer], [AVPlayerView][a-playerview] |
| **D06 — Sharing/export** | Native `ShareLink`/`NSSharingServicePicker` when the existing action can supply the transferable with the required lifetime; save/export uses existing handoff. Maintain what is shared and consent, especially identifiers/keys/decrypted attachments. No native share button that bypasses encryption/lifetime policy. | [Sharing][h-sharing] · [ShareLink][a-sharelink], [NSSharingServicePicker][a-sharepicker] |
| **D07 — Permissions/system settings** | Keep OS-owned camera, microphone, notifications and authentication prompts native. Explain the immediate need through existing consent flows; use existing supported Settings links. A UI task cannot request new permissions, change notification policy, or spoof Apple's prompt. | [Privacy][h-privacy], [Managing notifications][h-notifications] · [UNUserNotificationCenter][a-notificationcenter], [AVCaptureDevice][a-capturedevice] |
| **D08 — No speculative features** | Preserve the existing `DockBadgeController` and badge policy. Don't introduce Finder-style column browsing, web views, charts, color/font panels, printing, a menu-bar extra, Touch Bar controls, new badge behavior or extra main windows just to complete a component checklist. Revisit the relevant Apple component only for an explicitly scoped capability. Color pickers/themes are deferred. | [Component catalog][h-components], [Pattern catalog][h-patterns] |

## Feedback, progress, and recovery

| ID / state | Required presentation | Apple guidance / public API |
| --- | --- | --- |
| **E01 — Empty/no selection/no results** | Distinguish no conversations, no selected conversation, no search results, and failed loading. Use `ContentUnavailableView` when its layout fits, with one real next action if available. Don't show onboarding or empty art over recoverable existing content. | [Feedback][h-feedback] · [ContentUnavailableView][a-unavailable] |
| **E02 — Loading/progress** | `ProgressView`: indeterminate for unknown duration; determinate only with real progress. Keep it near the initiating task. Preserve button/form size and visible staged content. Don't simulate percentages, delay a fast completion, or animate an entire view with shimmer. Cancel is shown only if an existing action can actually cancel. | [Loading][h-loading], [Progress indicators][h-progress] · [ProgressView][a-progress] |
| **E03 — Validation/failure** | Persistent localized error by the field/action; keep draft and selected files. Separate field validation from save/network failure. Retry reuses the existing operation and eligibility. Blocking decision uses native alert; a transient toast must not be the sole explanation. | [Feedback][h-feedback], [Alerts][h-alerts] · [alert][a-alert] |
| **E04 — Save completion** | Disable duplicate submission; remain in editor until confirmed success, preserving entered content on failure. Successful content/navigation normally confirms the outcome. No redundant success modal or fake optimistic completion over an unresolved mutation. | [Feedback][h-feedback] · [Button][a-button], [ProgressView][a-progress] |
| **E05 — Copy feedback** | Show temporary Copied/checkmark at the initiating control, keeping repeated copy available and canceling delayed reset when the view disappears. Preserve existing announcement semantics. Don't use a global toast that obscures another window or expose copied secret contents. | [Feedback][h-feedback] · C02, M07 |
| **E06 — Offline/disabled** | Explain the relevant known state near the affected action. Keep reading and local editing usable where supported; no blanket disabled window. Retain system disabled appearance and capability checks. Do not add network probes/retry loops to decide a visual state. | [Feedback][h-feedback], [Buttons][h-buttons] · native `.disabled` with existing feature state |
| **E07 — Persistent notices** | Keep account/history/recovery/security notices visible for as long as their existing contract requires, with truthful dismissal. A presentation migration must not acknowledge a history loss automatically or turn a warning into decoration. | [Alerts][h-alerts], [Feedback][h-feedback] · existing notice models |

## Transitions and animation

Use Apple's own navigation/presentation/control motion by default. No app-wide
duration/easing recipe: Apple does not publish one fixed timing that reproduces
all of its apps. Custom motion must explain a specific state change and remain
interruptible; it must not change the operation's completion, timing, or lifetime.
[Motion][h-motion] · [SwiftUI animations and transitions][a-animations].

| ID / transition | White Noise motion rule | API / implementation boundary |
| --- | --- | --- |
| **M01 — Window/sheet/popover/menu** | Use native open/close presentation untouched. No second fade/scale/slide around system chrome, animation delay before dismissal, or custom easing intended to imitate a private Apple app. | `.sheet`, `.popover`, `.alert`, native window/menu APIs; P01–P07. |
| **M02 — Sidebar/inspector** | Native split-view/inspector show-hide and live resize. Keep detail identity stable. Do not animate widths per drag event or slide an overlay over the conversation to simulate a column. | [NavigationSplitView][a-split], [inspector][a-inspector]. |
| **M03 — Navigation/selection** | Native navigation transition for child destinations. Selecting a sibling conversation replaces its content without a phone push, cross-window zoom, or sliding every row. Changing category/selection keeps its native feedback. | [NavigationStack][a-stack], [List][a-list]. |
| **M04 — Disclosure/local layout** | Native DisclosureGroup first. For a genuinely custom inline expansion, animate only its expanded state with `.smooth`; no extra bounce. Use `.animation(_:value:)` at the smallest owning view or `withAnimation` around the specific local change. Do not animate a feature's entire observed snapshot. | [smooth][a-smooth], [animation(value:)][a-animationvalue], [withAnimation][a-withanimation]. |
| **M05 — Message arrival/history** | Keep existing transcript insertion and anchor behavior. No slide/fade on all initial or paginated rows, no staggered reveal, no reanimation on read receipts. Scroll to latest only through existing permitted scroll intent. Motion must never delay rendering incoming messages. | `NSTableView` update/scroll owner; T04. |
| **M06 — Progress/expiry** | Use native progress motion for actual ongoing work. Refresh retention/expiry from existing presentation timing; no pulse, perpetual bounce, or per-row timer for decoration. Playback/progress is not a reason to animate surrounding layout. | [ProgressView][a-progress]; T11, E02. |
| **M07 — State feedback** | For Copy/checkmark or an existing play/pause glyph change, use an immediate update or a small native content transition. A `symbolEffect` must be tied to a discrete meaningful event; no looping attention effect on ordinary toolbar buttons. Preserve stable bounds. | [contentTransition][a-contenttransition], [symbolEffect][a-symboleffect]. |
| **M08 — Pointer/direct manipulation** | Native hover and press feedback. Custom drag feedback follows the pointer without lag; no spring behind the cursor. Don't add scale-on-hover, lift-on-hover, or a rubber-band effect to every Mac button. | Native controls; [onHover][a-onhover], existing drag owner. |
| **M09 — Reduce Motion/interruption** | Respect `accessibilityReduceMotion` in custom animation: remove spatial travel/bounce, use an immediate change or brief opacity feedback where necessary. Native controls keep their system adaptation. Cancel/switch/typing remains available while animating. Final state and feedback cannot depend on animation completion firing. | [accessibilityReduceMotion][a-reducemotion], [Transaction][a-transaction]. This preserves support; dedicated QA still needs authorization. |
| **M10 — Glass continuity** | On 26+, native containers own their glass transitions. `GlassEffectContainer`/glass IDs are only for an approved custom floating group that genuinely needs coordinated glass, not form cards or message bubbles. No matched-geometry “hero” transition by default and no glass imitation on older OS versions. | [Liquid Glass][a-adoptingglass], [GlassEffectContainer][a-glasscontainer]; native fallback below. |

## API availability and native fallbacks

The project supports macOS 15.6. These are feature gates, not permission to raise
the minimum target. Exact overloads and SF Symbols can have newer requirements
than their parent type; inspect the linked declaration and installed SDK.

| API family | Usable baseline / action |
| --- | --- |
| `Window`, `NavigationSplitView`, `NavigationStack`, `LabeledContent`, `Grid` | macOS 13+; available at the current floor. Keep existing scene lifetime. |
| `Settings`, native toolbar items | macOS 11+; available. `ControlGroup` is 12+. |
| `FormStyle.grouped` | macOS 13+; use it directly at the floor. |
| `.inspector`, inspector width, `InspectorCommands` | macOS 14+; available at the floor, including native inspector command. |
| `.searchable(text:placement:prompt:)` linked overload | macOS 13+; sidebar placement exists from 12. Rendering can differ with SDK/OS. |
| `ContentUnavailableView`, symbol effects | macOS 14+ for the base APIs; inspect the exact effect/overload. |
| `.quickLookPreview` | macOS 11+; file/lease lifetime still determines whether adoption is safe. |
| [`NSColor.secondarySystemFill`][a-secondaryfill] | macOS 14+; available for our received-bubble mapping. |
| [`.glass`][a-glassbutton], [`.glassProminent`][a-glassprominent], [`.glassEffect`][a-glasseffect], [`GlassEffectContainer`][a-glasscontainer], [`ToolbarSpacer`][a-toolbarspacer] | macOS 26+. Guard with `if #available(macOS 26.0, *)`. Build using an SDK that declares the chosen API. |
| Glass button fallback | Use `.bordered` for secondary / `.borderedProminent` for primary on 15.6. Preserve role, label, focus, disabled state, and monochrome foreground pairing. Never fake Liquid Glass with layered blurs. |
| Toolbar grouping fallback | Use ordinary `ToolbarItem`/`ToolbarItemGroup`/`ControlGroup` placement before 26; don't inject custom material rectangles to mimic new toolbar islands. |

## Source map and implementation decisions

Paths are entry points, not an instruction to modify every owner or a claim that
the present code already follows this guide. Follow the actual model/action into
its owner before making a UI change.

| Area | Existing Mac entry point |
| --- | --- |
| Semantic colors/type | [Palette](../whitenoise-mac/Views/Palette); `WNColor`, `WNNSColor`, legacy `WNTextStyle`, identity `WNAccentColorSet`. |
| Main shell/sidebar | [MessengerShellView](../whitenoise-mac/Views/MessengerShellView.swift), [SidebarViews](../whitenoise-mac/Views/SidebarViews.swift). |
| Transcript/composer | [TranscriptTableView](../whitenoise-mac/Views/TranscriptTableView.swift), [ComposerViews](../whitenoise-mac/Views/ComposerViews.swift). |
| Settings and category ownership | [SettingsPanelView](../whitenoise-mac/Views/Settings/SettingsPanelView.swift), [MessengerModels](../whitenoise-mac/Models/MessengerModels.swift) (`SettingsPage`), [Features](../whitenoise-mac/Features). |
| Group/contact info and media | [GroupDetails](../whitenoise-mac/Views/GroupDetails), [ContactDetails](../whitenoise-mac/Views/ContactDetails). |
| Onboarding | [Onboarding](../whitenoise-mac/Views/Onboarding). |
| Attachment handoff | [AttachmentHandoff](../whitenoise-mac/Core/AttachmentHandoff.swift); preserve the MDK-owned lease and file lifetime. |
| Session lifetime | [AccountScope](../whitenoise-mac/Session/AccountScope.swift); do not recreate it for new UI containers. |

For a requested change, identify its pattern IDs, existing action/model, native
container/control, state handling, and any availability fallback. Put a material
Mac exception or custom-control reason in the change/PR description, not a new
per-task report. Reuse a wrapper only if it preserves the native behavior above;
an existing custom wrapper is not an exemption from the design target.

Custom UI is justified for message bubbles, avatars, reaction pills, structured
message content, and compact expiry/playback where no native component supplies
the product semantics. It is not a reason to replace native buttons, forms,
menus, focus, scroll containers, sheets, or window chrome. Keep custom state
local to the feature; don't grow `WorkspaceState` or change account/network/MDK
behavior to satisfy a visual design.

For issue ownership, implementation boundaries and permitted verification, read
[delivery](../.agents/skills/wn-mac-design/references/delivery.md). For a requested
review, use [wn-mac-design-review](../.agents/skills/wn-mac-design-review/SKILL.md).

[ios-design]: https://github.com/marmot-protocol/whitenoise-ios/blob/b4bd66bc/docs/ios-design.md
[ios-settings]: https://github.com/marmot-protocol/whitenoise-ios/blob/b4bd66bc/whitenoise-ios/Settings/SettingsView.swift
[ios-group]: https://github.com/marmot-protocol/whitenoise-ios/blob/b4bd66bc/whitenoise-ios/Group/GroupDetailsView.swift
[ios-profile]: https://github.com/marmot-protocol/whitenoise-ios/blob/b4bd66bc/whitenoise-ios/Profile/ProfileContentView.swift
[ios-button]: https://github.com/marmot-protocol/whitenoise-ios/blob/b4bd66bc/whitenoise-ios/Components/WNButton.swift
[ios-bubbles]: https://github.com/marmot-protocol/whitenoise-ios/blob/b4bd66bc/whitenoise-ios/Conversation/ChatSurfacePresentation.swift
[ios-identity]: https://github.com/marmot-protocol/whitenoise-ios/blob/b4bd66bc/whitenoise-ios/Components/WNIdentityPalette.swift
[ios-gray]: https://github.com/marmot-protocol/whitenoise-ios/blob/b4bd66bc/whitenoise-ios/Components/WNGrayButton.swift

[h-mac]: https://developer.apple.com/design/human-interface-guidelines/designing-for-macos
[h-layout]: https://developer.apple.com/design/human-interface-guidelines/layout
[h-color]: https://developer.apple.com/design/human-interface-guidelines/color
[h-dark]: https://developer.apple.com/design/human-interface-guidelines/dark-mode
[h-type]: https://developer.apple.com/design/human-interface-guidelines/typography
[h-materials]: https://developer.apple.com/design/human-interface-guidelines/materials
[h-symbols]: https://developer.apple.com/design/human-interface-guidelines/sf-symbols
[h-accessibility]: https://developer.apple.com/design/human-interface-guidelines/accessibility
[h-writing]: https://developer.apple.com/design/human-interface-guidelines/writing
[h-labels]: https://developer.apple.com/design/human-interface-guidelines/labels
[h-windows]: https://developer.apple.com/design/human-interface-guidelines/windows
[h-fullscreen]: https://developer.apple.com/design/human-interface-guidelines/going-full-screen
[h-split]: https://developer.apple.com/design/human-interface-guidelines/split-views
[h-sidebars]: https://developer.apple.com/design/human-interface-guidelines/sidebars
[h-lists]: https://developer.apple.com/design/human-interface-guidelines/lists-and-tables
[h-toolbars]: https://developer.apple.com/design/human-interface-guidelines/toolbars
[h-panels]: https://developer.apple.com/design/human-interface-guidelines/panels
[h-navigation]: https://developer.apple.com/design/human-interface-guidelines/navigation-and-search
[h-searching]: https://developer.apple.com/design/human-interface-guidelines/searching
[h-searchfields]: https://developer.apple.com/design/human-interface-guidelines/search-fields
[h-settings]: https://developer.apple.com/design/human-interface-guidelines/settings
[h-boxes]: https://developer.apple.com/design/human-interface-guidelines/boxes
[h-disclosure]: https://developer.apple.com/design/human-interface-guidelines/disclosure-controls
[h-segments]: https://developer.apple.com/design/human-interface-guidelines/segmented-controls
[h-collections]: https://developer.apple.com/design/human-interface-guidelines/collections
[h-scroll]: https://developer.apple.com/design/human-interface-guidelines/scroll-views
[h-buttons]: https://developer.apple.com/design/human-interface-guidelines/buttons
[h-alerts]: https://developer.apple.com/design/human-interface-guidelines/alerts
[h-keyboards]: https://developer.apple.com/design/human-interface-guidelines/keyboards
[h-toggles]: https://developer.apple.com/design/human-interface-guidelines/toggles
[h-popup]: https://developer.apple.com/design/human-interface-guidelines/pop-up-buttons
[h-textfields]: https://developer.apple.com/design/human-interface-guidelines/text-fields
[h-entry]: https://developer.apple.com/design/human-interface-guidelines/entering-data
[h-textviews]: https://developer.apple.com/design/human-interface-guidelines/text-views
[h-steppers]: https://developer.apple.com/design/human-interface-guidelines/steppers
[h-sliders]: https://developer.apple.com/design/human-interface-guidelines/sliders
[h-datepickers]: https://developer.apple.com/design/human-interface-guidelines/pickers
[h-menubar]: https://developer.apple.com/design/human-interface-guidelines/the-menu-bar
[h-context]: https://developer.apple.com/design/human-interface-guidelines/context-menus
[h-menus]: https://developer.apple.com/design/human-interface-guidelines/menus
[h-focus]: https://developer.apple.com/design/human-interface-guidelines/focus-and-selection
[h-pointer]: https://developer.apple.com/design/human-interface-guidelines/pointing-devices
[h-help]: https://developer.apple.com/design/human-interface-guidelines/offering-help
[h-drag]: https://developer.apple.com/design/human-interface-guidelines/drag-and-drop
[h-undo]: https://developer.apple.com/design/human-interface-guidelines/undo-and-redo
[h-sheets]: https://developer.apple.com/design/human-interface-guidelines/sheets
[h-modality]: https://developer.apple.com/design/human-interface-guidelines/modality
[h-popovers]: https://developer.apple.com/design/human-interface-guidelines/popovers
[h-files]: https://developer.apple.com/design/human-interface-guidelines/file-management
[h-accounts]: https://developer.apple.com/design/human-interface-guidelines/managing-accounts
[h-privacy]: https://developer.apple.com/design/human-interface-guidelines/privacy
[h-feedback]: https://developer.apple.com/design/human-interface-guidelines/feedback
[h-progress]: https://developer.apple.com/design/human-interface-guidelines/progress-indicators
[h-motion]: https://developer.apple.com/design/human-interface-guidelines/motion
[h-onboarding]: https://developer.apple.com/design/human-interface-guidelines/onboarding
[a-quicklookui]: https://developer.apple.com/documentation/quicklookui
[h-audio]: https://developer.apple.com/design/human-interface-guidelines/playing-audio
[h-video]: https://developer.apple.com/design/human-interface-guidelines/playing-video
[h-sharing]: https://developer.apple.com/design/human-interface-guidelines/collaboration-and-sharing
[h-notifications]: https://developer.apple.com/design/human-interface-guidelines/managing-notifications
[h-components]: https://developer.apple.com/design/human-interface-guidelines/components
[h-patterns]: https://developer.apple.com/design/human-interface-guidelines/patterns
[h-loading]: https://developer.apple.com/design/human-interface-guidelines/loading
[a-colors]: https://developer.apple.com/documentation/appkit/ui-element-colors
[a-material]: https://developer.apple.com/documentation/swiftui/material
[a-font]: https://developer.apple.com/documentation/swiftui/font
[a-label]: https://developer.apple.com/documentation/swiftui/label
[a-window]: https://developer.apple.com/documentation/swiftui/window
[a-nswindow]: https://developer.apple.com/documentation/appkit/nswindow
[a-split]: https://developer.apple.com/documentation/swiftui/navigationsplitview
[a-sidebarcommands]: https://developer.apple.com/documentation/swiftui/sidebarcommands
[a-list]: https://developer.apple.com/documentation/swiftui/list
[a-table]: https://developer.apple.com/documentation/appkit/nstableview
[a-navigationtitle]: https://developer.apple.com/documentation/swiftui/view/navigationtitle(_:)
[a-navigationsubtitle]: https://developer.apple.com/documentation/swiftui/view/navigationsubtitle(_:)
[a-toolbaritem]: https://developer.apple.com/documentation/swiftui/toolbaritem
[a-toolbargroup]: https://developer.apple.com/documentation/swiftui/toolbaritemgroup
[a-controlgroup]: https://developer.apple.com/documentation/swiftui/controlgroup
[a-inspector]: https://developer.apple.com/documentation/swiftui/view/inspector(ispresented:content:)
[a-inspectorwidth]: https://developer.apple.com/documentation/swiftui/view/inspectorcolumnwidth(min:ideal:max:)
[a-inspectorcommands]: https://developer.apple.com/documentation/swiftui/inspectorcommands
[a-stack]: https://developer.apple.com/documentation/swiftui/navigationstack
[a-navigationlink]: https://developer.apple.com/documentation/swiftui/navigationlink
[a-searchable]: https://developer.apple.com/documentation/swiftui/view/searchable(text:placement:prompt:)
[a-searchsidebar]: https://developer.apple.com/documentation/swiftui/searchfieldplacement/sidebar
[a-textfinder]: https://developer.apple.com/documentation/appkit/nstextfinder
[a-searchfield]: https://developer.apple.com/documentation/appkit/nssearchfield
[a-form]: https://developer.apple.com/documentation/swiftui/form
[a-section]: https://developer.apple.com/documentation/swiftui/section
[a-groupedform]: https://developer.apple.com/documentation/swiftui/formstyle/grouped
[a-labeledcontent]: https://developer.apple.com/documentation/swiftui/labeledcontent
[a-grid]: https://developer.apple.com/documentation/swiftui/grid
[a-groupbox]: https://developer.apple.com/documentation/swiftui/groupbox
[a-nsbox]: https://developer.apple.com/documentation/appkit/nsbox
[a-disclosure]: https://developer.apple.com/documentation/swiftui/disclosuregroup
[a-picker]: https://developer.apple.com/documentation/swiftui/picker
[a-group]: https://developer.apple.com/documentation/swiftui/group
[a-divider]: https://developer.apple.com/documentation/swiftui/divider
[a-lazygrid]: https://developer.apple.com/documentation/swiftui/lazyvgrid
[a-swifttable]: https://developer.apple.com/documentation/swiftui/table
[a-scrollview]: https://developer.apple.com/documentation/swiftui/scrollview
[a-nsscrollview]: https://developer.apple.com/documentation/appkit/nsscrollview
[a-button]: https://developer.apple.com/documentation/swiftui/button
[a-prominent]: https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/borderedprominent
[a-glassprominent]: https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/glassprominent
[a-bordered]: https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/bordered
[a-nsbutton]: https://developer.apple.com/documentation/appkit/nsbutton
[a-help]: https://developer.apple.com/documentation/swiftui/view/help(_:)
[a-buttonrole]: https://developer.apple.com/documentation/swiftui/buttonrole
[a-keyboardshortcut]: https://developer.apple.com/documentation/swiftui/view/keyboardshortcut(_:)
[a-toggle]: https://developer.apple.com/documentation/swiftui/toggle
[a-togglestyle]: https://developer.apple.com/documentation/swiftui/togglestyle
[a-menupicker]: https://developer.apple.com/documentation/swiftui/menupickerstyle
[a-segmentedpicker]: https://developer.apple.com/documentation/swiftui/segmentedpickerstyle
[a-radiopicker]: https://developer.apple.com/documentation/swiftui/radiogrouppickerstyle
[a-textfield]: https://developer.apple.com/documentation/swiftui/textfield
[a-securefield]: https://developer.apple.com/documentation/swiftui/securefield
[a-texteditor]: https://developer.apple.com/documentation/swiftui/texteditor
[a-textview]: https://developer.apple.com/documentation/appkit/nstextview
[a-stepper]: https://developer.apple.com/documentation/swiftui/stepper
[a-slider]: https://developer.apple.com/documentation/swiftui/slider
[a-datepicker]: https://developer.apple.com/documentation/swiftui/datepicker
[a-text]: https://developer.apple.com/documentation/swiftui/text
[a-link]: https://developer.apple.com/documentation/swiftui/link
[a-textselection]: https://developer.apple.com/documentation/swiftui/view/textselection(_:)
[a-commands]: https://developer.apple.com/documentation/swiftui/commands
[a-commandgroup]: https://developer.apple.com/documentation/swiftui/commandgroup
[a-commandmenu]: https://developer.apple.com/documentation/swiftui/commandmenu
[a-contextmenu]: https://developer.apple.com/documentation/swiftui/view/contextmenu(menuitems:)
[a-nsmenu]: https://developer.apple.com/documentation/appkit/nsmenu
[a-menu]: https://developer.apple.com/documentation/swiftui/menu
[a-menuitem]: https://developer.apple.com/documentation/appkit/nsmenuitem
[a-focusedvalue]: https://developer.apple.com/documentation/swiftui/focusedvalue
[a-responder]: https://developer.apple.com/documentation/appkit/nsresponder
[a-focusstate]: https://developer.apple.com/documentation/swiftui/focusstate
[a-onhover]: https://developer.apple.com/documentation/swiftui/view/onhover(perform:)
[a-cursor]: https://developer.apple.com/documentation/appkit/nscursor
[a-transferable]: https://developer.apple.com/documentation/coretransferable/transferable
[a-dragdestination]: https://developer.apple.com/documentation/appkit/nsdraggingdestination
[a-undo]: https://developer.apple.com/documentation/foundation/undomanager
[a-sheet]: https://developer.apple.com/documentation/swiftui/view/sheet(ispresented:ondismiss:content:)
[a-popover]: https://developer.apple.com/documentation/swiftui/view/popover(ispresented:attachmentanchor:arrowedge:content:)
[a-nspopover]: https://developer.apple.com/documentation/appkit/nspopover
[a-alert]: https://developer.apple.com/documentation/swiftui/view/alert(_:ispresented:actions:message:)
[a-nsalert]: https://developer.apple.com/documentation/appkit/nsalert
[a-confirmationdialog]: https://developer.apple.com/documentation/swiftui/view/confirmationdialog(_:ispresented:titlevisibility:actions:message:)
[a-nspanel]: https://developer.apple.com/documentation/appkit/nspanel
[a-fileimporter]: https://developer.apple.com/documentation/swiftui/view/fileimporter(ispresented:allowedcontenttypes:allowsmultipleselection:oncompletion:)
[a-fileexporter]: https://developer.apple.com/documentation/swiftui/view/fileexporter(ispresented:document:contenttype:defaultfilename:oncompletion:)
[a-openpanel]: https://developer.apple.com/documentation/appkit/nsopenpanel
[a-savepanel]: https://developer.apple.com/documentation/appkit/nssavepanel
[a-dismiss]: https://developer.apple.com/documentation/swiftui/dismissaction
[a-settings]: https://developer.apple.com/documentation/swiftui/settings
[a-tabview]: https://developer.apple.com/documentation/swiftui/tabview
[a-photospicker]: https://developer.apple.com/documentation/photosui/photospicker
[a-workspace]: https://developer.apple.com/documentation/appkit/nsworkspace
[a-uttype]: https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct
[a-quicklook]: https://developer.apple.com/documentation/swiftui/view/quicklookpreview(_:)
[a-previewpanel]: https://developer.apple.com/documentation/quicklookui/qlpreviewpanel
[a-videoplayer]: https://developer.apple.com/documentation/avkit/videoplayer
[a-playerview]: https://developer.apple.com/documentation/avkit/avplayerview
[a-sharelink]: https://developer.apple.com/documentation/swiftui/sharelink
[a-sharepicker]: https://developer.apple.com/documentation/appkit/nssharingservicepicker
[a-notificationcenter]: https://developer.apple.com/documentation/usernotifications/unusernotificationcenter
[a-capturedevice]: https://developer.apple.com/documentation/avfoundation/avcapturedevice
[a-unavailable]: https://developer.apple.com/documentation/swiftui/contentunavailableview
[a-progress]: https://developer.apple.com/documentation/swiftui/progressview
[a-smooth]: https://developer.apple.com/documentation/swiftui/animation/smooth
[a-animationvalue]: https://developer.apple.com/documentation/swiftui/view/animation(_:value:)
[a-withanimation]: https://developer.apple.com/documentation/swiftui/withanimation(_:_:)
[a-contenttransition]: https://developer.apple.com/documentation/swiftui/view/contenttransition(_:)
[a-symboleffect]: https://developer.apple.com/documentation/swiftui/view/symboleffect(_:options:value:)
[a-reducemotion]: https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion
[a-transaction]: https://developer.apple.com/documentation/swiftui/transaction
[a-adoptingglass]: https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
[a-glasscontainer]: https://developer.apple.com/documentation/swiftui/glasseffectcontainer
[a-animations]: https://developer.apple.com/documentation/swiftui/animations
[a-secondaryfill]: https://developer.apple.com/documentation/appkit/nscolor/secondarysystemfill
[a-glassbutton]: https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/glass
[a-glasseffect]: https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)
[a-toolbarspacer]: https://developer.apple.com/documentation/swiftui/toolbarspacer
