---
name: butler-ghost-text-not-a-blocker-or-authorization
description: "Refines butler-ghost-text-not-input with 2026-07-21 evidence: Claude Code's ghost/autocomplete text renders in a visually distinct gray and does not concatenate with what's typed over it. Two symmetric failure directions, and the second is the sharper one: do not treat parked ghost text as a BLOCKER (withholding a safe dispatch costs real time) and do not treat it as an AUTHORIZATION (acting on it can be irreversible). Ghost text is generated FROM the visible pending context, so it reliably resembles the exact plausible next instruction, not noise. Interim workaround (until cc-butler#6 exposes the face property properly): measure the text-property face directly via emacsclient rather than inferring from behavior."
metadata:
  node_type: memory
  type: feedback
---

Evidence gathered 2026-07-21, refining [[butler-ghost-text-not-input]] (which
correctly identified the phenomenon but, lacking this evidence, treated *any*
parked input-line text as occupied/dangerous by default, with no way to
distinguish the harmless case from the rare real one).

## What was actually measured

- **Ghost text and real text render with different colors.** Inspected live
  buffer text properties directly: ghost renders `#a7a7a7` on `#262626`; real
  typed/submitted text renders `#eeeeee` on `#373737`/`#ffffff`. The
  separation is clean, not a judgment call.
- **Ghost text does NOT concatenate with what's sent over it.** Confirmed
  three independent ways: (1) a control experiment — sending a message into a
  session with gray parked text produced a submitted line containing *only*
  the new message, nothing prepended; (2) a live case — a `/compact` sent to
  `monocle-server-side-orchestration` displaced the gray parked `merge #1361`
  and submitted alone, cleanly; (3) 정수님 directly confirmed these parked
  lines are Claude Code's own suggestions, not anything he or anyone typed.

## Two symmetric failure directions — the SECOND is the sharper one

**Direction 1 — false blocker.** Treating parked ghost text as a live
obstacle and withholding a safe action because of it. Cost measured today:
`monocle-server-side-orchestration` sat at 561k context — over the
400k/500k tolerance in [[butler-context-ceiling-and-compaction]], on the
wrong model, uncompactable — because `merge #1361` sitting on its input line
was treated as a blocker. It was a phantom the entire time. An unnecessary
clearing action was escalated to 정수님 for a problem that did not exist, and
four other sessions were tiptoed around for the same non-reason.

**Direction 2 — false authorization.** Treating parked ghost text as a
human's actual instruction and acting on it — this is the more dangerous
direction, because the action taken is often irreversible. Measured case:
the butler's own input line showed, across three separate reads,
`PR #72 머지 진행해주세요` ("please go ahead and merge PR #72") — reading
exactly like 정수님 approving a pending merge decision. Measured directly
rather than inferred:
```elisp
(:line #("❯ PR #72 머지 진행해주세요" 2 18
         (face (:foreground "#a7a7a7" :background "#262626"))))
```
Ghost — `#a7a7a7`/`#262626`, the same signature as direction 1's phantom. Had
either butler or steward acted on it, a PR would have been merged on a real
repo without 정수님's actual approval, and reported back to him as done at
his own instruction — a false report of consent, not just a false blocker.

**Why this direction is dangerous in a way that isn't obvious.** Ghost text
is generated *from the visible pending context* — it is Claude Code's own
prediction of the most plausible next line, given what's on screen. It does
not resemble noise; it resembles *the thing you were waiting for*. A
suggestion engine reading the same screen you are will propose the same next
step you were hoping to hear — which means **the more genuinely pending a
decision is, the more convincing the phantom authorizing it will be.** The
cases where this is riskiest (a real pending decision, a plausible-sounding
approval sitting right there) are exactly the cases where a false positive
is most tempting to accept at face value.

## The rule (both butler and steward)

1. **Do not treat a parked line as a reason to withhold a dispatch.**
   Confirmed-ghost text is inert — it does not concatenate, does not need
   protecting against, and a dispatch sent over it lands clean.
2. **Do not treat a parked line as an instruction to act on — in either
   direction.** Not as a task to do, and not as an approval/authorization to
   proceed on something already pending. It was never asked for. (This
   reaffirms, and sharpens for the authorization case, the "confirm
   submission before acting" duty already in [[butler-ghost-text-not-input]].)
3. **Prefer measurement over inference.** An earlier, sound-seeming judgment
   call — "this parked line grew between two reads, so it must be someone
   really typing" — is still only inference, and inference is not good
   enough here given how plausible a ghost-generated line can look. Once a
   direct measurement of the `face` property is available, use it instead
   of behavioral inference.
4. **Fail-safe while the signal is unreadable.** `read_session_output`
   returns `buffer-substring-no-properties`, which strips the `face`
   property — the only signal that distinguishes ghost from real text
   (root cause filed as **cc-butler#6**, sibling of #4: both are cases where
   the observation tool omits exactly the signal needed to tell two states
   apart that call for opposite correct actions). When the signal cannot be
   read, **treat the line as REAL and abort** — do not dispatch through it
   (direction 1's caution) and do not act on it as authorization (direction
   2's caution). Never optimistically classify an unreadable signal as
   ghost in either direction.
5. **Once the color IS readable, act on it.** Confirmed gray (`#a7a7a7` on
   `#262626`) → ghost: proceed with the dispatch (rule 1) and do not treat it
   as authorization (rule 2). Confirmed near-white/real → treat as an actual
   pending human message: hold the dispatch and do not proceed on the
   apparent authorization without independent confirmation.

## Interim workaround (until cc-butler#6 ships a proper fix)

Measure the face property directly via `emacsclient`, rather than reasoning
about it from `read_session_output`'s stripped text or from behavioral
inference:

```elisp
(emacsclient -e '(with-current-buffer "*claude-code[SESSION]*"
  (save-excursion (goto-char (point-max))
    (while (> (point) (point-min))
      (forward-line -1)
      (let ((l (buffer-substring (line-beginning-position) (line-end-position))))
        (when (string-prefix-p "❯ " l)
          (return (get-text-property (+ (line-beginning-position) 3) (quote face)))))))))
```

`#a7a7a7` on `#262626` → ghost, ignore (safe to dispatch over, not an
authorization). `#eeeeee` (or any non-ghost color) → real, treat as the
human's actual words. Run this before acting on any parked line, in
**either** direction — as a blocker or as an authorization — until
`read_session_output` itself carries this distinction.

## What this does and does not change

This **refines** [[butler-ghost-text-not-input]]: its "confirm before acting
FROM it" and "confirm before relaying INTO it" duties stand, but the
*reasoning* changes — parked text is not inherently dangerous to dispatch
over, and a tooling blind spot (not a property of ghost text itself) is the
only reason either direction still needs caution today.

This does **not** touch [[butler-relay-safe-worker-decisions]] — the
`AskUserQuestion`/live-wizard-swallows-Enter hazard is a different failure
mode entirely (an *active interactive menu* consuming a relay's Enter), not
passively-parked autocomplete text, and remains fully in force, unchanged.
