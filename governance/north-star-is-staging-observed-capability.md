---
name: butler-north-star-is-staging-observed-capability
description: "The three active tracks' DoD is 정수님's user-capability question answered YES on the STAGING monocle env — re-ask every ~2h; merged/green is not yes"
metadata:
  node_type: memory
  type: feedback
---

정수님's standing reframe (2026-08-13, verbatim): "does our DB mcp support oracle engine now? … can a scheduled task execute an MCP? regardless of built-in or monocle-provided or custom? … can an user now generated an image based on existing image (edit)? … they are DoD of each task. ask these question yourself time to time (eg., every 2 hrs) and regard them as north star. in this sentences, 'can user do …' means, on staging monocle env."

The DoD of a feature track is the USER-CAPABILITY QUESTION answered YES on the staging monocle environment — not "PR merged", not "CI green", not "review passed". Those are gates on the way, and a track whose PRs are all merged can still be a NO.

**Why:** On 2026-08-13 all three active tracks (DB-MCP Oracle, scheduler-MCP-enable, image edit) had substantial merged/reviewed work, yet all three north-star answers were NO — the remaining distance (deploys, cross-PR merges, pending decisions) was invisible in per-PR status. 정수님 set the question form itself as the tracker. The phrasing also RULED a pending fork: "regardless of built-in or monocle-provided or custom" answered #1754's F1 as widen-to-all-types, because a DoD stated over all server types cannot be met by a subset.

**How to apply:** (1) Butler re-asks the three questions on a ~2h pulse (cron is session-only — re-arm it after any butler restart; this note is the durable record). (2) Answer each from CURRENT state, never from the previous check. (3) For each NO, name the single next gate and its owner; surface 정수님-owned gates to him, drive fleet-owned gates via steward. (4) When scoping any of these tracks, distance-to-staging is the plan's spine, and merged-but-not-deployed work counts as not done. Related: [[butler-dod-vs-ultimate-goal]], [[butler-ci-deploy-is-not-cdk-deploy]].
