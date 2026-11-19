Add native theme and layout decorations for the Winnow interface

Add composable callouts, full-width actions, subtitles/accessories, image assets, spacing, scaled point sizes, underlined text and navigation-bar control. The native renderer accepts app-provided colors and square-button/content-inset settings, allowing the Winnow Lean views to render their reviewed design with native controls.

> **DEPENDENCY NOTE.** This is the renderer prerequisite for the separate Winnow app UI submission. It contains no Winnow wallet data, app review catalog or generated native project. Please review and merge it before the app pins its final upstream revision.

The six-file change was reconciled onto LeanNative main `3f6303b58535128d4ccd9272df8f668f22a70012`, preserving subsequent framework work rather than replacing files from our older preview dependency. The four overlapping decoration changes retain both selectable-text support and the new presentation fields. Auth, Keychain, networking, signing and cloud capability implementations are unchanged from this baseline.

Validation: the framework Lean build and HTML/decoration tests pass, including selectable text and action dispatch. The generated UIKit renderer passes Objective-C syntax checking, and a native Winnow simulator review build using this renderer succeeds. The app's 56 presentation/action checks pass. Full device accessibility, keyboard and native interaction regression coverage remains to be run before release.

Branch: `codex/winnow-ui-renderer-20261119`. One commit; no AI coauthor trailer. After merging, use the resulting upstream commit for the app's Lake and workflow pins.
