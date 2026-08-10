---
name: fixing-one-instrument-flaw-does-not-validate-the-instrument
description: "One DNS probe produced four different measurement artifacts in a single night — a timeout ceiling, a second ceiling, sequential ordering bias, a wrong-target code path, and a wait-reap ordering bug. Each fix revealed the next, and each artifact was subtler and more convincing than the last. The most persuasive-looking result of all — two resolvers with 6x-different budgets agreeing to 3ms — was pure instrument. After one artifact, suspect the instrument before the world on every later surprise. A later instance: an unverified mic-routing trace nearly overruled a human's direct observation — keep at least one pre-registered acceptance criterion that does not read any instrument."
metadata:
  node_type: memory
  type: feedback
---

**The incident (dealmatch + steward, 2026-08-03/04).** A standing DNS probe on an office CI runner was the sole
instrument for diagnosing intermittent lookup failures. In one night it produced **five wrong readings, of four
structurally different kinds**, and every one of them was believed at the time:

1. **Ceiling clipped (8s).** Seven failures at exactly `8.002s`, read as "a configured timeout's fingerprint."
   It was the probe's own `timeout 8` wrapper. See [[suspiciously-uniform-is-the-instruments-fingerprint]].
2. **Ceiling clipped again (30s).** After raising the wrapper to 30s, failures landed at `30.001985842s` and
   `30.002203662s` — **the same artifact, re-struck at the new limit.** Raising a ceiling does not stop you
   measuring the ceiling; it moves the number.
3. **Ordering bias.** The probe ran the host lookup *to completion*, then started the container lookup. So
   `host=ok + container=fail` was structurally near-impossible to observe — and its **zero count had been used
   all night as load-bearing evidence** that failures originate upstream of Docker. Rebuilt to run in parallel,
   it observed that exact combination within minutes.
4. **Wrong target.** The probe measured `getent hosts`, which on both glibc and musl calls AAAA and then A
   *separately* (5s+5s on musl, up to 30s+30s on glibc). Real CI failures go through Node's
   `getaddrinfo(AF_UNSPEC)`, which does not. **The probe's headline durations described a code path nothing in
   CI takes.** Distortion can be corrected; measuring a different target cannot.
5. **Reap-order aliasing.** `wait "$hpid"` then `wait "$cpid"`: the container arm finishes first, so its recorded
   end time was **not when it finished but when we got around to reaping it** — `hend + ε`.

**The fifth one is the one worth studying, because it looked like the best evidence of the night.** It presented
as: the host arm (glibc, ~60s budget) and container arm (musl, ~10s budget) completing within **3ms** of each
other, repeatedly. The reasoning drawn from it was sound *given the data* — two independent timers with 6×
different budgets cannot coincide to a millisecond, so a **shared external event** must have released both,
pointing at the router/uplink rather than the resolver. Elegant, and it dissolved a standing arithmetic puzzle
(a container failure at 19.766s despite musl's 10s ceiling).

All of it was `wait` ordering. `celapsed ≈ helapsed + ε` was **guaranteed by the script** and carried zero
information about the world. Three accumulated "synchronisation" observations were retired.

**So: apparent signal quality is not evidence of signal.** The cleanest, most theory-confirming, most
quantitatively striking result the instrument ever produced was the one with no content at all. An unaudited
instrument generates its most convincing artifacts exactly where its structure is tightest.

**How to apply.**
1. **After the first artifact, invert your prior.** Do not treat a fixed instrument as a cleared instrument. Once
   a measurement apparatus has fooled you once, the base rate says it will again — **suspect the instrument
   before the world on every subsequent surprising result**, and say so out loud so the check actually happens.
2. **Fixing a flaw finds the next flaw; it does not validate the instrument.** Each repair here exposed a deeper
   one, in *increasing* order of subtlety: wrapper → wrapper → control flow → wrong binary → process reaping. Budget
   for that instead of declaring victory after a fix.
3. **When a result is strikingly clean, read the measuring code before theorising.** Concretely: does each arm
   stamp *its own* start and end, or are values derived from a shared boundary (`wait`, a common timer, one
   enclosing `timeout`)? A value computed from a common boundary is a property of the script.
4. **Verify the fix produced new observability, not just new numbers.** The parallel rebuild was confirmed by
   immediately observing the combination that had been impossible before — a prediction that could have failed.
   That, not the absence of errors, is what makes a repaired instrument trustworthy.
5. **Retire the data, not just the conclusion.** Pre-fix samples carry the pre-fix bias. Mark the changeover in
   the log and start the count again rather than pooling; and state which specific claims died.
6. **"Its support was fake" is not "it is refuted."** The shared-path hypothesis went back to *undetermined*, not
   rejected — the evidence for it evaporated, but nothing argued against it. Collapsing those two is how a live
   hypothesis gets wrongly buried alongside its bad evidence.
7. **The worker found four of these five itself, unprompted, against its own prior conclusions.** That is the
   behaviour that made the investigation worth trusting at all, and it is expensive to acquire and cheap to
   suppress. Say so when it happens.

**A sixth instance, on a different instrument, hours after this note was written — and it proves the thesis harder
than the DNS probe did.** A skills-triggering evaluation harness had run **three** sweeps whose isolation was
explicitly verified. The verification checked for **stale artifacts** — old filenames from prior runs, `find`
sweeps, `ls` spot-checks — and honestly returned "clean" every time. It was clean *on that axis*. Two things it
structurally could not see:

- **Live cross-contamination.** Cases read the harness's own `driver.log` *while the sweep was running* — other
  cases' real-time results — and one climbed into `archive/` and found the investigation's own pre-registration
  documents. 14 of 36 transcripts in the "clean" run showed it.
- **The naming leak, which was worse.** Every case directory was named after the skill under test
  (`run-005-bug-fix-driven-development-5`). That discloses the answer **passively, to every case, in every
  sweep, via a single `pwd`** — no curiosity required. The live-log reading needed a wandering model; this
  needed nothing. So the experiment was partly measuring *whether a model can read its own working directory*.

Every corpus number from the entire investigation — **including the baselines the whole effort was measured
against** — had to be withdrawn. The verdict that had been reported, and two rounds of remediation built on it,
rested on comparison against a fictional baseline.

**Three lessons specific to this instance:**
1. **"Verified isolation" names an axis, not a property.** Checking for stale artifacts says exactly nothing
   about live siblings. Before trusting any isolation claim, ask *which* contamination it could have detected.
2. **A detector never demonstrated to fire is not a detector.** Every check here returned "clean," and that was
   read as evidence. The fix adopted: a **bidirectional canary** — plant a leak, confirm the checker reports
   *contaminated*, remove it, confirm it reports clean. Same shape as [[a-test-that-cannot-fail-is-not-evidence]].
3. **Eliminate the channel, don't out-guess the explorer.** The remedy is anonymous per-case temp dirs with the
   log written by the parent outside the child's cwd ancestry — *no skill name in any path the child can see*.
   That is a checkable property; "no informative siblings nearby" was a hope about what a curious model wouldn't
   look at.

**And what survived, because separating that out is the whole job.** A constant present in *both* arms cannot
manufacture a difference between them: the naming leak was identical before and after, and the before-arm still
scored 0/6 — so the disclosure alone demonstrably did not cause firing, and the measured *improvement* stands
even though the *absolute rates* do not. "This change improves triggering" is supported; "it fires 100% of the
time" is not. Likewise a purely **textual** finding — a dropped trigger tag `root-cause analysis` against a
corpus prompt reading *"Track down the root cause"* — is a fact about two strings and needs no working
instrument at all. When an instrument collapses, sort claims by what actually rested on it.

**A seventh instance, on a third instrument — the only one where the instrument nearly overruled a direct
observation of the world (2026-08-03).** A mobile app's Bluetooth mic-routing fix was verified on a real
device. The human tester reported the headset mic working. The app's own input-device trace field said
"Built-in microphone" for every turn of the test. Both reviewers sided with the trace and were about to record
a *working* fix as failed. What settled it was an experimental condition, not a log: the tester had been **ten
metres from the phone** — a distance at which the built-in mic physically cannot pick up speech. No log was
read to reach that verdict. (The trace was wrong twice over: it read the *first* recording configuration on
the system rather than the app's own, and it read it at turn start, returning early before ever reaching the
branch that would have answered "Bluetooth".)

Two reasoning failures stacked, and both are worth naming:
- "The corrected instrumentation commit is in this build" was treated as "therefore the instrumentation is
  correct." Confirming *which* implementation is running says nothing about whether that implementation is
  right.
- "The old implementation over-reported; the symptom is under-reporting; so the old bug doesn't explain it —
  **therefore the new one is correct**." That last step has no support: it ruled out one known defect and never
  put "the new implementation is independently wrong" on the candidate list.

And pre-registration made it worse rather than better. The registered acceptance criterion was
`input_device == Bluetooth` — a criterion that **reads the instrument**. So when the instrument lied,
pre-registration did not catch the error; it *lent the error authority*, because "the acceptance criterion we
fixed in advance failed" is a hard sentence to argue with.

**Three lessons specific to this instance:**
1. **An unverified instrument cannot outrank a direct observation.** A log line, a trace field, a status probe
   is not evidence — it is an instrument that *produces* evidence. Until the instrument itself has been
   verified, its readings cannot overrule a direct observation of the world; when the two disagree, the first
   suspect is the instrument, not the world.
2. **Every pre-registered criteria set gets at least one instrument-independent member** — one a person can
   adjudicate without reading any output the system produced about itself. Ten metres. The app is on screen.
   The file exists. If every criterion reads an instrument, the instrument has quietly become the judge, and
   nobody is judging the judge.
3. **Do not adjudicate the disagreement from the armchair — ask what the human actually did.** The
   experimental conditions are usually the missing variable. And once the world and the instrument disagree
   and the world wins, the instrument becomes the bug, and it outranks the original task: every verdict built
   on it is now suspect.

Related: [[suspiciously-uniform-is-the-instruments-fingerprint]] (the first of these, and the narrower rule),
[[a-test-that-cannot-fail-is-not-evidence]] (a check that could not have come out differently),
[[a-stop-that-reports-success-is-not-a-stop]] (a status answering a different question than the one asked),
[[merging-agent-results-must-keep-per-claim-provenance]] (mark *observed* vs *inferred* in your own sentences).

**SPT:** the habit is *once an instrument has fooled you, audit it before every surprising result — treat its
most convincing output as its most suspect, and never let an unverified instrument outrank a direct observation.*
