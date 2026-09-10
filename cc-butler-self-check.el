;;; cc-butler-self-check.el --- periodic elisp self-check (existence -> consistency)  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Four defects on 2026-08-14 shared one shape: a value computed once, never
;; re-checked, found by accident, reporting success the whole time it was
;; wrong -- the MCP server port a session's argv baked in, the North Star
;; pulse file pointed at a directory that no longer existed, the governance
;; memory dir written to one place while the running code read from another
;; (see `cc-butler-governance.el''s own 2026-07-23 commentary), and the
;; `cc-butler' module load path itself being whatever the mutable dev
;; checkout happened to hold at restart time.  All four would pass an
;; EXISTENCE check ("is the variable set", "does the directory exist").
;; None would pass a CONSISTENCY check ("does the thing this points at match
;; the thing it is supposed to match, RIGHT NOW").  A fifth, the vault path
;; (`WARMBLE_JUMBLE_PATH' vs. `cc-butler-governance-store'), was found the
;; same night by another worker and is the cleanest illustration of the
;; thesis: both paths exist, both are genuine vault clones of the same
;; origin, so only asking "do they agree" catches it.
;;
;; This module is the periodic mechanical check for that whole class: a
;; registry of named checks, each returning (:ok BOOL :detail STRING), run
;; on a timer and reported two ways -- a quiet per-tick log no matter the
;; result, and a push notification ONLY on a check's ok<->fail transition
;; (both directions, so a fix is announced as loudly as a break).
;;
;; Modeled on two patterns already proven in this codebase rather than
;; inventing new ones: the timer + idle-safe-firing + interactive-command
;; shape of `cc-butler-north-star.el', and the "never read the variable
;; directly, ask the resolver function" discipline of
;; `cc-butler-governance-store' / `cc-butler-governance--load-dir' -- each
;; check below is a pair of small resolver functions (what does the config
;; say vs. what does reality say) so each half is independently stubbable
;; in tests.
;;
;; See ~/.emacs.d/cc-butler/butler/docs/design-periodic-self-check-2026-08-14.md
;; for the full design brief this module implements.

;;; Code:

(require 'cl-lib)
(require 'cus-edit)
(require 'seq)
(require 'subr-x)
(require 'cc-butler-session)
(require 'cc-butler-orchestrator)
(require 'cc-butler-governance)
(require 'cc-butler-docs)
(require 'cc-butler-north-star)
(require 'cc-butler-mail)
;; No cycle: `cc-butler-decision' requires only `cc-butler-mail' / `org' /
;; `subr-x', none of which requires this file back — safe to reuse its
;; `cc-butler--decision-format-age' below instead of writing a duplicate.
(require 'cc-butler-decision)
;; `matrix-bridge' is a standalone, co-located file (not one of
;; `cc-butler--modules') that already owns all Matrix connection config
;; (homeserver, token, self-identity) — check 9 below reuses that config and
;; its synchronous thread-fetch function rather than duplicating either.
(require 'matrix-bridge)

;; `cc-butler-source-dir' lives in cc-butler.el, which requires THIS file --
;; the reference is forward at compile time and resolved at run time, the
;; same pattern `cc-butler-session.el' already uses for
;; `cc-butler--source-diagnostics'.
(declare-function cc-butler-source-dir "cc-butler" ())
(declare-function cc-butler--defcustom-drift-all "cc-butler" (&optional dir))
(declare-function cc-butler--defcustom-symbols-all "cc-butler" (&optional dir))
(declare-function cc-butler--defcustom-file-for-symbol "cc-butler" (dir symbol))
(declare-function cc-butler--defcustom-drift-label "cc-butler" (file symbol live-value code-default))

;;;; ------------------------------------------------------------------
;;;; Check 1: MCP port -- bound port == every live session's actual port
;;;; ------------------------------------------------------------------

(defun cc-butler-self-check--mcp-bound-port ()
  "Reality: the port `claude-code-ide-mcp-server' is ACTUALLY bound to, or nil.
Deliberately reads `claude-code-ide-mcp-server--port' (set at `ws-start'
success), never `claude-code-ide-mcp-server-port' (only the configured
*desired* port, which can be nil for auto-select) -- confusing those two
is the existence-only mistake that let a rebind go unnoticed on 2026-08-14."
  (and (boundp 'claude-code-ide-mcp-server--port)
       claude-code-ide-mcp-server--port))

(defun cc-butler-self-check--proc-env-port (pid)
  "Return the CLAUDE_CODE_SSE_PORT baked into PID's environment, or nil.
Read from /proc/PID/environ (Linux) -- the port a session's `claude' CLI
process was actually launched with, which a later server rebind does not
retroactively update."
  (let ((file (format "/proc/%d/environ" pid)))
    (and (file-readable-p file)
         (ignore-errors
           (with-temp-buffer
             (insert-file-contents-literally file)
             (let ((entry (seq-find
                           (lambda (v) (string-prefix-p "CLAUDE_CODE_SSE_PORT=" v))
                           (split-string (buffer-string) "\0" t))))
               (and entry
                    (string-to-number
                     (substring entry (length "CLAUDE_CODE_SSE_PORT="))))))))))

(defun cc-butler-self-check--session-ports ()
  "Return an alist of (DIR . PORT), PORT being the connection port each live
fleet session was actually launched with.  Sourced from `cc-butler--sessions'
-- the fleet's existing liveness roster -- and each session's real process,
not a new session-tracking mechanism.  A session whose port cannot be
determined (process gone, /proc unavailable) is simply omitted, never
reported as a mismatch."
  (delq nil
        (mapcar
         (lambda (s)
           (let* ((dir (plist-get s :dir))
                  (process (claude-code-ide--get-process dir))
                  (pid (and process (process-live-p process) (process-id process)))
                  (port (and pid (cc-butler-self-check--proc-env-port pid))))
             (and port (cons dir port))))
         (cc-butler--sessions))))

(defun cc-butler-self-check--mcp-port ()
  "Check 1: the bound MCP port matches every live session's actual port.
Fails on the exact 2026-08-14 failure mode: a session spawned before a
rebind, now silently pointed at a dead port."
  (let ((bound (cc-butler-self-check--mcp-bound-port))
        (sessions (cc-butler-self-check--session-ports)))
    (cond
     ((null bound)
      (list :ok nil
            :detail "MCP port: server not bound (claude-code-ide-mcp-server--port is nil) — no fleet session can be reaching it"))
     (t
      (let ((mismatched (seq-filter (lambda (sp) (/= (cdr sp) bound)) sessions)))
        (if mismatched
            (list :ok nil
                  :detail (format "MCP port: bound to %d, but %d live session(s) connected to a different port: %s"
                                  bound (length mismatched)
                                  (mapconcat (lambda (sp) (format "%s=%d" (car sp) (cdr sp)))
                                             mismatched ", ")))
          (list :ok t
                :detail (format "MCP port: bound to %d, matches all %d live session(s) with a known port"
                                bound (length sessions)))))))))

;;;; ------------------------------------------------------------------
;;;; Check 2: governance memory dir -- write path == read path
;;;; ------------------------------------------------------------------

(defun cc-butler-self-check--governance-write-dir ()
  "Reality A (write path): where `regenerate_governance' actually writes.

Goes through `cc-butler-governance-memory-store', not the raw
`cc-butler-governance-memory-dir' variable — that variable now defaults
to nil (2026-09-01 fix for the load-order race this check exists to
catch), so reading it directly would report every default-configured
fleet as a permanent mismatch against Reality B below."
  (cc-butler-governance-memory-store))

(defun cc-butler-self-check--governance-read-dir ()
  "Reality B (read path): where the running butler's own CLAUDE.md actually
points a session at for shared memory -- the same derivation
`cc-butler--shared-state-note' / `cc-butler--learning-duty' already use,
anchored to the currently designated butler home (falling back to
`cc-butler-home' before one is designated)."
  (cc-butler--claude-memory-dir (or cc-butler--butler cc-butler-home)))

(defun cc-butler-self-check--governance-memory-dir ()
  "Check 2: the governance memory write path and the butler's own read path
must resolve to the same directory.  A direct instance of the governance
principle `one-path-for-write-and-read' -- a write landing somewhere the
reader never looks reports success while landing nothing, exactly the
2026-07-23 incident recorded in `cc-butler-governance.el''s own commentary."
  (let* ((write (cc-butler-self-check--governance-write-dir))
         (read (cc-butler-self-check--governance-read-dir))
         (write-abs (and write (file-name-as-directory (expand-file-name write))))
         (read-abs (and read (file-name-as-directory (expand-file-name read)))))
    (if (and write-abs read-abs (equal write-abs read-abs))
        (list :ok t
              :detail (format "governance memory dir: write path and read path agree (%s)"
                              (abbreviate-file-name write-abs)))
      (list :ok nil
            :detail (format "governance memory dir: write path (%s) != read path (%s) — see governance one-path-for-write-and-read"
                            (and write-abs (abbreviate-file-name write-abs))
                            (and read-abs (abbreviate-file-name read-abs)))))))

;;;; ------------------------------------------------------------------
;;;; Check 3: North Star file -- exists, and inside the CURRENT store
;;;; ------------------------------------------------------------------

(defun cc-butler-self-check--north-star-file ()
  "Check 3: `cc-butler-north-star-file' exists on disk, lives inside the
CURRENTLY effective `cc-butler-governance-store', and (only once PR #73
lands) passes `cc-butler--north-star-file-namespaced-p'.  PR #73's check
is a load/fire-time gate; this adds the periodic half -- catching a file
that was correct at configuration time but has since been orphaned by a
governance-dir move (exactly the 2026-08-14 root cause) even if its
basename still looks fine."
  (let* ((file cc-butler-north-star-file)
         (exists (and file (file-exists-p file)))
         (store (file-name-as-directory (expand-file-name (cc-butler-governance-store))))
         (dir-matches
          (and exists
               (equal (file-name-as-directory (expand-file-name (file-name-directory file)))
                      store)))
         (namespaced (if (fboundp 'cc-butler--north-star-file-namespaced-p)
                          (cc-butler--north-star-file-namespaced-p file)
                        'not-checked)))
    (cond
     ((not file)
      (list :ok nil :detail "north-star file: cc-butler-north-star-file is unset"))
     ((not exists)
      (list :ok nil :detail (format "north-star file: %s does not exist on disk" file)))
     ((not dir-matches)
      (list :ok nil
            :detail (format "north-star file: %s is not inside the currently effective governance store (%s)"
                            file store)))
     ((eq namespaced nil)
      (list :ok nil
            :detail (format "north-star file: %s failed the namespaced-basename check (cc-butler--north-star-file-namespaced-p)"
                            file)))
     (t
      (list :ok t
            :detail (format "north-star file: %s exists, inside the current governance store%s"
                            file
                            (if (eq namespaced 'not-checked)
                                " (namespaced-basename check not available — PR #73 not loaded)"
                              "")))))))

;;;; ------------------------------------------------------------------
;;;; Check 4: module load path -- DELIBERATE PARTIAL IMPLEMENTATION
;;;; ------------------------------------------------------------------

;; PR #74's runtime-source vars, in cc-butler.el -- which REQUIRES this file
;; (cc-butler-self-check), so this file cannot require it back. Bare defvars,
;; same forward-reference workaround as the `fboundp' guard on
;; `cc-butler--commit-merged-p' below: both are only ever read once cc-butler.el
;; has finished loading and actually set them.
(defvar cc-butler--runtime-source-dir)
(defvar cc-butler--runtime-commit-sha)

(defun cc-butler-self-check--module-load-path ()
  "Check 4 (partial by design -- see the design doc, verdict 3): the full
\"running code == stable install location\" comparison needs the
`.emacs.d' stable-path decision (a separate, still-open PR #1) as a
baseline, which does not exist yet.  What CAN run today: PR #74's
`cc-butler--commit-merged-p' ancestry check, which independently catches
the hot-load-of-unmerged-code half of this defect class (the actual
2026-08-14 PR #71 incident) even with no stable-path baseline.  Guarded
by `fboundp' since PR #74 may not
be merged in a given fleet; when it is not, this reports :ok t with a
detail string that says explicitly WHY it was not checked -- a bare
\"not checked\" would be indistinguishable from a real pass, repeating
tonight's exact mistake one level up."
  (if (fboundp 'cc-butler--commit-merged-p)
      (let ((verdict (cc-butler--commit-merged-p cc-butler--runtime-source-dir
                                                  cc-butler--runtime-commit-sha)))
        (if (eq verdict 'unmerged)
            (list :ok nil
                  :detail (format "module load path: running code is UNMERGED — not reachable from origin/main (cc-butler--commit-merged-p -> %s); this is a hot-load of unreleased code"
                                  verdict))
          (list :ok t
                :detail (format "module load path: running code is reachable from origin/main (cc-butler--commit-merged-p -> %s). NOTE: this only checks ancestry, not stable-install-path equality — that half is still pending .emacs.d PR #1"
                                verdict))))
    (list :ok t
          :detail "module load path: not verified — no stable-install-path baseline yet, pending .emacs.d PR #1, and the ancestry-check dependency (PR #74's cc-butler--commit-merged-p) is not loaded in this fleet")))

;;;; ------------------------------------------------------------------
;;;; Check 5: persisted vs. live -- would this survive a restart?
;;;; ------------------------------------------------------------------

(defcustom cc-butler-self-check-tracked-variables '(claude-code-ide-mcp-server-port)
  "EXTRA variables checked for persisted-vs-live drift by check 5
\(`cc-butler-self-check--persisted-vs-live'), beyond the automatic scan
\(`cc-butler--defcustom-symbols-all').  The automatic scan is now the
PRIMARY population -- it reads every defcustom/defvar across cc-butler.el
and `cc-butler--modules' from source text, so it cannot silently narrow as
the codebase grows the way a hand-maintained list did: on 2026-09-10 this
list tracked 2 of ~8 variables that actually mattered that day, the exact
\"hand-maintained population silently narrows\" failure this closes.

Only useful now for a symbol the scan genuinely cannot see -- the
canonical case is `claude-code-ide-mcp-server-port' itself: it belongs to
the third-party `claude-code-ide' package, not to cc-butler.el or any
module in `cc-butler--modules', so `cc-butler--defcustom-symbols-all'
structurally cannot ever see it no matter how thorough the scan gets
\(confirmed live, 2026-09-10: `cc-butler-north-star-file' was dropped from
this list at the same time as genuinely redundant with the scan, which
was correct -- but `claude-code-ide-mcp-server-port' was dropped alongside
it, which was not, and is the textbook case this EXTRA list exists for).
Also useful for a symbol defined inside a macro the read-don't-eval reader
does not expand.

An EXTRA-list-only symbol -- one the automatic scan cannot see -- is
flagged by check 5 whenever unsaved and differing from its own
`standard-value', with no stuck-vs-deliberate label applied: that
classification depends on this repo's own git history, which does not
exist for a symbol belonging to another package.

An entry here is only actually MONITORABLE by check 5 if it is a
`defcustom' (i.e. has a `standard-value' symbol property -- only
`defcustom'/`custom-declare-variable' ever set one). A plain `defvar' has
no `standard-value' and so cannot be compared against \"what it would
revert to on restart\" at all; check 5 flags that case as its own distinct
failure (\"... has no standard-value ... cannot be monitored\") rather than
silently passing it through."
  :type '(repeat symbol)
  :group 'cc-butler)

(defun cc-butler-self-check--persisted-vs-live ()
  "Check 5: every tracked variable's `custom-variable-state' is `saved' or
`standard' -- i.e. would still hold this value after an Emacs restart --
UNLESS its live value already equals the current code-default, in which
case a restart gives back that exact same value anyway and there is
nothing to lose (2026-09-10: steward set `cc-butler-launch-ready-timeout'
live to 8 with `saved-value' nil, deliberately -- that must read as OK,
not bad).

A symbol whose state is unsaved AND whose value also appears in
`cc-butler--defcustom-drift-all' (i.e. genuinely differs from the
code-default) is only flagged if that drift's label -- via the same
`cc-butler--defcustom-file-for-symbol' + `cc-butler--defcustom-drift-label'
mechanism check 7 already uses -- comes back \"(likely stuck reload)\".
REGRESSION FIX (2026-09-10, live): before this, any unsaved+differing
symbol was flagged regardless of label, and once the population widened
(PR #225) that hit 8 symbols, 7 of which were legitimate live
customizations -- pure noise. A \"(likely deliberate customization)\"
label, or unlabelable drift, must not flag here any more than it fails
check 7.

`cc-butler--defcustom-drift-all' only walks `cc-butler--modules' (this
repo's own source), so a symbol reaching this check ONLY via the EXTRA
list `cc-butler-self-check-tracked-variables' -- never found by
`cc-butler--defcustom-symbols-all' either, the exact shape of
`claude-code-ide-mcp-server-port', a third-party package's defcustom --
never appears in `drift' at all. For that case there is no git history to
walk and no stuck-vs-deliberate label to ask for, so this compares the
live value directly against the symbol's own `standard-value' (the
built-in, package-agnostic default Emacs already tracks) and flags it
whenever unsaved AND differing -- no attempt at a stuck/deliberate
distinction, unlike the in-repo path above. The EXTRA list is small and
opt-in: each symbol on it was deliberately chosen because its
restart-survival matters enough to watch, so failing open here (flag
first, let a human judge) is the right default -- unlike the broad
auto-scanned population, where doing the same produced the 7-of-8 noise
regression this docstring already describes.

Distinct from check 7 (`cc-butler-self-check--code-vs-live-defcustom'):
that one asks whether the value running RIGHT NOW already matches what
the code says, restart or not; this one asks only whether it would
SURVIVE a restart.

Population is the automatic scan (`cc-butler--defcustom-symbols-all')
plus `cc-butler-self-check-tracked-variables' (now an EXTRA list -- see
its docstring).

An EXTRA-list entry only counts as monitorable if it is a `defcustom'
(has a `standard-value' property). A plain `defvar' added to the EXTRA
list has none, so this check cannot tell what it would revert to on
restart; rather than silently doing nothing (indistinguishable from \"all
clear\"), that case is flagged as its own distinct failure naming the
symbol and stating it has no `standard-value'."
  (let* ((dir (cc-butler-source-dir))
         (auto (cc-butler--defcustom-symbols-all dir))
         (drift (cc-butler--defcustom-drift-all dir))
         bad)
    (dolist (sym (delete-dups (append auto cc-butler-self-check-tracked-variables)))
      (when (boundp sym)
        (let ((state (custom-variable-state sym (symbol-value sym))))
          (when (not (memq state '(saved standard)))
            (let ((triple (assq sym drift)))
              (cond
               (triple
                (let* ((live (nth 1 triple)) (code-default (nth 2 triple))
                       (file (cc-butler--defcustom-file-for-symbol dir sym))
                       (label (and file (cc-butler--defcustom-drift-label file sym live code-default))))
                  (when (and label (string-match-p "\\`(likely stuck reload)" label))
                    (push (cons sym state) bad))))
               ;; Not present in `drift' -- either an EXTRA-list-only symbol
               ;; the in-repo scanner can't see, or an in-repo symbol that
               ;; simply isn't drifted right now (`cc-butler--defcustom-drift'
               ;; only pushes a symbol onto `drift' when its live value
               ;; already differs from the freshly-recomputed code-default).
               ;; No git history to classify stuck-vs-deliberate either way;
               ;; compare directly against `standard-value' and flag on any
               ;; genuine difference.
               ((get sym 'standard-value)
                (let ((standard (eval (car (get sym 'standard-value)) t)))
                  (when (not (equal (symbol-value sym) standard))
                    (push (cons sym state) bad))))
               ;; No `standard-value' AND not in `auto' (the in-repo scan) --
               ;; the only way such a symbol reached this loop at all is
               ;; `cc-butler-self-check-tracked-variables'.  Only
               ;; `defcustom'/`custom-declare-variable' populate
               ;; `standard-value', so this is a plain `defvar' someone added
               ;; to the EXTRA list.  This check has no way to know what it
               ;; would revert to on restart; doing nothing here would
               ;; silently report :ok with no mention of the gap, so flag it
               ;; as its own distinct failure instead.
               ((not (memq sym auto))
                (push (cons sym :no-standard-value) bad))
               ;; Else: an in-repo symbol (`auto' already returns it), not
               ;; drifted, and happens to have no `standard-value' -- a
               ;; plain top-level `defvar' like `cc-butler-project-templates'.
               ;; `custom-variable-state' reports `rogue' (not
               ;; `saved'/`standard') for ANY plain `defvar' regardless of
               ;; drift, which is why this case reaches here at all -- but
               ;; `cc-butler--defcustom-drift-all' COULD monitor it (via its
               ;; own code-default) and currently has nothing to report, so
               ;; this is a healthy variable, not an unmonitorable one.
               ;; Nothing to flag.
               ))))))
    (setq bad (nreverse bad))
    (if bad
        (list :ok nil
              :detail (format "persisted vs live: %s"
                              (mapconcat
                               (lambda (b)
                                 (if (eq (cdr b) :no-standard-value)
                                     (format "%s is in `cc-butler-self-check-tracked-variables' but has no standard-value -- not a defcustom, cannot be monitored for persisted-vs-live drift" (car b))
                                   (format "%s is `%s' (not saved/standard)" (car b) (cdr b))))
                               bad "; ")))
      (list :ok t
            :detail "persisted vs live: no tracked variable is both unsaved and labeled a likely stuck reload (in-repo), or unsaved and differing from its own standard-value (EXTRA-list-only)"))))

;;;; ------------------------------------------------------------------
;;;; Check 6: vault path -- WARMBLE_JUMBLE_PATH vs. the governance store
;;;; ------------------------------------------------------------------

(defun cc-butler-self-check--vault-path ()
  "Check 6: `WARMBLE_JUMBLE_PATH' (if set) resolves to the same directory
`cc-butler-governance-store' actually reads from.  Both can be genuine
vault clones of the same origin, so no existence check catches a drift --
only asking whether they agree does.  cc-butler's own correctness does
not depend on this env var (the Emacs daemon does not inherit it); this
exists as a canary for OTHER tooling (wb-para's vault_paths.py,
push-vault.sh, the Stop hook) silently operating on a stale clone.
Reports only -- never edits `~/.zshrc' or any other shell config."
  (let* ((env (getenv "WARMBLE_JUMBLE_PATH"))
         (env-abs (and env (not (string-empty-p env))
                       (file-name-as-directory (expand-file-name env))))
         (store (file-name-as-directory (expand-file-name (cc-butler-governance-store)))))
    (cond
     ((not env-abs)
      (list :ok t :detail "vault path: WARMBLE_JUMBLE_PATH not set — nothing to compare"))
     ((equal env-abs store)
      (list :ok t
            :detail (format "vault path: WARMBLE_JUMBLE_PATH matches the governance store (%s)" store)))
     (t
      (list :ok nil
            :detail (format "vault path: WARMBLE_JUMBLE_PATH (%s) != governance store (%s)"
                            env-abs store))))))

;;;; ------------------------------------------------------------------
;;;; Check 7: code vs. live defcustom -- is this already wrong RIGHT NOW?
;;;; ------------------------------------------------------------------

(defun cc-butler-self-check--code-vs-live-defcustom ()
  "Check 7: any defcustom/defvar whose LIVE value matches a value the code
used to ship as its default, before a later commit changed the default --
the \"stuck reload\" shape (2026-09-05: `cc-butler-launch-ready-timeout'
raised 5->8 in source, stayed live at 5 through a reload, and sat that
way for 5 days because nothing periodic ever asked).  Distinct from check
5 (persisted-vs-live): that one asks whether a live value SURVIVES a
restart; this one asks whether the value running RIGHT NOW already
matches what the code currently says it should be, restart or not.

Reuses `cc-butler--defcustom-drift-all' (the exact enumeration
`cc-butler-reload' itself reports) and `cc-butler--defcustom-drift-label'
(the exact stuck-vs-deliberate classifier) rather than reimplementing
either.

Only a \"(likely stuck reload)\" label fails this check -- a \"(likely
deliberate customization)\" label, or unlabelable drift (no git history
to match against -- e.g. a default that has never changed, like
`cc-butler-decision-workflow', 2026-09-10), is ordinary customization and
must not page anyone."
  (let* ((dir (cc-butler-source-dir))
         (drift (cc-butler--defcustom-drift-all dir))
         stuck)
    (dolist (triple drift)
      (let* ((sym (nth 0 triple)) (live (nth 1 triple)) (code-default (nth 2 triple))
             (file (cc-butler--defcustom-file-for-symbol dir sym))
             (label (and file (cc-butler--defcustom-drift-label file sym live code-default))))
        (when (and label (string-match-p "\\`(likely stuck reload)" label))
          (push (list sym live code-default label) stuck))))
    (setq stuck (nreverse stuck))
    (if stuck
        (list :ok nil
              :detail (format "code-vs-live defcustom: %s"
                              (mapconcat
                               (lambda (s) (format "%s live=%S code-default=%S %s"
                                                    (nth 0 s) (nth 1 s) (nth 2 s) (nth 3 s)))
                               stuck "; ")))
      (list :ok t
            :detail (format "code-vs-live defcustom: %d drifted symbol(s) checked, none labeled stuck reload"
                            (length drift))))))

;;;; ------------------------------------------------------------------
;;;; Check 8: orphaned inboxes -- unread mail nobody will ever read
;;;; ------------------------------------------------------------------
;;
;; Found live: a directory named `___' held unread mail, an artifact of a
;; display-name regex bug (fixed in PR #183, commits 9d3a79a/7884dbe) that
;; collapsed any non-ASCII display name to that literal placeholder.
;; Current code can never regenerate that slug again, so that inbox is now
;; structurally unreachable forever -- and separately, a currently-not-live
;; agent's inbox can also hold undelivered mail.  Nothing before this check
;; ever enumerated inbox directories against the live-session set, so both
;; cases were silent.

(defcustom cc-butler-self-check-orphan-inbox-age-threshold (* 7 24 60 60)
  "Seconds an inbox's oldest unread message must sit before check 8
\(`cc-butler-self-check--orphaned-inboxes') flags its directory as an
orphan candidate.  Only applies to a slug with NO currently live
session -- liveness gates the whole check first, so a busy worker's
backlog is never touched here regardless of this value.

Deliberately generous (7 days), not a tight window: a worker that
merely restarted minutes or hours ago is not evidence of anything
wrong, and a short threshold would flag that routine gap the same as
genuinely orphaned mail -- e.g. the `___' inbox this check exists to
catch, unreachable since PR #183's display-name regex fix."
  :type 'integer
  :group 'cc-butler)

(defun cc-butler-self-check--live-inbox-slugs ()
  "Return the set of maildir slugs every currently live session maps to
\(a hash-table, for O(1) membership tests), via `cc-butler--sessions' --
the fleet's existing liveness roster -- and the same
`cc-butler--mail-slug' + `cc-butler--display-name' derivation the mail
delivery path itself uses for a session's `:dir'."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (s (cc-butler--sessions))
      (puthash (cc-butler--mail-slug (cc-butler--display-name (plist-get s :dir)))
                t table))
    table))

(defun cc-butler-self-check--inbox-dirs ()
  "Return the basenames of every immediate subdirectory of
`cc-butler-mail-dir' that could be a per-agent inbox -- i.e. every
subdirectory except the channel journal directory (`cc-butler--mail-log-dir',
never a guessed literal).  Nil when `cc-butler-mail-dir' does not exist."
  (let ((root (file-name-as-directory (expand-file-name cc-butler-mail-dir))))
    (when (file-directory-p root)
      (let ((log-name (file-name-nondirectory
                        (directory-file-name (cc-butler--mail-log-dir)))))
        (seq-filter
         (lambda (name)
           (and (not (equal name log-name))
                (file-directory-p (expand-file-name name root))))
         (ignore-errors (directory-files root nil "\\`[^.]")))))))

(defun cc-butler-self-check--inbox-new-files (slug)
  "Return the list of message files directly under
<`cc-butler-mail-dir'>/SLUG/new/, or nil when that directory does not
exist or holds none."
  (let ((newdir (expand-file-name (concat slug "/new/")
                                  (file-name-as-directory
                                   (expand-file-name cc-butler-mail-dir)))))
    (and (file-directory-p newdir)
         (seq-filter #'file-regular-p
                     (ignore-errors (directory-files newdir t "\\`[^.]"))))))

(defun cc-butler-self-check--inbox-oldest-age (files)
  "Return the age in seconds of the oldest of FILES (by modification
time), or nil for empty FILES.  Reads only file metadata -- never
message content (sender/body) -- matching this codebase's convention
that check/report output must never surface private runtime content
\(same reasoning as the `--'-prefixed-symbol exclusion in
`cc-butler--defcustom-drift-internal-p')."
  (when files
    (let (oldest)
      (dolist (f files)
        (let ((mtime (file-attribute-modification-time (file-attributes f))))
          (when (or (null oldest) (time-less-p mtime oldest))
            (setq oldest mtime))))
      (float-time (time-subtract (current-time) oldest)))))

(defun cc-butler-self-check--inbox-newest-mtime (files)
  "Return the modification time of the most recently modified of FILES,
or nil for empty FILES.  Mirror image of `cc-butler-self-check--inbox-oldest-age'
\(that one returns an age for the oldest; this returns a raw time value
for the newest) -- needed by the acknowledgment re-trigger comparison in
`cc-butler-self-check--orphan-acknowledged-p', which reacts to the
newest arrival, not the oldest."
  (when files
    (let (newest)
      (dolist (f files)
        (let ((mtime (file-attribute-modification-time (file-attributes f))))
          (when (or (null newest) (time-less-p newest mtime))
            (setq newest mtime))))
      newest)))

(defun cc-butler-self-check--orphan-ack-file (slug)
  "Return the path to SLUG's orphan-acknowledgment marker file: a dotfile
at the inbox root (<`cc-butler-mail-dir'>/SLUG/.orphan-ack), deliberately
NOT inside new/ so it is never itself enumerated as a pending message by
`cc-butler-self-check--inbox-new-files'."
  (expand-file-name ".orphan-ack" (cc-butler--mail-inbox slug)))

(defun cc-butler-self-check--orphan-acknowledged-p (slug files)
  "Return non-nil when SLUG's orphan candidacy is currently acknowledged:
its `.orphan-ack' marker exists and its modification time is >= the
newest of FILES (the inbox's current new/ contents).  Any message newer
than the marker -- or no marker at all -- makes this nil regardless of a
prior acknowledgment: acknowledging silences only the mail that existed
at ack time, not mail delivered afterward."
  (let ((ack-file (cc-butler-self-check--orphan-ack-file slug))
        (newest (cc-butler-self-check--inbox-newest-mtime files)))
    (and newest
         (file-exists-p ack-file)
         (not (time-less-p
               (file-attribute-modification-time (file-attributes ack-file))
               newest)))))

(defun cc-butler-self-check--orphan-candidates-format (candidates)
  "Format CANDIDATES (a list of (slug pending-count age) as pushed by
`cc-butler-self-check--orphaned-inboxes') the same way that check has
always formatted its :detail entries."
  (mapconcat
   (lambda (c)
     (format "%s (%d pending, oldest %s)"
             (nth 0 c) (nth 1 c)
             (cc-butler--decision-format-age (nth 2 c))))
   candidates "; "))

(defun cc-butler-self-check--orphan-ack-reason (slug)
  "Return the reason text recorded in SLUG's `.orphan-ack' marker file
\(see `cc-butler-self-check--orphan-ack-content'), or nil when the
marker does not exist."
  (let ((ack-file (cc-butler-self-check--orphan-ack-file slug)))
    (when (file-exists-p ack-file)
      (with-temp-buffer
        (insert-file-contents ack-file)
        (nth 1 (split-string (buffer-string) "\n"))))))

(defun cc-butler-self-check--orphan-ack-candidates-format (candidates)
  "Like `cc-butler-self-check--orphan-candidates-format', but for the
ACKNOWLEDGED branch only: each entry also names the reason it was
acknowledged for (`cc-butler-self-check--orphan-ack-reason') -- an
acknowledged candidate with no visible reason repeats the exact
erasure (who judged this fine, and why) this check exists to catch."
  (mapconcat
   (lambda (c)
     (format "%s (%d pending, oldest %s, ack'd: %s)"
             (nth 0 c) (nth 1 c)
             (cc-butler--decision-format-age (nth 2 c))
             (or (cc-butler-self-check--orphan-ack-reason (nth 0 c)) "unknown")))
   candidates "; "))

(defun cc-butler-self-check--orphaned-inboxes ()
  "Check 8: an inbox directory under `cc-butler-mail-dir' whose slug maps
to no currently live session, AND whose oldest unread message in new/
has sat for at least `cc-butler-self-check-orphan-inbox-age-threshold'
seconds, is an orphan candidate -- unread mail nobody will ever read.
Read-only: never deletes, moves, or marks a message read.

Candidates split further into ACTIVE and ACKNOWLEDGED (see
`cc-butler-self-check--orphan-acknowledged-p') -- a deliberate,
documented non-fix (mail staying in place pending separate disposal
work) must not keep this check permanently red once someone has looked
at it, or it trains people to stop looking, same failure mode as a
false positive.  So `:ok' is t iff there are zero ACTIVE candidates;
an acknowledged-but-still-pending candidate never fails `:ok', but it is
always still named in `:detail' -- acknowledgment silences the FAILURE,
never the VISIBILITY.

Two false-positive guards, both load-bearing (see this check's own
design brief):
 - liveness gates the WHOLE check -- a currently live agent's own
   unread backlog is never flagged, no matter how old (busy, not
   orphaned);
 - a not-live slug whose oldest unread message is still under the
   threshold is not flagged either (a worker that merely restarted
   minutes/hours ago is not evidence of anything wrong)."
  (let ((live (cc-butler-self-check--live-inbox-slugs))
        active acknowledged)
    (dolist (slug (cc-butler-self-check--inbox-dirs))
      (unless (gethash slug live)
        (let* ((files (cc-butler-self-check--inbox-new-files slug))
               (age (cc-butler-self-check--inbox-oldest-age files)))
          (when (and age (>= age cc-butler-self-check-orphan-inbox-age-threshold))
            (let ((c (list slug (length files) age)))
              (if (cc-butler-self-check--orphan-acknowledged-p slug files)
                  (push c acknowledged)
                (push c active)))))))
    (setq active (nreverse active)
          acknowledged (nreverse acknowledged))
    (cond
     ((and (null active) (null acknowledged))
      (list :ok t :detail "orphaned inboxes: none"))
     (active
      (list :ok nil
            :detail (concat
                     (format "orphaned inboxes: %s"
                             (cc-butler-self-check--orphan-candidates-format active))
                     (when acknowledged
                       (format "; acknowledged: %s"
                               (cc-butler-self-check--orphan-ack-candidates-format acknowledged))))))
     (t
      (list :ok t
            :detail (format "orphaned inboxes: none active; acknowledged: %s"
                             (cc-butler-self-check--orphan-ack-candidates-format acknowledged)))))))

;;;; ------------------------------------------------------------------
;;;; Orphan-inbox acknowledgment -- quiets check 8 for existing mail only
;;;; ------------------------------------------------------------------

(defun cc-butler-self-check--orphan-ack-content (reason)
  "Return the `.orphan-ack' marker file content recording REASON: two
human-readable, greppable lines -- an ISO-ish acknowledgment timestamp,
then REASON itself.  Content only, for a human/agent reading the marker
-- the re-trigger mechanism in `cc-butler-self-check--orphan-acknowledged-p'
never parses this; it keeps comparing the marker file's own mtime."
  (concat (format-time-string "%FT%T") "\n" reason "\n"))

(defun cc-butler-self-check-acknowledge-orphan-inbox (slug reason)
  "Acknowledge SLUG's orphan-inbox candidacy for now, recording REASON --
who judged it fine and why.  This is NOT permanent and NOT a deletion:
it only creates/rewrites the `.orphan-ack' marker file at the inbox
root (`cc-butler-self-check--orphan-ack-file', content from
`cc-butler-self-check--orphan-ack-content'), which silences check 8's
`:ok' for the mail that exists right now -- the moment one more message
is delivered to SLUG, `cc-butler-self-check--orphan-acknowledged-p'
goes false again and the check re-triggers automatically.  Never reads,
moves, or deletes anything under new/, tmp/, or archive/.

REASON must be a non-blank string (not empty, not only whitespace).  A
marker recording only a timestamp says someone judged this fine but
erases who and why -- exactly the failure this check exists to surface
for un-actioned mail.  A blank REASON signals an error and creates or
touches NOTHING -- not even when a marker already exists for SLUG; it
must never overwrite a prior good acknowledgment with nothing.

Signals an error, and creates nothing, when SLUG does not name an
existing inbox directory directly under `cc-butler-mail-dir' -- this
must never silently create an arbitrary directory."
  (interactive
   (list (completing-read "Acknowledge orphan inbox: "
                           (cc-butler-self-check--inbox-dirs) nil t)
         (read-string "Reason: ")))
  (unless (member slug (cc-butler-self-check--inbox-dirs))
    (error "cc-butler: %S is not a known mail inbox under `cc-butler-mail-dir'" slug))
  (when (string-empty-p (string-trim (or reason "")))
    (error "cc-butler: acknowledging %S requires a non-blank reason" slug))
  (write-region (cc-butler-self-check--orphan-ack-content reason)
                nil (cc-butler-self-check--orphan-ack-file slug) nil 'silent)
  slug)

;;;; ------------------------------------------------------------------
;;;; Check 9: queue vs. room -- thread activity surfaced, never judged
;;;; ------------------------------------------------------------------
;;
;; A real incident: a decision was already answered/closed in the Matrix
;; room (a follow-up reply existed in that event's thread), but the local
;; open/ queue file was never updated to reflect that -- so the queue kept
;; counting it as "awaiting answer" and the same closure notice was sent a
;; second time, hours later, because the stale count was trusted.
;;
;; The FIRST implementation of this check tried to detect that directly:
;; a reply from this fleet's own Matrix identity, posted after delivery,
;; was treated as proof of closure.  On its first live run it mislabeled
;; multiple genuinely still-open decisions as closed -- some of them
;; production state-change questions -- because this fleet's own delivery
;; convention posts the decision's body as a threaded reply to its own
;; header, so EVERY delivered decision already carries a self-authored
;; reply before anyone, human or fleet, ever answers it.  The predicate
;; wasn't measuring closure; it was re-detecting its own delivery
;; mechanism.  Narrowing the predicate (e.g. requiring a NON-self sender)
;; is not a fix -- it is the same mistake at a smaller radius: it lowers
;; how OFTEN the check is wrong without changing WHETHER it can be wrong,
;; and a rarer false closure is more dangerous, not less, because it is
;; less likely to be caught by chance.
;;
;; So this check makes NO closure judgment at all, by design.  For each
;; locally-open decision with a recorded Matrix delivery, it fetches that
;; event's thread and reports what is there -- scanned message count and a
;; raw sender/count breakdown -- as material for a human to read.  Every
;; candidate this check can reconcile stays counted as "awaiting answer"
;; regardless of what its thread shows; nothing here ever removes a
;; decision from that count.  See this check's own test file for the
;; permanent negative controls pinning this down, including the exact
;; false-positive shape found live (a thread with only a self-authored
;; reply and zero others).
;;
;; Also unchanged from the first version: this is FORWARD-ONLY, starting
;; from the file (a declared, bounded population), never from the room.
;; Deliberately NOT built: a reverse check (scanning the room for
;; un-registered questions).  The room has no way to self-label "this
;; message is a question", so a reverse detector would be an unfalsifiable
;; heuristic over an unconstrained population -- see this check's own test
;; file for the two permanent negative controls that follow from that.

(defun cc-butler-self-check--queue-room-matrix-configured-p ()
  "Non-nil when this fleet has Matrix bridging configured enough for check 9
to attempt reconciliation at all: a self identity AND an on-disk token
file.  `matrix-bridge-self-user-id' is genuinely nil on a fleet that never
set up Matrix -- a normal, valid state, not a defect -- so this check must
not fail for that reason; it skips instead (see the caller)."
  (and matrix-bridge-self-user-id
       matrix-bridge-token-file
       (file-exists-p matrix-bridge-token-file)))

(defun cc-butler-self-check--queue-room-reason-label (reason)
  "Human-readable label for one `cc-butler-self-check--queue-room-reconcile-one'
unverifiable REASON symbol -- kept distinct per reason in `:detail' rather
than collapsed into one undifferentiated \"unverifiable\" count, since each
points at a different, useful diagnostic (never delivered vs. delivered but
un-recorded room vs. a wrong recorded room vs. a fetch failure)."
  (pcase reason
    ('no-delivery "no :Delivered-to-matrix: recorded")
    ('no-room "no :Room: recorded")
    ('not-in-room "recorded room does not contain the event (M_NOT_FOUND)")
    ('fetch-error "fetch failed")
    (_ (symbol-name reason))))

(defun cc-butler-self-check--queue-room-sender-counts (events)
  "Alist of sender -> message count from EVENTS (as returned by
`matrix-bridge-thread-replies''s `:events'), in first-seen order.  Raw
material for a human to read -- this function makes no judgment about
whether any of it means a decision is answered."
  (let (counts)
    (dolist (ev events)
      (let* ((sender (matrix-bridge--get ev 'sender))
             (cell (assoc sender counts)))
        (if cell
            (setcdr cell (1+ (cdr cell)))
          (push (cons sender 1) counts))))
    (nreverse counts)))

(defun cc-butler-self-check--queue-room-sender-summary (senders)
  "Format SENDERS (an alist from `cc-butler-self-check--queue-room-sender-counts')
as \"sender x N; sender x N\", for `:detail'."
  (mapconcat (lambda (s) (format "%s x%d" (car s) (cdr s))) senders "; "))

(defun cc-butler-self-check--queue-room-reconcile-one (path)
  "Reconcile one open/ decision file at PATH.  Returns a plist:
  (:bucket open :scanned N :senders ALIST)  -- thread fetched; ALIST (from
                                                `cc-butler-self-check--queue-room-sender-counts')
                                                is raw material for a human
                                                to read -- this function
                                                never judges whether any of
                                                it means the decision was
                                                answered.  Even N = 0 lands
                                                here: a successful fetch
                                                that finds nothing is a
                                                meaningful \"checked, no
                                                thread activity at all\".
  (:bucket unverifiable :reason R)          -- R one of `no-delivery' `no-room'
                                                `not-in-room' `fetch-error'.
Either property missing (`no-delivery'/`no-room') is checked BEFORE ever
calling out to Matrix at all -- an unverifiable decision must never guess
at a room to fetch from.

This check has NO closure bucket.  A thread reply -- even one from this
fleet's own identity -- is not evidence of an answer: this fleet's own
delivery convention posts the decision body itself as a threaded reply, so
every successfully delivered decision carries at least one self-authored
reply from the moment it is sent, whether or not anyone ever answers it.
Treating that as \"already handled\" mislabeled multiple live, still-open
decisions as closed the first time this check ran end-to-end -- some of
them production state-change questions that would have silently vanished
from the queue.  See this check's own test file for the permanent negative
controls pinning this down."
  (let ((event-id (cc-butler--decision-delivered-to-matrix-event-id path))
        (room (cc-butler--decision-room-id path)))
    (cond
     ((not event-id) (list :bucket 'unverifiable :reason 'no-delivery))
     ((not room) (list :bucket 'unverifiable :reason 'no-room))
     (t
      (let ((resp (matrix-bridge-thread-replies room event-id)))
        (pcase (plist-get resp :status)
          ('not-in-room (list :bucket 'unverifiable :reason 'not-in-room))
          ('error (list :bucket 'unverifiable :reason 'fetch-error))
          ('ok
           (list :bucket 'open
                 :scanned (plist-get resp :scanned)
                 :senders (cc-butler-self-check--queue-room-sender-counts
                           (plist-get resp :events))))))))))

(defun cc-butler-self-check--queue-room-reconciliation ()
  "Check 9: reconciliation between the open/ decision queue and the Matrix
room a delivered decision was posted into -- see the section commentary
above for the incident this exists to catch and why a reverse (room->queue)
scan is explicitly out of scope.

Candidates are `cc-butler--decision-open-files-and-oldest''s existing
`Kind: decision' population (reused, not re-scanned).  When Matrix is not
configured on this fleet at all (`cc-butler-self-check--queue-room-matrix-configured-p'),
reconciliation is skipped entirely and `:ok' is t -- a fleet without
Matrix wired up is a normal state, not a defect.

Otherwise, each candidate lands in one of two buckets
(`cc-butler-self-check--queue-room-reconcile-one'): OPEN (the thread was
fetched -- `:detail' carries its scanned-message count and a raw
sender/count breakdown, for a human to read) or UNVERIFIABLE (missing
`:Delivered-to-matrix:'/`:Room:', the recorded room turned out wrong, or
the fetch itself failed).  Every candidate in either bucket counts toward
the same \"still awaiting answer\" total -- nothing here ever removes a
decision from that count.

`:ok' is unconditionally t whenever Matrix is configured -- this check has
NO closure verdict to fail on (see `cc-butler-self-check--queue-room-reconcile-one''s
docstring for why: thread activity, even from this fleet's own identity,
is not evidence of an answer). Its entire value is surfacing raw
per-candidate thread material in `:detail' for a human to read and judge
-- not judging on their behalf. `:detail' always names: total candidates,
the open count (with each file's scanned-reply count and sender
breakdown), the unverifiable count (broken down by reason), and the
aggregate scanned-message total paired with how many decisions were
actually reconciled -- so a reader can tell \"the check ran and found
nothing\" apart from \"the check silently didn't run\"."
  (if (not (cc-butler-self-check--queue-room-matrix-configured-p))
      (let ((n (length (car (cc-butler--decision-open-files-and-oldest)))))
        (list :ok t
              :detail (format "queue-room reconciliation: skipped — Matrix not configured on this fleet (%s); %d open decision(s) left unreconciled"
                               (if (not matrix-bridge-self-user-id)
                                   "matrix-bridge-self-user-id is nil"
                                 "matrix-bridge-token-file does not exist")
                               n)))
    (let* ((dir (cc-butler--decision-open-dir))
           (files (car (cc-butler--decision-open-files-and-oldest)))
           open unverifiable (scanned-total 0) (reconciled 0))
      (dolist (f files)
        (let ((r (cc-butler-self-check--queue-room-reconcile-one (expand-file-name f dir))))
          (pcase (plist-get r :bucket)
            ('open
             (setq reconciled (1+ reconciled) scanned-total (+ scanned-total (plist-get r :scanned)))
             (push (list f (plist-get r :scanned) (plist-get r :senders)) open))
            ('unverifiable
             (push (cons f (plist-get r :reason)) unverifiable)))))
      (setq open (nreverse open) unverifiable (nreverse unverifiable))
      (let* ((reason-counts
              (mapcar (lambda (reason)
                        (cons reason (length (seq-filter (lambda (u) (eq (cdr u) reason)) unverifiable))))
                      '(no-delivery no-room not-in-room fetch-error)))
             (detail
              (format "queue-room reconciliation: %d candidate(s) — open %d%s · unverifiable %d (%s) — %d decision(s) reconciled, %d total thread message(s) scanned — this check never judges closure; read each before treating any as answered"
                      (length files)
                      (length open)
                      (if open
                          (format " [%s]"
                                  (mapconcat (lambda (o) (format "%s (scanned %d%s)"
                                                                  (nth 0 o) (nth 1 o)
                                                                  (if (nth 2 o)
                                                                      (format ": %s" (cc-butler-self-check--queue-room-sender-summary (nth 2 o)))
                                                                    "")))
                                             open "; "))
                        "")
                      (length unverifiable)
                      (mapconcat (lambda (rc) (format "%s %d"
                                                       (cc-butler-self-check--queue-room-reason-label (car rc))
                                                       (cdr rc)))
                                 reason-counts "; ")
                      reconciled scanned-total)))
        (list :ok t :detail detail)))))

;;;; ------------------------------------------------------------------
;;;; Registry
;;;; ------------------------------------------------------------------

(defconst cc-butler-self-check--checks
  '(("mcp-port" . cc-butler-self-check--mcp-port)
    ("governance-memory-dir" . cc-butler-self-check--governance-memory-dir)
    ("north-star-file" . cc-butler-self-check--north-star-file)
    ("module-load-path" . cc-butler-self-check--module-load-path)
    ("persisted-vs-live" . cc-butler-self-check--persisted-vs-live)
    ("vault-path" . cc-butler-self-check--vault-path)
    ("code-vs-live-defcustom" . cc-butler-self-check--code-vs-live-defcustom)
    ("orphaned-inboxes" . cc-butler-self-check--orphaned-inboxes)
    ("queue-room-reconciliation" . cc-butler-self-check--queue-room-reconciliation))
  "Alist of (NAME . FUNCTION).  FUNCTION takes no args, returns a plist
\(:ok BOOL :detail STRING).  Extensible -- new checks are just new entries,
so this does not stay a fixed list of six forever.

A `defconst' on purpose, not a `defvar' (2026-09-10 live: it was a `defvar'
when PR #225 added the 7th entry, and `cc-butler-reload' left an
already-running daemon stuck on the OLD 6-entry alist -- `defvar' with a
value only sets the symbol IF IT IS CURRENTLY UNBOUND, it never overwrites
an already-bound one, so check 7's function was defined but never actually
dispatched). This is a pure code-owned dispatch table, not a genuine
customization point nobody is meant to `setq' or Customize away from
source, so `defconst''s unconditional reassignment on every reload is
exactly right here, with nothing to lose -- same precedent as
`cc-butler--modules' in cc-butler.el.")

(defun cc-butler-self-check-run ()
  "Run every registered check.  Return an alist of (NAME . PLIST)."
  (mapcar (lambda (c) (cons (car c) (funcall (cdr c)))) cc-butler-self-check--checks))

;;;; ------------------------------------------------------------------
;;;; Reporting: quiet every tick, loud only on a transition
;;;; ------------------------------------------------------------------

(defvar cc-butler-self-check--previous nil
  "Alist NAME -> last-observed :ok value, for transition detection.
Absent on the very first tick a check is ever observed -- with no prior
state there is no transition to report, so the first observation of any
check never itself triggers an escalation, only establishes the baseline
future ticks compare against.")

(defun cc-butler-self-check--summary-line (results)
  "One-line ok/FAIL summary of RESULTS, for the quiet per-tick log."
  (mapconcat (lambda (r) (format "%s=%s" (car r) (if (plist-get (cdr r) :ok) "ok" "FAIL")))
             results " "))

(defun cc-butler-self-check--report (results)
  "Report RESULTS: a quiet per-tick summary no matter what, plus a loud
`display-warning' when anything is failing, plus a notification-kind
escalation for each check whose :ok flipped since the last tick (either
direction -- a fix must be announced as loudly as a break, or a human
carries a stale failure notification forever)."
  (let ((failing (seq-filter (lambda (r) (not (plist-get (cdr r) :ok))) results)))
    (when failing
      (display-warning
       'cc-butler-self-check
       (format "cc-butler self-check: %d failing — %s"
               (length failing)
               (mapconcat (lambda (r) (plist-get (cdr r) :detail)) failing " | "))))
    (ignore-errors
      (cc-butler-tool-log (format "self-check: %s" (cc-butler-self-check--summary-line results))
                           "event"))
    (dolist (r results)
      (let* ((name (car r))
             (ok (plist-get (cdr r) :ok))
             (cell (assoc name cc-butler-self-check--previous)))
        (if cell
            (progn
              (when (not (eq (cdr cell) ok))
                (ignore-errors
                  (cc-butler-tool-escalate-to-butler
                   (format "cc-butler self-check: `%s' %s — %s"
                           name (if ok "RECOVERED" "started FAILING")
                           (plist-get (cdr r) :detail))
                   nil nil "notification" "cc-butler (self-check)")))
              (setcdr cell ok))
          (push (cons name ok) cc-butler-self-check--previous)))))
  results)

;;;; ------------------------------------------------------------------
;;;; Timer + interactive command (mirrors cc-butler-north-star.el)
;;;; ------------------------------------------------------------------

(defcustom cc-butler-self-check-interval (* 15 60)
  "Seconds between self-check ticks.  15 minutes, uniform across all checks
\(verdict 1 -- differentiate only once evidence demands it; every check
here is a cheap local-state comparison, none is network- or terminal-I/O-
bound, and every 2026-08-14 incident was wrong for hours, not minutes)."
  :type 'number
  :group 'cc-butler)

(defvar cc-butler--self-check-timer nil
  "Repeating timer driving `cc-butler--self-check-fire', or nil before first use.")

(defun cc-butler--self-check-fire ()
  "Timer callback: run every check and report.  Unconditional -- unlike
`cc-butler--north-star-fire' this never types into any session's terminal,
so it does not need to gate on butler idleness."
  (cc-butler-self-check--report (cc-butler-self-check-run)))

;;;###autoload
(defun cc-butler-self-check ()
  "Run the self-check right now and report a one-line summary.
Mirrors `cc-butler-north-star-check' -- always messages, never silent."
  (interactive)
  (let ((results (cc-butler-self-check--report (cc-butler-self-check-run))))
    (message "cc-butler self-check: %s" (cc-butler-self-check--summary-line results))
    results))

(defun cc-butler--self-check-ensure-timer ()
  "(Re)register the self-check timer; idempotent for hot reloads."
  (when (timerp cc-butler--self-check-timer)
    (cancel-timer cc-butler--self-check-timer))
  (setq cc-butler--self-check-timer
        (run-with-timer cc-butler-self-check-interval
                         cc-butler-self-check-interval
                         #'cc-butler--self-check-fire)))

(cc-butler--self-check-ensure-timer)

;;;; ------------------------------------------------------------------
;;;; MCP tool: pull the full state on demand
;;;; ------------------------------------------------------------------

(defun cc-butler-tool-self-check ()
  "MCP tool: run the self-check on demand and return EVERY check's state,
ok and failing both -- a clean run should be positively confirmable, not
just silent."
  (let ((results (cc-butler-self-check-run)))
    (mapconcat
     (lambda (r)
       (format "[%s] %s — %s"
               (if (plist-get (cdr r) :ok) "OK" "FAIL")
               (car r) (plist-get (cdr r) :detail)))
     results "\n")))

;; Idempotent registration.
(when (fboundp 'claude-code-ide-make-tool)
  (setq claude-code-ide-mcp-server-tools
        (seq-remove
         (lambda (spec)
           (member (plist-get (claude-code-ide--normalize-tool-spec spec) :name)
                   '("self_check")))
         claude-code-ide-mcp-server-tools))
  (claude-code-ide-make-tool
   :function #'cc-butler-tool-self-check
   :name "self_check"
   :description "Pull the full state of cc-butler's periodic consistency self-check (existence -> consistency), on demand, from any fleet session. Nine checks: MCP bound port vs. each live session's actual connection port; governance memory write-path vs. read-path; the North Star file's existence + location inside the current governance store; the running module code's ancestry vs. origin/main (deliberately partial -- pending a separate stable-install-path decision); tracked customizable variables' persisted-vs-live state (would this survive a restart); WARMBLE_JUMBLE_PATH vs. the governance store (a cross-tool vault-drift canary); code-vs-live defcustom drift (is a live value already stuck on a superseded code default RIGHT NOW, restart or not); orphaned mail inboxes (a not-live agent's inbox with old unread mail nobody will ever read); and queue-room reconciliation (surfaces each locally-open decision's Matrix thread activity -- sender and message counts, not a closure verdict -- forward-only, file-driven only, never a reverse room scan). Returns EVERY check's state, ok and failing both -- a clean run is positively confirmable, not just silent."
   :args nil))

(defun cc-butler-tool-acknowledge-orphan-inbox (slug reason)
  "MCP tool: mark an orphaned inbox (as flagged by check 8 in `self_check')
as acknowledged for now, recording REASON.  This is NOT permanent and
NOT a deletion -- it only rewrites a marker file, never a message; a
new message arriving in that inbox afterward un-acknowledges it
automatically and check 8 goes active again on its own.  REASON is
required (not optional) because a marker recording only a timestamp
erases who judged the inbox fine and why -- this check exists
specifically to surface mail nobody actioned, so the acknowledgment
itself must not repeat that same erasure."
  (cc-butler-self-check-acknowledge-orphan-inbox slug reason)
  (format "Acknowledged orphan inbox %s for now -- a new message delivered to it will un-acknowledge it automatically." slug))

;; Idempotent registration.
(when (fboundp 'claude-code-ide-make-tool)
  (setq claude-code-ide-mcp-server-tools
        (seq-remove
         (lambda (spec)
           (member (plist-get (claude-code-ide--normalize-tool-spec spec) :name)
                   '("acknowledge_orphan_inbox")))
         claude-code-ide-mcp-server-tools))
  (claude-code-ide-make-tool
   :function #'cc-butler-tool-acknowledge-orphan-inbox
   :name "acknowledge_orphan_inbox"
   :description "Mark an already-known orphaned mail inbox (a not-live agent's inbox with old unread mail, as flagged by check 8 in self_check) as acknowledged-for-now. This is NOT permanent and NOT a deletion -- it only rewrites a marker file at the inbox root, never any message; a new message arriving in that inbox after acknowledgment automatically un-acknowledges it, and check 8 will flag it as failing again on its own, with no further action needed to re-arm it. Requires a reason: a marker recording only a timestamp erases who judged the inbox fine and why, which is exactly the erasure this check exists to surface -- so the acknowledgment itself must not repeat it."
   :args '((:name "slug"
                  :type string
                  :description "The inbox's directory name (slug) exactly as it appears in check 8's :detail output under the `orphaned-inboxes` entry of self_check.")
           (:name "reason"
                  :type string
                  :description "Why this inbox's current pending mail is fine to leave un-actioned for now, e.g. 'kept pending separate disposal work'. Required and must be non-blank -- shown back in self_check's :detail for this candidate."))))

(provide 'cc-butler-self-check)
;;; cc-butler-self-check.el ends here
