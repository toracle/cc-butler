# cc-butler showcase

Faithful renders of cc-butler's surfaces, for the top-level README.

## How these are captured (and the finding)

The agent probed whether it can capture surfaces directly through Emacs:

- The live daemon's frames are **terminal** (`window-system nil`), so
  `x-export-frames` → PNG/SVG is **not** available headless (it needs a
  graphical frame).
- **`htmlize` works headless** — it renders a fontified buffer to CSS-colored
  HTML. So the agent CAN capture any surface faithfully, as HTML, with no GUI.

Regenerate the assets:

```sh
emacs -Q --batch -l docs/showcase/capture-showcase.el
```

For raster **PNG** (e.g. GitHub README images): open a surface in a GUI Emacs
and screenshot, or render these `.html` files in a browser and capture. The
HTML is the runtime-neutral, reproducible source.

## Surfaces

| file | surface |
|------|---------|
| `decision.html` | an answerable decision document — envelope (`From`/`Via`), options, and the `C-c C-c` answer region |
| `briefing.html` | an up-direction worker briefing (read-only, optional reply) |
| `inbox.html` | the inbox list (`i`) — the pending queue, `f` to switch folders |

The **session-list sidebar** (ops) and **in-session** surfaces are live
terminal buffers; capture those from a GUI Emacs or a terminal dump (a follow-on
if raster images are wanted for the README).
