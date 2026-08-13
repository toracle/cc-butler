---
name: butler-time-words-ship-unverified
description: "날짜·시각·시제 표현은 문장에서 가장 검증을 안 받는 자리다 — 정수님께 나가는 문장에 시간 표현이 들어가면 보내기 전에 실물(로그 타임스탬프, scheduled_for, 세션 상태)에 한 번 대볼 것"
metadata:
  node_type: memory
  type: feedback
---

Date, clock-time, and tense words are the least-verified part of any sentence.
When everything else in a claim is right, neither writer nor reader stops at the
time expression — it has no visible referent, so nothing invites checking. Same
structure as a bare count shipping without its list
([[butler-the-verified-half-licenses-the-unverified-half]]).

**Why:** Three misfires in one day (2026-08-09), all with correct content and a
wrong time axis:
1. "어제의 침묵-504" — it was **today's** run, the very schedule the principal
   had created hours earlier; "yesterday" severed his connection to his own
   action, right where the message's purpose was re-run motivation.
2. "압축까지 마친 채" — compaction was queued, not finished (tense; see
   [[butler-approval-is-not-completion]]).
3. In a **correction message whose purpose was disambiguating which run was
   which**: "어제 오후 16:40" (it was today, same day as the 21:35 run, 4h55m
   apart) and "새벽 11시대" (11:35 KST is late morning; a UTC window 02:00–03:10Z
   flipped sign while being converted by feel). The correction re-created the
   confusion it was correcting — and corrections arrive with extra authority.

**How to apply:**
- Before sending any sentence to 정수님 containing a date, a clock time, or a
  completion tense, **check that value against an artifact once**: the log
  timestamp, `scheduled_for` epoch, the session's actual state. Same motion as
  writing the list next to the number.
- Convert UTC↔KST on paper (±9h arithmetic written out), never by feel —
  sign-flips survive proofreading because both readings sound plausible.
- Be strictest in messages whose *purpose* is time/identity disambiguation —
  an error there is not a typo, it defeats the message.
