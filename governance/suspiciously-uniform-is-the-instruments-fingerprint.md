---
name: suspiciously-uniform-is-the-instruments-fingerprint
description: "Before reading a measurement as a property of the system, check whether it is a property of the measurement. A value that repeats too cleanly — seven failures at exactly 8.002s — is usually the instrument's own limit (a `timeout 8` wrapper, a retry cap, a page size), not the system's configuration. Real systems jitter. Uniformity is the tell, and it is easy to mistake for strong evidence."
metadata:
  node_type: memory
  type: feedback
---

**The incident (steward, 2026-08-03).** Analyzing a standing DNS probe, the steward found seven failures whose
host-side elapsed time was `8.002s` every single time, and reported this as *"a configured timeout's
fingerprint, not drift"* — using the uniformity as the strength of the inference, and directing the worker to
go find the 8-second setting.

There was no 8-second setting. The probe script wrapped the host lookup in `timeout 8`. **The number measured
the instrument, not the resolver.** With no explicit `options timeout:`/`attempts:` in `resolv.conf`, glibc
defaults apply (5s × 2 attempts × 3 nameservers ≈ 30s worst case), so the true stall could have been far longer
and was simply cut off. The worker found this on its own, in analysis the steward had not asked for, and
reported it as a correction.

**The tell was in the evidence and was read backwards.** Genuine system timeouts jitter — scheduling, network,
load. A value repeating to the millisecond across seven independent samples is *too clean to be organic*. The
steward treated that cleanliness as the reason to believe it. **Suspicious uniformity is evidence about the
measuring apparatus, and it feels like the strongest evidence you have.**

**Separate what the correction kills from what it leaves standing.** This matters more than the apology, because
it determines the next action. Here, three conclusions rested on paired outcomes and timestamps and survived
untouched (failures are a time burst not domain skew; failures occur upstream of Docker since `host=ok` +
`container=fail` never happened; Docker adds ~511 ms on successes). Exactly one inference died: "look for an
8-second setting." A retraction that vaguely taints the whole analysis is as unhelpful as no retraction — say
which claims lived, which died, and what each rested on.

And note the correction had **practical** weight, not merely epistemic: if the real stall is ~30s rather than 8s,
it blows through most CI timeouts, so the size of the problem being fixed changed with it.

**How to apply.**
1. **Before attributing a measurement to the system, list what in your apparatus could produce that exact
   number** — `timeout`/`ulimit` wrappers, retry caps, client-side deadlines, buffer or page sizes, sampling
   interval. Round or repeating values are suspects until cleared.
2. **Treat uniformity as a question, not a confirmation.** Ask "what would make this vary, and why didn't it?"
   before asking "what setting produces 8 seconds?"
3. **A ceiling you imposed cannot measure a value above it.** If failures pile up at your limit, you have
   learned the limit was too low — nothing about the true distribution. Raise it and re-measure.
4. **This is the same error class as a missing binary reporting as a failure.** Earlier the same night the
   steward's own host-latency measurement used a `/usr/bin/time` that did not exist, producing eight spurious
   FAILs that were not DNS failures at all. Both times the instrument spoke and was recorded as the system.
   **When a measurement surprises you, re-read the measuring code before theorising about the world.**
5. **When a worker corrects you on analysis you performed, take it plainly and say what it kills.** This one
   arrived unprompted, from work not asked for. That behaviour is expensive to acquire and cheap to suppress.

Related: [[a-test-that-cannot-fail-is-not-evidence]] (the same shape in testing — an observation that could not
have come out differently), [[environment-broken-cross-check-same-resource]] (cross-check the same resource from
a second vantage point), [[merging-agent-results-must-keep-per-claim-provenance]] (apply provenance to your own
sentences — *observed* vs *inferred*; this was inferred and reported as found).

**SPT:** the habit is *when a number repeats too cleanly, suspect your own instrument before the system's config.*
