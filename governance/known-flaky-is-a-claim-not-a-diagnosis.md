---
name: known-flaky-is-a-claim-not-a-diagnosis
description: "'Known flaky' is a label that stops investigation, and it is frequently wrong. Flaky means RANDOM — it eventually passes. N consecutive failures of the SAME tests in the SAME way is a persistent condition, and the N+1th retry will fail too. Test the label: count consecutive identical failures, and if the failure is a real external dependency (DNS, third-party API), the defect is usually that a unit test reaches the outside world at all. Retrying is not a strategy; mock the dependency."
metadata:
  node_type: memory
  type: feedback
---

**The incident (dealmatch #1109, 2026-08-03).** A worker's CI kept failing on two tests. It classified them
as "the known flaky tests we've been seeing all session" and was on its **sixth rerun**, waiting for a green.
The failure was identical every time: DNS resolution of `sens.apigw.ntruss.com` (Naver's SMS gateway) failing
inside the test job.

**Why the label is dangerous.** "Known flaky" is an *explanation-shaped* phrase that ends inquiry. Once
attached, the failure stops being evidence and becomes noise to be retried past. But it carries a falsifiable
claim — *flaky means random* — and randomness has a signature: some attempts pass. Six identical failures in
a row has the opposite signature. That is a **persistent condition wearing a flaky label**, and no number of
retries will clear it.

**The cheap test.** Count consecutive failures and check whether they are the *same* tests failing the *same*
way. Genuinely flaky tests scatter — different tests, different runs, intermittent passes. A stable
signature means: stop retrying, start diagnosing. Retry budget is not a debugging strategy; it just converts
a diagnosable failure into a slow one.

**The usual underlying defect: the test reaches the outside world.** Here two *unit* tests dialed a live
third-party SMS gateway. That is the bug, independent of whether DNS happens to work today — it makes CI
nondeterministic and hands a vendor's outage the power to block your pipeline. The durable fix is to mock the
external call, not to stabilize the network. Authorize that fix directly; it is small, test-only, and
reversible.

**Localize before blaming the environment.** When the failure IS network/DNS, resolve the hostname yourself
from the relevant host before theorizing. In this incident the steward suspected office-wide DNS instability
(having just hit `github.com` DNS failures on the same network) — then resolved the SMS gateway directly,
got 3/3 success, and **discarded the hypothesis instead of shipping it**. The better remaining hypothesis was
narrower: the job ran in a `container:` on the runner, and **a container's resolv.conf can differ from its
host's** — host-resolves-but-container-doesn't reproduces exactly this symptom. Related:
[[environment-broken-cross-check-same-resource]].

**✅ RESOLVED (same night, first-hand on the runner box).** The narrower hypothesis was right in shape and
still not the bottom. dealmatch's own host turned out to BE the runner (`/home/github-action-runner-*/.runner`),
so it could look directly: host resolves 10/10; resolv.conf was ALREADY public (1.1.1.1/1.0.0.1/8.8.8.8), and
dhclient.conf showed *someone had already switched to public DNS 3 weeks earlier* — i.e. the popular fix ("use a
different DNS provider") was already applied and had NOT worked. The real layer was **Docker's embedded DNS
proxy (127.0.0.11) on a ROOTLESS docker running the gVisor/rootlesskit userspace network stack
(`--net=gvisor-tap-vsock`)**: journalctl showed 254 "failed to query external DNS server i/o timeout" in one day,
against all three upstreams failing *together* in bursts (simultaneous ⇒ not a bad resolver — the rootless net
stack's UDP forwarding itself is unreliable), burst-intermittent (~97.5%/query, hundreds/day). **Three lessons
that generalize:** (1) **localize to the exact resolution layer** — host resolver vs the container's embedded
proxy vs the upstream — because a fix aimed at the wrong layer (swap resolver) is a no-op; (2) **check whether
the fix was already applied** before proposing it (dated config + a comment told the whole story in seconds);
(3) **simultaneous failure of independent upstreams exonerates the upstreams** and points one layer down. The
concrete fix menu here was retry-tuning the embedded resolver (`dns-opts timeout/attempts` in rootless
`daemon.json`) or moving off the gvisor rootless backend — neither is "DNS provider."

**How to apply.**
1. Treat "known flaky" as a **hypothesis to test**, never as a reason to rerun. Ask: how many consecutive
   failures, and are they identical? Identical + consecutive ⇒ not flaky.
2. Never let a worker rerun indefinitely. Two identical failures is the point to stop and diagnose.
3. If the failure traces to an external dependency, the fix is to remove the dependency from the test, not to
   wait for the dependency to recover.
4. Don't merge on red because "the failures look unrelated" — that is a human decision to route upward, not
   one a worker (or a steward) settles alone. See [[prod-data-access-requires-explicit-approval]].
5. A config-level workaround (switch runners, bump a timeout) may be a legitimate **fallback**, but name it
   as a workaround so it doesn't get mistaken for the fix and close the ticket.

**SPT:** the habit is *when someone says "that test is just flaky," count the consecutive identical failures —
if they don't scatter, it isn't flaky and no retry will save you.*
