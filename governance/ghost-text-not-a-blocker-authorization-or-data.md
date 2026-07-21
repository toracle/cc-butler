---
name: butler-ghost-text-not-a-blocker-authorization-or-data
description: "Refines butler-ghost-text-not-input with 2026-07-21 evidence: Claude Code's ghost/autocomplete text renders in a visually distinct gray and does not concatenate with what's typed over it. THREE failure directions, escalating: do not treat parked ghost text as a BLOCKER (withholding a safe dispatch costs real time), not as an AUTHORIZATION (acting on it can be irreversible), and not as DATA (it can fabricate a precise, plausible answer to a diagnostic question no human actually answered). Ghost text is generated FROM the visible pending context, so it reliably resembles the exact plausible next line — a sharper, more falsifiable question attracts a MORE convincing fabricated answer, not a less convincing one. Interim workaround (until cc-butler#6 exposes the face property properly): measure the text-property face directly via emacsclient rather than inferring from behavior."
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

## Three failure directions, escalating

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

**Direction 3 — fabricated data. The most dangerous of the three.**
Treating parked ghost text as an actual answer to a question and using it as
evidence. Measured case, an hour after direction 2: the butler had asked
정수님 a specific diagnostic question about a live macOS dictation defect —
does the early text appear on screen during dictation and then vanish, or
was it never there at all? A precisely framed, falsifiable question designed
to split the hypothesis space: "never there" points to capture/buffer loss,
"appears then vanishes" points to render/paste loss. The butler's input line
showed:
```
처음부터 없었어요. 스테이징 빌드로 다시 테스트해볼게요
```
("It wasn't there from the start. I'll re-test on the staging build.") —
measured directly:
```elisp
(:face (:foreground "#a7a7a7" :background "#262626"))
```
Ghost. It answered the diagnostic question precisely, in the exact
load-bearing vocabulary the question was framed in, with a plausible
follow-up commitment attached that would have left a worker waiting on a
test no human ever agreed to run. Had it been relayed as 정수님's answer, the
investigation would have eliminated an entire family of causes on the
strength of a sentence he never said — and it would have looked like a
clean, decisive datum, which is the most *trusted* kind of finding and here
completely hollow.

**Why this direction is the counter-intuitive one.** Ghost text continues
whatever is visible and pending. When what's pending is a *question*, the
single most plausible continuation is an *answer* — so **a sharper, more
falsifiable diagnostic question does not protect you here; it attracts a
more convincing fabricated answer, precisely because it's a better-designed
question.** This is a genuinely nasty interaction between two disciplines
that are each individually correct — asking sharp, hypothesis-splitting
questions, and acting decisively on what comes back. The standard must go
*up*, not down, exactly when an answer looks clean and on-point: plausibility
here is the symptom of ghost text doing its job well, not reassurance that
the answer is real.

## The rule (both butler and steward)

1. **Do not treat a parked line as a reason to withhold a dispatch.**
   Confirmed-ghost text is inert — it does not concatenate, does not need
   protecting against, and a dispatch sent over it lands clean.
2. **Do not treat a parked line as an instruction to act on, an approval to
   proceed on, or data to reason from.** Not a task, not an authorization,
   not evidence — in all three directions it was never asked for and never
   given. (This reaffirms, and now extends to the data case, the "confirm
   submission before acting" duty already in [[butler-ghost-text-not-input]].)
3. **The standard goes UP, not down, when the content is exactly what you
   were hoping to hear.** Plausibility is the symptom of ghost text doing
   its job well, not a reason to relax scrutiny — a decisive-looking answer
   to a sharp diagnostic question is exactly the shape a fabrication takes.
4. **Measure before relaying anything that arrives on an input line —
   prefer measurement over inference.** An earlier, sound-seeming judgment
   call — "this parked line grew between two reads, so it must be someone
   really typing" — is still only inference, and inference is not good
   enough here given how plausible a ghost-generated line can look, whether
   it's posing as a blocker, an approval, or an answer. Once a direct
   measurement of the `face` property is available, use it instead of
   behavioral inference.
5. **Fail-safe while the signal is unreadable.** `read_session_output`
   returns `buffer-substring-no-properties`, which strips the `face`
   property — the only signal that distinguishes ghost from real text
   (root cause filed as **cc-butler#6**, sibling of #4: both are cases where
   the observation tool omits exactly the signal needed to tell two states
   apart that call for opposite correct actions). When the signal cannot be
   read, **treat the line as REAL and abort** — do not dispatch through it
   (direction 1), do not act on it as authorization (direction 2), and do
   not relay or reason from it as data (direction 3). Never optimistically
   classify an unreadable signal as ghost in any of the three directions.
6. **Once the color IS readable, act on it.** Confirmed gray (`#a7a7a7` on
   `#262626`) → ghost: proceed with the dispatch (rule 1), and do not treat
   it as authorization or data (rules 2–3). Confirmed near-white/real →
   treat as an actual pending human message: hold the dispatch and do not
   proceed on the apparent authorization or datum without independent
   confirmation.

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

`#a7a7a7` on `#262626` → ghost, ignore (safe to dispatch over; not an
authorization; not data to reason from). `#eeeeee` (or any non-ghost color)
→ real, treat as the human's actual words. Run this before acting on any
parked line, in **any** of the three directions — as a blocker, as an
authorization, or as data — until `read_session_output` itself carries this
distinction. Two real instances an hour apart, in different failure
directions (the PR #72 false authorization above, and the dictation
diagnostic false-data case), is what gives this its teeth: this is not a
single anecdote, it is a recurring shape.

## What this does and does not change

This **refines** [[butler-ghost-text-not-input]]: its "confirm before acting
FROM it" and "confirm before relaying INTO it" duties stand, but the
*reasoning* changes — parked text is not inherently dangerous to dispatch
over, and a tooling blind spot (not a property of ghost text itself) is the
only reason any of the three directions still needs caution today.

This does **not** touch [[butler-relay-safe-worker-decisions]] — the
`AskUserQuestion`/live-wizard-swallows-Enter hazard is a different failure
mode entirely (an *active interactive menu* consuming a relay's Enter), not
passively-parked autocomplete text, and remains fully in force, unchanged.
