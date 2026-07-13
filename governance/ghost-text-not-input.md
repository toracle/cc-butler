---
name: butler-ghost-text-not-input
description: "Text visible in a session's input line is NOT necessarily a submitted message — Claude Code renders ghost/autocomplete suggestions that LOOK like typed input but were never sent; before relaying INTO that line (your Enter collides) or inferring intent FROM it, confirm it was actually SUBMITTED (appears in the transcript), not an unsent suggestion"
metadata:
  node_type: memory
  type: feedback
---

Recurring issue (2026-07-13): Claude Code renders prompt auto-suggestions /
ghost (autocomplete) text directly in a session's input line. It *looks* like
typed input sitting there ready — but it was never submitted. Twice this
session, text visible in the steward's input line (e.g. *"Route the same
learning to worker dispatch reminders"*) turned out to be a ghost/autocomplete
suggestion, **not** 정수님's actual instruction.

The butler handled both correctly: (a) it **held its relay** rather than
sending over that occupied-looking input line, and (b) it did **NOT** treat the
ghost text as a command to act on. Both halves matter — the danger is
symmetric.

This is the same family as [[butler-relay-safe-worker-decisions]] and
[[butler-worker-relay-prompt-safety]] (an occupied input line is dangerous to
send Enter into) crossed with [[butler-no-overinterpret]] (do not read intent
into a surface that was never asserted).

**Lessons (durable):**
1. **A visible input-line string is not a message.** It may be a ghost /
   autocomplete suggestion the session rendered, still sitting *unsent*. It is
   not consent, not an instruction, and not necessarily even real input.
2. **Confirm submission before acting FROM it.** Only treat text as a real
   message/instruction once you can see it was actually SUBMITTED — it appears
   in the conversation/transcript, not just parked in the input box.
3. **Confirm before relaying INTO that line.** If you are about to
   `send_to_session` a session whose input line already shows unexpected text,
   your one submit-Enter will collide with (or append to) whatever is sitting
   there. Treat the line as occupied/unsafe until proven clear.
4. **Ghost until proven submitted.** Default assumption for unexpected
   input-line text is "possibly a ghost suggestion," not "a command someone
   left for me."

**How to apply:** [as butler/steward] when you see unexpected text in a target
session's input line, do NOT act on it as content and do NOT assume your relay
is safe — treat it as possibly-ghost until you have positive evidence it was
submitted (it shows in the transcript). Related:
[[butler-relay-safe-worker-decisions]], [[butler-worker-relay-prompt-safety]],
[[butler-no-overinterpret]].
