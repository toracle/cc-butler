---
name: butler-a-decision-you-cite-may-have-been-narrowed-later
description: "'The governance store is a timeline, not a set of independent facts — quoting a standing decision without checking what later narrowed it produces a constraint that is accurately sourced, verbatim-faithful, and wrong; the more exactly you quote, the more persuasively you mislead, and citing the human's own words back at him is the hardest error for him to push back on'"
metadata:
  node_type: memory
  type: feedback
---

A principle in the store is a **dated position, not a permanent fact**. Later
decisions narrow, widen, or revoke earlier ones, and the earlier note does not
rewrite itself. So citing one entry faithfully — right file, right date, verbatim
quote — can still yield a constraint that does not exist.

This failure is worse than a sloppy citation, because everything checkable about
it checks out. **The more exactly you quote, the more persuasively you are wrong.**

**Why:** 2026-08-08, ~04:00. The steward was about to reframe the scheduler census
options for 정수님. It read `workers-must-not-reach-aws-profiles` and found his
ruling, quoted correctly:

> "wokrer는 가급적 AWS profile을 읽거나 사용할 수 없게 합시다." (2026-08-04)

and the note's own line that *"read-only is not a justification."* On that basis it
told butler that **RDS-1 — letting a worker run the census — collided with 정수님's
own standing ruling**, and should be re-presented not as a peer option but as a
request to suspend his own decision.

Butler read the source instead of relaying it, and refused. **The very next day
정수님 narrowed the scope**, in `staging-is-agent-accessible-by-design`:

> "스테이징은 저는 에이전트가 액세스 가능하면 좋을 것 같습니다. 어차피 AWS 프로파일
> 퍼미션이 없으면 패스워드를 안다고 해도 이게 프라이빗 VPC에 있기 때문에 접근을 할
> 수가 없어요." (2026-08-05)

That note says outright: *"Keep the production boundary exactly as strict as it is
— for non-`-stg` profiles. This note narrows to staging and nothing else,"* and
*"Agents reaching staging is desired, not tolerated."* The census script is
`PROFILE=<AWS_PROFILE>-stg` — staging. RDS-1 was never a violation; it is the
direction 정수님 said he **wanted**.

**Note the shape of the harm.** Had this reached him, he would have been pushed off
his own preferred option *by a quotation of his own words*. That is the hardest
error for a human to resist: arguing back means contradicting himself, and the
citation is real. Manufacturing a constraint out of the principal's own voice
outranks ordinary misinformation, and it is invisible unless someone opens the
neighbouring note.

**The symmetry matters too.** Ignoring 08-04 and citing only 08-05 would have
licensed access the pair does not license. Neither note alone is safe; the
boundary lives in the pair.

> **Correction, same day, from 정수님 directly.** This paragraph originally said
> the discriminator "was a five-character suffix — `<AWS_PROFILE>` versus
> `<AWS_PROFILE>-stg`," and called a worker's `AWS_PROFILE=<AWS_PROFILE>`
> CloudWatch read "production." **Both claims are false.** The two profiles are
> the *same account* (`<AWS_ACCOUNT_ID>`); the suffix marks a **permission tier**, not
> an environment — `<AWS_PROFILE>` is the account **administrator** role. Jarvice
> prod and staging share one account, separated by role scope and SSM path prefix.
> See [[butler-a-profile-name-is-a-permission-tier-not-an-environment]].
>
> The error is left visible rather than silently rewritten, because it is this
> note's own thesis turned on its author: I wrote a durable rule whose
> discriminator I had inferred from a *name* and never verified, and it then sat
> in the store being recalled as fact. **A note written to warn against citing an
> unverified claim was itself an unverified claim.** The lesson generalizes past
> supersession: a citation can be stale *or* it can have been wrong on the day it
> was written, and re-reading the source catches both.

A second correction rode along. The steward had also declined to pre-verify the
census's SSM parameters, citing the same rule — wrong rule, right conclusion. The
actual reason is mechanism, not permission: per 08-05's own third bullet, **the
local sandbox classifier blocks credential-adjacent reads regardless of what IAM
allows**, so `ssm get-parameter --with-decryption` would likely be blocked anyway,
and it fails non-destructively at the query stage. *"Forbidden"* and *"blocked by a
different layer"* license different next moves; see
[[a-tools-success-check-covers-only-its-own-layer]].

**How to apply:**

1. **Before citing a standing decision as a constraint, search the store by
   *topic*, not by note name.** You are looking for what came *after*. One `grep`
   across the store for the subject (`aws`, `profile`, `staging`) surfaces the
   neighbours; opening only the note you already remembered guarantees you see the
   timeline's first entry and none of its amendments.
2. **Read a rule's scope qualifiers as load-bearing, then check which side your
   case is on.** "For non-`-stg` profiles", "this narrows to staging and nothing
   else", "as far as achievable" — these clauses are the whole content. Then open
   the actual artifact and read the actual value (`PROFILE=` line), because the
   rule turns on a string, not on the noun "AWS profile".
3. **Follow the store's own cross-links before concluding.** These notes link to
   the ones that bound them; the narrowing note named the broad one explicitly.
   The links exist precisely so that reading one is enough to find the other —
   they only work if followed.
4. **Treat "this contradicts the human's own ruling" as a high-bar claim.** It
   ends discussion by construction, since disagreeing means contradicting himself.
   Before writing it, verify the ruling is current *and* that his case falls inside
   it — the same bar as "the control is unreliable" in
   [[a-true-observation-licenses-only-its-own-scope]].
5. **Relay receivers: open the cited source before acting on the citation.** Butler
   caught this by reading the note rather than trusting a correctly-formatted quote
   from a peer role. A citation's formatting quality says nothing about its
   currency. See
   [[a-channel-that-carries-authority-must-be-verifiable-by-the-receiver]].
6. **When you retract, keep the parts that survive and say why they survive.**
   Butler kept the production finding and the "absence of a block is not
   authorization" point while killing the staging claim, and separately kept the
   steward's *conclusion* on SSM pre-verification while replacing its *reason*. A
   retraction that discards the whole message loses true findings along with the
   false one.
