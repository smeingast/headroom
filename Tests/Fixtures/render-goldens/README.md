# Menu-bar render goldens (pixel parity)

These fixtures pin `StatusRenderer` output so that any UNINTENDED rendering
drift fails the build.

## Baseline history

The corpus was captured twice, both times deliberately:

1. **Pre-package-4a** (`StatusRenderer.swift` at commit `00c7d6a`, "Codex
   sessions: interactive rows + exec summary"), to prove package 4a's new
   rendering parameters were dormant.
2. **v0.12, scoped model caps** — the current baseline. The weekly ring's
   resting alpha in the MENU-BAR glyph moved from 1.0 to
   `StatusRenderer.weeklyCalmAlpha` (0.5), matching what the panel had drawn
   since v0.8 and freeing opacity to signal "a window inside this week is at the
   wall". This is a visible change and was made on purpose.

   Exactly **50 of 320** cells moved: every `concentric` cell whose week value is
   non-nil and non-zero (5 such values x 5 modes x 2 appearances). No `single`,
   `bars` or `percentages` cell moved, and no concentric cell with a nil or zero
   week moved — which is the proof that only the weekly arc changed. Re-verify
   that arithmetic before ever regenerating again: a drift count that is not
   explained cell-for-cell is a bug, not a baseline.

The package-4a dormancy claim below still describes what the corpus tests; only
the pixels it compares against have moved.

The package-4a work adds new, dormant rendering parameters (a `provider` and
`role` on the color resolver, glyph pip / "Both" / dashed-track variants, and the
`ColorMode.claude` -> `.brand` rename). Dormancy means every existing call site
must produce **pixel-identical** output. `RenderDormancyParityTests` re-renders
each cell below through the post-4a renderer and asserts RGBA equality within a
+/-1/255 per-channel tolerance.

## What the grid covers

`styles x modes x values x appearances`:

- **styles (4):** `concentric`, `single`, `bars` (drawn via
  `StatusRenderer.image`), `percentages` (rasterized from
  `StatusRenderer.percentText`).
- **modes (5):** `brand`, `thresholds`, `monochrome`, `heatmap`, `accent`.
  The stable key `brand` maps to `ColorMode.claude` pre-4a and `ColorMode.brand`
  post-4a (see `colorMode(forKey:)` in `Tests/RenderParitySupport.swift`).
- **values (8):** `(five, week, projected)` tuples straddling both threshold
  edges (70 and 90) on both windows, plus the red >=90 override, the projected
  ghost arc, genuine zero, and the nil-window paths. See `renderGoldenValues`.
- **appearances (2):** `aqua` and `darkAqua`, pinned at draw time.

4 x 5 x 8 x 2 = **320 cells**, one `.rgba` file each (~1.6 MB total).

## Rendering method (the parity contract [R4])

For each cell: pin the `NSAppearance` (`aqua` / `darkAqua`) via
`performAsCurrentDrawingAppearance`, draw at a **fixed 1x scale** into an
**explicit sRGB `CGContext`** (8-bit, premultiplied-last), and store the **raw
RGBA bytes**. Never a TIFF/PNG container. Text (percentages) is rasterized onto a
fixed 100x18 canvas with the app's menu-bar font.

## File format

`<cell-id>.rgba`: an 8-byte little-endian header (`width`, `height` as `UInt32`)
followed by `width * height * 4` raw RGBA bytes. Cell id:
`<style>_<mode>_f<five>_w<week>_p<projected>_<aqua|dark>` (`nil` for absent
values).

## Regenerating (only intentionally, from the pinned renderer)

    CAPTURE_RENDER_GOLDENS=1 swift test --filter RenderGoldenCaptureTests

An ordinary `swift test` **never** rewrites these (the capture test is skipped
without the env var), so the parity test always compares new code against the
frozen pixels. Determinism was verified by capturing twice and confirming a
byte-identical directory (`diff -rq`), and that aqua vs darkAqua and the color
modes each produce distinct pixels.

**The capture DELETES this file.** It rewrites the directory wholesale, so
restore the README (`git checkout`) after any regeneration and record what moved
and why in the baseline history above. A regeneration with no note is
indistinguishable from an accident.
