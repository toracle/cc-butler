---
name: butler-the-verified-half-licenses-the-unverified-half
description: "A true narrow fact welded to an untested inference ships as one statement, and the verified half vouches for the rest — the listener cannot see the seam, so name which half you actually measured."
metadata:
  node_type: memory
  type: feedback
---

The dangerous claim is rarely a false one. It is a **true fact carrying an
unverified inference on its back.** You measured something real, you drew the
obvious conclusion, and you sent both as a single sentence. The recipient sees
one claim backed by evidence — the seam between the measured part and the
inferred part is invisible from outside.

**Say which half you measured.** The listener cannot audit an inference they
cannot see, and the verified half is what makes the whole thing credible.

The pattern has a consistent shape: **a narrow true statement quietly widened** —
across time (past state → future cost), across population (one sample → the
category), or across category (infrastructure surfaces → all surfaces).

**Why:** On 2026-08-09 the steward did this four times in one day.

1. **Across time.** Escalating a merge, it wrote *"yesterday's result is identical
   under either rule"* — verified — and let that imply *"so reverting is cheap."*
   Never checked. Staging data had **already moved into the new rule's position**,
   so keeping the old rule meant not a code revert but values scattering across
   two rules on the next run. A worker caught it and flagged it for the approval
   thread. The recommendation survived; the "cheap to undo" impression had to be
   withdrawn — an approval granted on it would have rested on nothing.
2. **Across population.** A worker tested `logs:FilterLogEvents` on **one** log
   group and reported the permission present; the steward relayed *"not a
   blocker"* upward without re-measuring. Permissions were scoped **per log
   group** — two others were denied. Three reversals to 정수님 on one question.
3. **Across category.** *"The worker log group is our entire observation
   surface"* — true of infrastructure, false of surfaces. The chat and Sentry
   were both available, and two permission requests were sent up resting on that
   enumeration.
4. **Across definition.** Analysing a security gate, it collapsed *"unresolvable
   name"* into *"nonexistent name"* and concluded a rule bought nothing.
   Unresolvable also covers **existing orphan collections**, which the rule was
   the only thing blocking. The worker verified before editing on the steward's
   say-so and found the analysis half right.

5. **Across repository.** Having learned that morning that jarvice squash-merges —
   so `merge-base --is-ancestor` and `behind_by: 0` are permanently false there —
   the steward handed a different repo's worker the lesson as a universal:
   *"don't assume the promotion mechanism; verify by content
   (`git diff --stat origin/staging origin/devel` empty = fully promoted), which
   is **robust either way**."* The narrow fact was right. The widening was not:
   dealmatch's staging is a **release line** permanently carrying VERSION and
   CHANGELOG content devel never has, so the content check is false there too —
   for an entirely unrelated reason. **Two repos, two different reasons the naive
   check fails, and the fix for one was shipped as a general rule.** The worker
   caught it and did the right thing: it **narrowed the criterion to something
   that could actually be false** ("#1128's 9 files identical, residual diff is
   exactly those 4") and **wrote the prediction down before running the
   comparison**.

Every one began with something genuinely checked.

Instance 5 adds a wrinkle worth naming on its own: **the widening happened while
teaching.** Handing a lesson to someone else is where a fact gets compressed into
a rule, and compression is exactly where the measured edge gets sanded off. The
teaching voice ("always", "robust either way") is the widening voice.

6. **Across deployment mechanism.** Later the same day the same steward, having
   learned on jarvice to match a running image's SHA against the promoted commit,
   prescribed that check to dealmatch. **It is unanswerable there**: the staging
   image tag is the fixed string `:staging` (the workflow passes no `tags:` to
   `docker/metadata-action`), and the deploy re-registers no task definition — it
   calls `forceNewDeployment` on the *same* revision, re-pulling a mutable tag. A
   task definition's image URI can never identify a commit in that repo. The
   worker found the path that does work (digest → manifest → config blob → the
   OCI `org.opencontainers.image.revision` label) and then went further, adding a
   **behavioral** canary — running a non-discriminating case first to confirm a
   response field that exists only in the new code, on the grounds that a label
   says what the image *is*, not what the running code *does*.

7. **Across sample count — the same measurement counted twice.** Later the same
   day the steward wrote that a ~300s timeout "came up twice, so this is a
   structural ceiling rather than a one-off stall." Both numbers were real: 302.9s,
   measured carefully, twice. **They were the same run.** An earlier measurement and
   a later one had landed on one execution (schedule 49 = 08:30:00Z = 17:30 KST),
   and the steward filed them as two events. The worker caught it: *"제가 아까 잰
   302.9초와 방금 잰 302.9초는 같은 실행을 두 번 잰 것입니다. n=1입니다."*

   This form is worth naming separately because **nothing in it is false.** There is
   no bad measurement to find — auditing the number confirms it. The defect is in
   the *join*: two records pointing at one event, counted as two. And the conclusion
   it produced ("structural, not one-off") is precisely the kind that cannot be
   drawn from n=1 at all, so the fabricated sample was load-bearing.

   The tell is that a trend appeared without any new observation being made. **A
   frequency claim needs distinct events, and identity of events is a thing you
   check, not a thing you assume from having two records.**

   **A second counting failure the same evening, in the other direction, showed
   the cheap check.** A worker signing off wrote *"pushback happened four times,
   **two** of them the steward was wrong"* — and then **enumerated three**. It
   caught this itself on re-reading what it had just written, and the true count
   was three of four. The steward had meanwhile repeated the "two" back
   approvingly: it accepted a count **about its own errors, without checking, in
   the direction that flattered it.**

   Two counting errors in one day, from two different agents, on opposite sides of
   the same relationship. Neither was a hard fact to verify — and that is the
   point. **A count is a claim, but unlike other claims it carries no visible
   referent**, so nothing about it invites checking. The worker's fix is the
   general one: it wrote the number *and* the list, and the mismatch between them
   was self-announcing.

   **The third one the same night reached the human and bought an approval.** A
   production write was authorised on a stated scope of *"NICE 112 + KIS 159 =
   271 records."* Those were **lookup attempts, not writes**; the actual figure
   was **89 rows**. The operator approved a job three times larger than the real
   one. The worker caught it only when it opened the source files — and said the
   sharper thing about why:

   > *"열거가 검사가 되려면 열거할 원본이 곁에 있어야 합니다."*
   > (For enumeration to work as a check, the source you would enumerate has to be
   > at hand.)

   That is the refinement. "Write the list next to the number" is advice for the
   *author*, who still has the data. But **a count travelling upward gets stripped
   of its decomposition at the first hop**, and every recipient after that is
   structurally unable to check it — not careless, unable. `271` went author →
   steward → butler → operator, and only the author could ever have expanded it.
   By the time it was load-bearing for a decision, it was unfalsifiable.

   So a count that will be relayed must **carry its decomposition with it**, or it
   arrives as a bare assertion no one downstream can audit. Note the direction of
   the failure: the number did not get corrupted in transit. It was *correct about
   something else*, and the label travelled while the referent did not.

   **The same night, the same defect turned up in product code — which is where
   this stops being a communication rule.** A code review of dealmatch's admin
   tooling found that the bulk-update response returns
   `agency/updated/unchanged/skipped/skipped_count` but **not `received`** — the
   number of rows the caller actually sent. The worker named the shape exactly:
   the response carries **the left side of its own reconciliation and leaves the
   right side to the caller's memory.**

   That is `271` again, in an API. The invariant
   (`received == updated + unchanged + skipped`) is unfalsifiable from the
   response alone; verifying it requires a value the response does not carry, so
   every consumer downstream is structurally unable to check it. Adding
   `received` makes the response **self-auditing** — the mismatch announces
   itself, exactly as writing the list next to the count does.

   So the rule generalises past agent-to-agent relay: **any value that will be
   read somewhere other than where it was computed must carry what is needed to
   falsify it.** A log line, an API response, a status field, a report to a
   human — all the same shape. The failure is never that the number is wrong; it
   is that nothing downstream can tell.

**Three prescriptions in one day, each right in intent and wrong in mechanism.**

The first draft of this entry concluded that "the recurring error is prescribing
mechanism across contexts at all." **A worker corrected that, and the correction
is the more useful rule.** Its argument: all three instructions *did* carry the
intent, and that is exactly why the mechanism could be thrown away —

> *"방법이 틀린 처방은 버리면 그만이지만, 의도가 없는 지시는 버릴 것도 없습니다."*
> (A prescription with the wrong method can simply be discarded; an instruction
> with no intent leaves nothing to discard.)

Checking the actual message rather than arguing from memory confirmed it: it read
"confirm the running task definition's image tag SHA **corresponds to the promoted
staging commit**" — property *and* mechanism together. The property is what sent
the worker digging to the OCI label. A bare "match the image tag SHA" would have
dead-ended at the mutable tag with no way to tell the instruction was unanswerable.

**So the rule is narrower than the first draft claimed: always state the property;
a mechanism offered alongside it is a useful hint, not a hazard. The hazard is a
mechanism with no property attached** — because when it does not fit, there is
nothing left to fall back on.

Note where the over-generalization happened: **while writing up over-generalization.**
That is the fourth same-day instance of a pattern surviving the act of documenting
it (cf. [[butler-asserting-comments-stop-verification]], instance 4).

Note this pairs with, rather than contradicts,
[[butler-name-the-command-a-check-that-resembles-the-gate-is-not-the-gate]]:
**name the exact command when *reporting* what you ran; specify the property when
*instructing* someone else.** Reporting needs precision about the past;
instructing needs room for a local mechanism you cannot see.

**How to apply:**

- **Split the sentence.** "X is verified. Y follows from X but I have not checked
  Y." Two sentences cost nothing and put the inference where it can be attacked.
- **Watch for the widening words**: *so*, *therefore*, *which means*, *always*,
  *only*, *entire*. They mark the seam where measurement stopped.
- **A fact about the past does not price the future.** State drifts between when
  you measured and when the decision lands — ask what has moved since.
- **One instance is not the category.** Scoped permissions, per-tenant config, and
  intermittent failures all look uniform from a single sample.
- **Before claiming a frequency, prove the samples are distinct events.** Pin each
  to an identifier that cannot collide — a run id, a scheduled-for timestamp, a
  request id — not to the measured value. Two matching numbers are as easily one
  event measured twice as two events agreeing, and the first is invisible from the
  numbers alone.
- **Be most suspicious of a trend that arrived without a new observation.** If you
  did not go and look again, you did not get a second data point; you re-read the
  first one.
- **Never write a count without writing its list.** "Four times, two of them
  mine" is unauditable; "four times, two of them mine — ①②③" audits itself the
  instant you read it back. The enumeration is not decoration, it is the check,
  and it costs one line.
- **A count you are relaying must carry its decomposition.** You can enumerate
  because the source is in your hands; the next hop cannot, and the hop after
  that is deciding on it. Send "89 rows (NICE 65 + KIS 24)", never "271" —
  otherwise the number arrives unfalsifiable and gets approved.
- **Design responses, logs, and reports to be self-auditing.** If a value implies
  an invariant, ship the other terms of that invariant alongside it. A response
  carrying `updated/unchanged/skipped` but not `received` cannot be checked by
  anyone who did not make the call — the same defect as a bare relayed count,
  frozen into an interface where it recurs on every invocation.
- **Ask what a number counts, not just whether it is right.** "271" was accurate
  about lookup *attempts* and wrong about writes. A count with the wrong referent
  survives every arithmetic check you can run on it.
- **Check counts that flatter you at least as hard as ones that don't** —
  especially a tally of your own errors handed to you by someone else. Agreeing
  with a number about yourself is still asserting it. See
  [[butler-verify-the-citations-you-hand-down]].
- **Watch yourself hardest when you are teaching.** Passing a lesson downward
  compresses a measured fact into a portable rule, and the edge conditions are
  what get dropped. Say where you measured it: *"this failed on jarvice because
  it squash-merges — check what your repo does"* survives the trip; *"verify by
  content, it's robust either way"* does not.
- **Send the property with the command, every time.** The command may not fit the
  local terrain; the property tells the recipient what to build instead. An
  instruction carrying only a command is unfalsifiable from the receiving end —
  they cannot tell "this does not apply here" from "I am doing it wrong."
- **When someone corrects your generalization, check what you actually sent** —
  not what you remember sending. Here the record showed the worker was right and
  the note was wrong, which is only discoverable by rereading the artifact.
- **Prefer a criterion that could be false.** "Diff is empty" is unfalsifiable
  praise when the repo always has a diff. Predicting *which* files will differ,
  in writing, before looking, is a check that can actually fail — and therefore
  one that means something when it passes.
- **When correcting outward, say the correction was late.** Hiding the delay
  protects your record at the decider's expense. See
  [[butler-verify-delivery-not-just-send]] and
  [[butler-an-unverified-constraint-spends-the-humans-hand]].
- **If the recommendation survives the correction, say that too** — otherwise the
  reader cannot tell whether the conclusion or only its framing changed.

**SPT:** the habit is *before a claim leaves your hands, underline the part you
actually measured — and mark the rest as inference, out loud.*
