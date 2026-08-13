---
name: butler-a-security-dod-needs-an-other-routes-axis
description: "A DoD for a security-boundary change that only asks 'does each declared check work?' will pass while the capability stays reachable by an undeclared route — add an explicit 'what else reaches this capability?' item, because that axis is what separates verifying the PR from verifying the surface"
metadata:
  node_type: memory
  type: feedback
---

A pre-registered DoD is the right instrument for a security change, but its
items inherit the *author's* threat model. Every item of the form "does check
N do what it claims?" is scoped to the list of checks someone already thought
to write. If the capability is reachable by a route nobody enumerated, a DoD
made only of such items passes — correctly — while the surface stays open.

So a security-boundary DoD needs at least one item of a different shape:
**what else reaches this same capability?** Not "does the declared block
work" but "if I wanted the effect the block exists to prevent, what other
paths get me there?"

**Why:** 2026-08-08, jarvice PR #1582 (MSSQL EngineDescriptor). Three
mutually-blind tracks verified it. The verify-first track
(monocle-jarvice-978) pre-registered ten DoD items before re-reading the
diff, refused to bend them to the code, reproduced every one directly rather
than trusting the PR body's test-plan checkboxes, and returned **9 MET / 1
NOT MET**. That work was genuinely rigorous — it caught a real regex
comment-injection bypass, confirmed it in a second independent session, and
verified a timeout enforcement live at 2.00s rather than accepting a
green test.

In parallel the exploratory-testing track (monocle-security) demonstrated
**two live bypasses that no DoD item covered**: `sys.fn_dblog` transaction-log
exfiltration, reproduced byte-exact, and the 4-part linked-server check
defeated eleven ways via dot-omission syntax (`linkedsrv..dbo.t`), where
sqlglot discards empty path components so `len(parts) >= 4` reads false.

Neither track was wrong. They measured different things — verify-first
against a pre-registered DoD ("did this PR do what it set out to do?"),
exploratory against the attack surface ("is the resulting surface safe?").
The ten items covered the declared checks thoroughly and the undeclared
routes not at all, because the DoD was built from what the PR claimed to
block. 978 reached this itself when shown the other tracks and named the
fix: an explicit "is there another route to the same capability" axis.

Note what this implies about substitution: a strong verify-first result is
**not** evidence that the surface is safe, and should never be reported as
if it were. The two questions can diverge, and on #1582 they did.

**How to apply:**

1. **Add the axis when writing the DoD, before reading the diff.** One item,
   phrased as capability not mechanism: "an attacker wants effect E — what
   paths reach E, and which does this PR close?" Derive it from the effect,
   not from the PR's list of blocks.
2. **Enumerate routes from the capability, not from the code.** Ask what the
   engine/API/protocol offers that produces the same effect, then check each
   against the implementation. Reading the diff first anchors you to the
   author's list — which is the failure being prevented.
3. **Suspect the parser's model wherever a check reads structure.** The
   linked-server bypass lived in the gap between sqlglot's AST and the real
   server's name resolution. Gaps like this are invisible to any amount of
   code reading and only appear when both are actually run — see
   [[a-true-observation-licenses-only-its-own-scope]].
4. **When both tracks are available, run both and report them separately.**
   Do not let a 9/10 MET summarize away a live bypass, and do not let a live
   bypass discredit sound DoD work. Report the divergence as a finding —
   it is the payoff of running independent tracks, not noise to reconcile.
5. **Single-track situations: borrow the question, not the whole track.**
   Where an exploratory track is not affordable, the "what else reaches this
   capability?" item is still cheap and catches the largest class of these.

Related: [[evaluation-independence]], [[verify-first]],
[[a-true-observation-licenses-only-its-own-scope]].
