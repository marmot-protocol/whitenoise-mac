# GIF playback admission

Downloaded GIPHY bytes pass `GIFPlaybackAdmission` before ImageIO inspection or
AppKit playback. The URL's extension, advertised rendition dimensions, display
size, and encoded byte count are not trusted as decoded-resource limits.

The starting policy is:

- At most 5 MiB encoded bytes (the existing GIPHY download limit).
- Positive logical canvas dimensions, at most 4096 pixels on either edge.
- Between 2 and 1000 image frames, all rectangles inside the logical canvas.
- At most 32 Mi logical-canvas pixels across all frames, checked by division
  before processing frame data. Partial frames still incur a full compositing
  canvas, so a tiny rectangle does not evade this budget.
- A complete container with a trailer and no trailing data. Supported extensions
  are graphics control, application data, and comments; plaintext/unknown rendering
  extensions are refused rather than assigned an implicit resource budget.

The parser skips bounded color tables and sub-blocks without decompressing pixels.
Only admitted bytes reach ImageIO, with caching disabled for source inspection.
ImageIO must recognize a complete GIF with the same frame count. Playback uses
the logical canvas aspect ratio rather than the first partial frame's rectangle.
Initial loading, legacy MP4 lookup, and retry all use this preparation path.

## Compatibility qualification

Header-only inspection of ordinary vendor renditions on 2026-10-03 produced:

| Rendition | Encoded bytes | Canvas | Frames | Aggregate canvas pixels |
|---|---:|---|---:|---:|
| `JIX9t2j0ZTN9S/giphy.gif` | 1776311 | 480 × 480 | 24 | 5529600 |
| `3o7TKMt1VVNkHV2PaE/200.gif` | 239337 | 200 × 200 | 96 | 3840000 |
| `3o7TKMt1VVNkHV2PaE/giphy.gif` | 639904 | 500 × 500 | 96 | 24000000 |

These are small and larger, shorter and longer ordinary renditions within the
existing preferred 2 MiB file budget. They use graphics-control and application
extensions, and fit the initial resource policy. Source URLs use
`https://media.giphy.com/media/` followed by the rendition above. Exact sample
SHA-256 values, in table order:

```text
5d53be905f5e3e8c0406a13f4fea74850966e6d356f42caed827b2f015e1e82c
7a126599836d07bd9b556a0e57294ec067065f87050e19909dc45e7b49231d70
943d75e2157f2c610c6d3fc49a404b9d09990df8fe13b0e55095745bb55228cf
```

This sample is not the entire vendor catalog, and header inspection is not a
native playback test. Long or high-resolution animations may intentionally be
refused and show the existing failed state. Test changes to these limits against
both ordinary renditions and tiny boundary fixtures; never raise a limit merely
to admit an untrusted file.

These admission ceilings do not prove a total AppKit memory ceiling or prevent
every native codec defect. Keep OS codec security updates current. The native
macOS test plan covers rejection boundaries without allocating oversized rasters.
