# Feature audit — recreated Calculator & Paint vs. the real Windows apps

Reverse-engineered from the Windows Store binaries (`../REPORT.md`), the open-source
`microsoft/calculator` repo, and Microsoft's Paint docs. ✓ = implemented, ✗ = not yet (reason noted).
Logic verified by tests (`swiftc Engines.swift calctest.swift`, flood-fill/wstrings for Paint).

## Calculator
| Feature | Status |
|---|---|
| Standard (immediate exec, %, 1/x, x², √, ±) | ✓ |
| Memory MC/MR/M+/M−/MS + memory list | ✓ |
| History list, recall | ✓ |
| Scientific — precedence, DEG/RAD/GRAD, 2nd, log/ln, x^y, √, n!, π/e, () | ✓ |
| Scientific — **hyperbolic** sinh/cosh/tanh + inverse (HYP toggle), 10ˣ/eˣ, \|x\|, mod | ✓ |
| Programmer — HEX/DEC/OCT/BIN, AND/OR/XOR/NOT, LSH/RSH, mod | ✓ |
| Programmer — **word size QWORD/DWORD/WORD/BYTE** (masking + signed range) | ✓ |
| Programmer — **bit-toggle grid** (click individual bits) | ✓ |
| Programmer — **NAND/NOR**, **RoL/RoR** rotate | ✓ |
| Date calculation (difference; add/subtract) | ✓ |
| Converters ×12 | ✓ |
| **Graphing** — plot y=f(x), 3 equations, pan + zoom, auto grid/axes | ✓ |
| **Keep on top** (⇧⌘T floating window) | ✓ |
| Keyboard input, digit grouping | ✓ |
| Scientific — FE (sci-notation toggle), DMS | ✗ (minor) |
| Currency converter (live rates) | ✗ (needs network endpoint we extracted) |

## Paint
| Feature | Status |
|---|---|
| Pencil, Fill, Eraser, Colour picker, Airbrush | ✓ |
| Brushes ×6 (brush, marker, watercolour, crayon, calligraphy, oil) | ✓ |
| Text tool — **font family / size / bold / italic / colour** (format bar) | ✓ |
| Shapes gallery — 18 (line, **polygon**, rect, rrect, ellipse, triangles, diamond, pentagon, hexagon, 5/6-stars, 4 arrows, heart, **lightning**) | ✓ |
| Shape outline/fill (outline/solid/both) | ✓ |
| Colours — Color 1/2 (click-to-target), palette, edit colour | ✓ |
| Select (rectangular), move, cut/copy/paste, delete, transparent, select-all | ✓ |
| **Selection resize handles** (resize pasted/selected images) | ✓ |
| **Free-form (lasso) selection** | ✓ |
| Crop to selection | ✓ |
| Rotate 90° L/R, **Rotate 180°**, flip H/V | ✓ |
| **Resize image by scale (resample)** + resize canvas | ✓ |
| **Rulers & gridlines** toggle | ✓ |
| Layers (add/dup/delete/reorder/merge/visibility/opacity) | ✓ |
| Undo/redo (30 steps), zoom slider, status bar (coords + selection size) | ✓ |
| Open/Save PNG/JPEG/TIFF + **BMP/GIF** | ✓ |
| Canvas drag-resize handle at corner | ✗ (use Image ▸ Resize canvas) |
| Invert selection | ✗ (minor) |
| Print, set as wallpaper, image properties | ✗ (platform-specific) |
| AI (Cocreator, Image Creator, Reimagine, Magic eraser, bg removal) | ✗ by request |
