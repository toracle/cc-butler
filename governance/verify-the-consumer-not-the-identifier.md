---
name: butler-verify-the-consumer-not-the-identifier
description: "A bare grep for a field name conflates distinct senses of the same identifier — check the code path that actually consumes the data before declaring a claim false"
metadata:
  node_type: memory
  type: feedback
---

When checking a claim of the form "nothing reads field X," do not stop at grepping the identifier. The same name usually denotes several unrelated things in one repo — a control-plane entity, a config key, a test fixture, and the runtime payload field you actually care about. Locate the code that **consumes the data in question** and check that, then report the distinction explicitly.

**Why:** 2026-08-05, verifying chat-proxy#350's claim that no stark code reads `provider_config` off usage events (load-bearing for promoting #272 alone). A plain grep returned **13 stark files** — which looks like a flat contradiction of the PR. Every one of them was the `ProviderConfiguration` control-plane entity: the Django model, the admin, the API view, the schema, their tests. The actual consumer — the usage-aggregation Lambda `infra/cdk/lambda/usage_aggregate.py` — has **zero** references. The PR's claim was true. I came close to reporting "13 consumers found, the PR lied," which would have injected a false alarm into 정수님's review and cost the author a defense of a correct statement.

**How to apply:**
- Ask "who consumes this at runtime?" and grep *that* file/path, not the whole repo.
- Treat a surprisingly high hit count as a signal of **sense collision**, not of a broken claim. The more central the name, the more senses it has.
- Carry the trap forward into the review notes, in the shape "a plain grep hits N files, all of them <other sense>, and zero in <real consumer>." The next person will run the same grep and reach the same wrong conclusion; pre-empting that costs one sentence now.
- The inverse also holds: zero grep hits does not prove no consumer, if the field is read dynamically (`.get(name)`, a dict copied wholesale, a serializer). Note that a wholesale `metadata.copy()` that only *adds* keys is immune to a field disappearing — that is a structural argument, stronger than a grep. See [[structurally-impossible-beats-checked-and-absent]].
