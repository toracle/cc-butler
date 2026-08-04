# Proposal: make AWS profiles unreachable from worker sessions, enforced at launch

Status: **PROPOSAL ONLY — nothing in this document has been implemented.** No code
changed, no reload performed, no session restarted. Written 2026-08-04 in response
to a butler dispatch, following 정수님's ruling: *"wokrer는 가급적 AWS profile을 읽거나
사용할 수 없게 합시다"* ("Let's make it so workers cannot, as far as possible, read
or use AWS profiles.")

## Why this exists

A governance note asserted worker sandboxes "structurally have NO AWS credentials."
That was false: `~/.aws/config` defines production profiles (`monocle-jarvice`,
`monocle-stark`, `warmblood-cross-account-admin`) alongside staging ones, and the
`aws` CLI is on `PATH`. Workers run as the same OS user, in the same home — what
was called structural was pure convention. See
`governance/live-aws-verification-uncloseable-in-worker-sandbox.md` (as revised
2026-08-04) and `governance/workers-must-not-reach-aws-profiles.md`.

The fix must live at the point sessions are **launched**, not in worker
instructions — a prompt is not a sandbox
(`governance/subagent-scope-is-not-self-enforcing.md`), and an instruction every
worker must remember to abstain from is the read-guard anti-pattern
(`governance/fix-at-the-write-site-not-the-read-guard.md`).

## 1. Where sessions launch, and what they inherit (CONFIRMED — read directly)

`cc-butler--launch-session` (`cc-butler-session.el:1365-1386`) and
`cc-butler--resume-in` (`cc-butler-persist.el:145-162`) are not two independent
sites — they share **one** underlying chokepoint. Both do nothing but bind
`default-directory` (and, for resume, `claude-code-ide-cli-extra-flags`) and call
`(cc-butler--with-channel (claude-code-ide))`. `cc-butler--with-channel`
(`cc-butler-session.el:38-44`) is that single macro.

Butler, steward, and every ordinary worker all go through this *exact same* call.
`cc-butler-start-butler` / `cc-butler-start-steward`
(`cc-butler-orchestrator.el:820-832`, `907-924`) both call the identical
`cc-butler--launch-session`, differing only in which directory is passed. Role
(`cc-butler-set-butler`, `cc-butler-orchestrator.el:277-287`) is a **post-hoc UI
label** applied after launch — it is never a launch-time parameter. There is no
existing role branching in the launch path at all, today.

One layer down, in the `claude-code-ide` dependency
(`claude-code-ide.el:908-1023`, read for tracing only — not part of cc-butler and
not to be modified), `claude-code-ide--create-terminal-session` does, around line
1006:

```elisp
(let* ((process-environment (append env-vars process-environment))
       (process (ghostel-exec buffer program args)))
  ...)
```

This **appends** onto the current dynamic value of `process-environment` rather
than resetting it — so an outer `let`-bound override, placed by cc-butler around
its `(claude-code-ide)` call, flows straight through into what `ghostel-exec`
receives. There is already an idiomatic precedent for exactly this shape:
`cc-butler--resume-in` already dynamically `let`-binds
`claude-code-ide-cli-extra-flags` around the identical call. The same shape,
extended to `process-environment`, is the natural fix — one edit to
`cc-butler--with-channel` (or a sibling `let` around it) would cover both the
launch and resume paths at once, since they share the macro.

**Nothing internal depends on these vars (CONFIRMED via full-repo + full-dependency
grep):** `AWS` appears zero times in any `.el` file in cc-butler, and zero times
in the installed `claude-code-ide` package. Neither shells out to `aws` or reads
AWS env vars for anything of their own. Redirecting
`AWS_CONFIG_FILE`/`AWS_SHARED_CREDENTIALS_FILE` breaks nothing internal to this
tooling.

### The one unverified link

`ghostel-exec`'s own internals were **not read** (a further dependency, out of
scope of this pass). Whether it preserves `process-environment` all the way to
the OS-level process spawn, or resets/filters it internally before that, is
**not confirmed** — only inferred from the fact that the surrounding Lisp does an
append rather than a reset. This is the first thing to check before
implementing, not something to assume.

## 2. Redirecting AWS_CONFIG_FILE / AWS_SHARED_CREDENTIALS_FILE

Mechanically achievable via the append-through path above. Redirecting these to
an empty/nonexistent path means the `aws` CLI *and* any AWS SDK a subprocess
might invoke (boto3, the JS/Go/Python SDKs — they all honor the same two env
vars) find no profiles at all. This is a real plus over an `aws`-CLI-only
mitigation: it also covers SDK-based access, not just the command-line tool.

## 3. A settings.json deny-rule, scoped to workers only (RESEARCHED)

Claude Code exposes an env var, `CLAUDE_CONFIG_DIR`, that repoints its *entire*
settings/config resolution (settings.json, settings.local.json, hooks, MCP
config — everything) at an alternate directory instead of `~/.claude/`. This can
be set through the exact same `process-environment` append mechanism as §2 — no
new plumbing, the same single edit.

Plan: a dedicated directory, e.g. `~/.claude-fleet/.claude/settings.json`:

```json
{"permissions": {"deny": ["Bash(aws *)"]}}
```

Set `CLAUDE_CONFIG_DIR` to it *only* inside the launch/resume env override.
정수님's own interactive `claude` sessions never call `cc-butler--with-channel` at
all — they are structurally outside this change regardless of the rule's
content, and never get `CLAUDE_CONFIG_DIR` set, so they keep reading
`~/.claude/settings.json` untouched.

Deny rules are confirmed (Claude Code's own documentation,
`code.claude.com/docs/en/permissions.md`) to be **harness-enforced hard blocks**:
evaluated before any prompt, always winning over an allow at any scope, and
failing closed in headless/non-interactive mode — no fallback to allow, the
model cannot talk past it. This is a genuinely different, *stronger* enforcement
than §2, because it does not depend on the spawned process's environment being
correctly scoped at all — it blocks the tool call itself, at the harness layer.

**Cost of this layer, stated plainly:** it is a Bash-tool pattern match on the
literal `aws` binary. It does **not**, by itself, stop a script invoking `boto3`
directly (§2 covers that), another AWS-aware CLI (`terraform`, `aws-vault`,
`cdk` assuming a role), or a `Read` tool call viewing `~/.aws/credentials`'
cleartext static keys directly. A companion `Read` deny rule on the AWS
config/credential paths would close that last gap — the exact path-deny syntax
for `Read` was not confirmed and should be checked before implementation, not
assumed to work as written above.

## 4. Should butler/steward be treated the same as workers?

**Yes — and it is also the cheaper build.** Because there is no existing
role parameter at launch (§1), giving butler/steward an *exception* would
require **new** plumbing: threading a role value into
`cc-butler--launch-session`/`--with-channel` that does not exist today. Uniform
denial needs none of that — it is one override at the one existing chokepoint,
applied unconditionally.

No legitimate AWS need specific to butler/steward's own role (orchestration,
dispatch, reporting) was found in the code. The two tracks that do genuinely need
live AWS (below) are already, in butler's own framing, routed away from butler
and steward — not to them.

### The one design gap

Today's launch path draws **no distinction whatsoever** between butler, steward,
and worker — they are the same function call with a different directory
argument. This proposal's "treat them all the same" recommendation is easy
precisely *because* of that gap: it needs zero new code to apply uniformly. But
the flip side is that if 정수님 or the butler ever *does* want an exception for
butler/steward specifically in the future, that is not a flag to flip — it is new
design and new code (a role parameter that does not exist today). This does not
make the current proposal unsafe or even incomplete for what was asked (uniform
denial); it is a **fine-with-a-caveat** situation: the simplicity of "deny
everyone" is bought by the absence of any mechanism to later carve out an
exception cheaply, should one ever turn out to be needed.

## Honesty on strength (do not oversell)

- **Layer 1 (env redirect):** a same-UID speed bump. A determined agent can
  `unsetenv`/override it. Covers CLI + SDK access.
- **Layer 2 (settings deny-rule):** a real harness-level hard block on the `aws`
  binary specifically. Stronger, not env-dependent — but pattern-scoped: doesn't
  stop `boto3` alone, doesn't stop reading the raw credential file via `Read`.
- **Together: meaningfully enforced, not structural isolation.** A sufficiently
  determined agent with Bash access and some other path to the raw credential
  file could still hand-craft signed requests without going through either
  guarded surface. State this plainly wherever this lands — do not describe it
  as a sandbox. That overstatement is the exact mistake this whole effort exists
  to correct.

## Not stranding legitimate AWS work

Neither layer touches 정수님's own interactive shell — his sessions never call
`cc-butler--with-channel`, so they sit structurally outside this change
regardless of directory or timing. Two tracks genuinely need live AWS and must
not be solved by reopening worker access:

- **prd-bastion policy confirmation** (`monocle-stark` admin,
  `iam:SimulatePrincipalPolicy` against the live instance role)
- **16-scheduler CDK deploy** (`monocle-jarvice-stg`, hand-run because no
  workflow runs `cdk`)

Both should go to a dedicated cred-host, to CI, or to 정수님 directly — never
through a hole reopened in the launcher for a worker.

## Cutover (infrastructure running while it is edited)

This lives at the launch/resume chokepoint, so it only affects sessions
**started after** the code is loaded. A code change plus `reload_butler_code`
does **not** retroactively change the environment of any already-live worker
process — env is fixed at that process's own spawn time, and a reload cannot
reach into an already-running OS process to change it.

Full fleet coverage therefore requires the currently-live workers to eventually
be relaunched/resumed under the new code. That can happen gradually (the next
natural restart, or the next crash-recovery) rather than as a forced blanket
restart the moment this lands. Whether to force an immediate restart of all
twelve to close the gap sooner is a separate, larger decision from "land this
fix" — it should be its own explicit choice, not something bundled silently into
implementation.

## Summary of what would actually change (not yet done)

1. Extend `cc-butler--with-channel` (or add a sibling `let` around both of its
   two call sites) to dynamically bind `process-environment`, appending:
   `AWS_CONFIG_FILE` → an empty/nonexistent path, `AWS_SHARED_CREDENTIALS_FILE`
   → same, `CLAUDE_CONFIG_DIR` → a dedicated fleet-config directory.
2. Create that fleet-config directory's `settings.json` with
   `{"permissions": {"deny": ["Bash(aws *)"]}}`, and evaluate whether a `Read`
   deny on the AWS config/credential file paths can be added the same way.
3. Verify `ghostel-exec` actually preserves `process-environment` through to the
   OS-level spawn (the one unverified link, §1) before relying on any of this.
4. Apply uniformly to butler, steward, and worker — no new role parameter.
5. Treat fleet-wide enforcement as gradual (natural relaunches) unless 정수님
   separately decides an immediate restart of all twelve is worth the
   disruption.
