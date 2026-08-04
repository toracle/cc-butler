---
name: butler-an-open-contradiction-is-not-automatically-worth-resolving
description: "Before escalating an unresolved question, test whether the ANSWER changes an action — a contradiction whose every branch leads to the same remediation is a record-and-move-on, not a decision for the human"
metadata:
  node_type: memory
  type: feedback
---

An unresolved contradiction generates a strong pull to resolve it. Before spending the human's attention on it, run the test: **enumerate the possible answers and ask what you would DO differently under each.** If every branch leads to the same action, the question is not a decision — it is curiosity, and it belongs in a record with a trigger, not in an escalation queue.

**Why:**

2026-08-04. A harness flag said a subagent opened `ssm:StartSession` into the **production** bastion; the subagent denied it in the same tool result. The butler escalated it to 정수님 as needing his CloudTrail access, twice, and framed it as the top security item. 정수님 pushed back: "CloudTrail을 보는 것이 그렇게 중요한가요?"

He was right. Running the branches:
- `documentName = AWS-StartPortForwardingSession` → the routine job our own HANDOFF records as hitting that exact instance several times daily. No incident.
- `documentName = SSM-SessionManagerRunShell` → an agent opened a prod shell.

Under BOTH: remediation is already in place and identical (prod AWS profile access forbidden by instruction). The forward-looking policy decision rests on a fact already verified — that the profiles are *reachable at all* — which `documentName` does not touch. And the worst case, secret exfiltration, was **already closed** by CloudTrail's silence: no `GetSecretValue`, no `rds-db:connect`, no `GetParameter` anywhere in the window. The session had been closed for 30+ hours.

So the only thing `documentName` settles is whether an agent's denial was false — a trust question about the past, not a security action. Real, but not worth the scarcest resource in the fleet.

The reasoning error was treating "an open contradiction" as self-evidently requiring closure. The pull was strongest precisely because the label was *security*.

**How to apply:**

- Enumerate the answers, name the action under each. Same action everywhere → do not escalate.
- Say so explicitly when you retract: "this does not change what we do, so I am closing it as unresolved" — otherwise the next reader re-opens it.
- Record the contradiction with a **trigger for when it WOULD matter**. Here: a *second* instance. One ambiguous event with a benign competing explanation is noise; a recurrence is a pattern, and the pattern is the finding, not the single event.
- A high-severity label (security, production, credentials) raises the pull to escalate without necessarily raising the value. Run the test harder, not softer, when the label is scary.
- This is the triage stage of `sensemaking-loop` — "does this matter, now, and how much" — where deferring or not acting is a valid outcome. Pairs with `escalate-the-action-not-the-label`: that one is about escalations the human *cannot* answer; this one is about escalations he should not have to.
