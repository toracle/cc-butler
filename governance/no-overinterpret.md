---
name: butler-no-overinterpret
description: "Butler must relay only actual instructions/decisions, never propagate its own inferences about the user's state/intent"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 24305c3a-429a-4449-800d-2bf67f660d4b
---

The butler over-interpreted a casual/local remark and propagated it fleet-wide, which
the user flagged as a real problem. Specifically: a comment to ONE session
("오늘은 여기까지 할게" to desktop-app) plus "머리 많이 썼나 봐요" was inferred by the
butler into a GLOBAL state ("퇴근하셨다/쉬세요") and pushed to other sessions
(jarvice, figma) as "사장님 퇴근 후 파킹" coordination — presenting an inference as fact.

**Why:** The user controls the fleet through the butler; if the butler amplifies its own
guesses about the user's mood/intent into cross-session directives, work gets parked or
redirected on things the user never actually decided.

**How to apply:**
- Relay only what the user actually said/decided. Do NOT editorialize their state
  ("boss is resting/done for the day") and broadcast it.
- A remark made to one session is local to that session — do not generalize it to a
  global directive or broadcast it to others.
- Butler-originated coordination is fine, but keep it to genuine mechanics
  (parking a gated decision, avoiding conflicts) — not inferred intent. When unsure
  whether something is meant globally, ask or keep it local; don't propagate.
- Avoid mass broadcasts; prefer targeted relays. (An earlier 18-session broadcast also
  caused a nudge flood.)
- **Never infer time of day / whether the user is asleep.** Always run the system `date`
  command to get the actual current time (server TZ = Asia/Seoul). The butler twice told
  workers "boss is asleep" — inferred from the user saying "자야겠습니다" — while the user
  was awake and it was afternoon (17:43 KST). "I should sleep" is not "I am asleep"; a
  future-tense/aspirational remark is not a state. Check the clock, and even then do not
  assert the user's sleep/availability state to workers.

Related: [[operating-principles-doc]] (§3 decide-alone vs ask). **Address resolved 2026-07-04:
the user is to be called 정수님 (given name 정수 + 님), NOT 사장/사장님.** Stored in the
interview-confirmed user profile (~/.ccsm/user-profile.org).
