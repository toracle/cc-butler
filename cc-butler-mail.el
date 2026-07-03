;;; cc-butler-mail.el --- Minimal durable inter-agent message channel  -*- lexical-binding: t; -*-

;; A small, reliable message bus for cc-butler agents — the first iteration
;; toward the full maildir design, built test-first.  It fixes two channel bugs:
;;
;;   1. down-direction input-box collision — a message to a worker was typed
;;      into its terminal, colliding with the human.  Here the *content* travels
;;      in a file inbox; only a minimal *poke* (a fixed signal, never the body)
;;      wakes an idle agent.
;;   2. no return path — the butler's question to a worker never came back.  A
;;      query carries a `reply-to', and the reply is delivered to the asker's
;;      inbox via an opaque `reply_handle' (request/response correlation).
;;
;; Ports & adapters: the transport is behind a `cc-butler-channel' interface
;; (deliver / drain / poke).  The routing logic (return-path, default-to-steward,
;; never-poke-butler) is written against that interface, so it is contract-tested
;; with an in-memory MOCK channel (see cc-butler-mail-test.el) and then run
;; unchanged over the real file/session adapter.
;;
;; Backward compatible: `send_to_session' (terminal typing) is untouched; this
;; channel is added in parallel, to be verified end-to-end before anything
;; migrates onto it.

(require 'cc-butler-session)
(require 'cc-butler-orchestrator)
(require 'cl-lib)
(require 'subr-x)

(defcustom cc-butler-mail-dir
  (expand-file-name "cc-butler/mail/"
                    (or (getenv "XDG_STATE_HOME")
                        (expand-file-name ".local/state" "~")))
  "Root of the cc-butler inter-agent message bus.
A durable directory independent of the sessions' `~/.claude' context."
  :type 'directory
  :group 'cc-butler)

(defconst cc-butler-mail--poke-signal
  "[cc-butler] New inbox message — run check_inbox, then reply_message to answer."
  "The wake text a poke types: a signal only, never the message body.")

(defvar cc-butler--mail-counter 0
  "Per-process counter making message ids unique within a second.")

(defun cc-butler--mail-id ()
  "Return a unique, chronologically sortable message id."
  (format "%s-%d-%04d"
          (format-time-string "%Y%m%dT%H%M%S")
          (emacs-pid)
          (setq cc-butler--mail-counter (1+ cc-butler--mail-counter))))

;;;; ------------------------------------------------------------------
;;;; Port: a channel is three operations
;;;; ------------------------------------------------------------------

(cl-defstruct (cc-butler-channel (:constructor cc-butler-make-channel))
  deliver   ; (TO-AGENT MSG) -> id     put MSG in agent TO's inbox
  drain     ; (AGENT) -> list of msgs  take + clear AGENT's pending messages
  poke)     ; (AGENT) -> nil           wake AGENT (signal only, no body)

(defvar cc-butler--channel nil
  "Active `cc-butler-channel'; nil means the real file/session adapter.
Bind to a mock channel to contract-test the routing in isolation.")

(defun cc-butler--channel ()
  "Return the active channel (the file adapter by default)."
  (or cc-butler--channel (cc-butler--file-channel)))

(defun cc-butler--ch-deliver (to msg) (funcall (cc-butler-channel-deliver (cc-butler--channel)) to msg))
(defun cc-butler--ch-drain (agent)    (funcall (cc-butler-channel-drain   (cc-butler--channel)) agent))
(defun cc-butler--ch-poke (agent)     (funcall (cc-butler-channel-poke    (cc-butler--channel)) agent))

;;;; ------------------------------------------------------------------
;;;; File adapter (lock-free maildir delivery + session poke)
;;;; ------------------------------------------------------------------

(defun cc-butler--mail-slug (s)
  (replace-regexp-in-string "[^A-Za-z0-9_.-]" "_" (or s "unknown")))

(defun cc-butler--mail-inbox (agent)
  (file-name-as-directory
   (expand-file-name (cc-butler--mail-slug agent)
                     (file-name-as-directory (expand-file-name cc-butler-mail-dir)))))

(defun cc-butler--mail-ensure (agent)
  (let ((in (cc-butler--mail-inbox agent)))
    (dolist (sub '("tmp/" "new/" "archive/"))
      (make-directory (expand-file-name sub in) t))
    in))

(defun cc-butler--mail-file-deliver (to msg)
  "Atomically deliver MSG to agent TO's inbox (write tmp, rename into new)."
  (cc-butler--mail-ensure to)
  (let* ((id (or (plist-get msg :id) (cc-butler--mail-id)))
         (msg (plist-put (plist-put msg :id id)
                         :time (or (plist-get msg :time) (current-time))))
         (in (cc-butler--mail-inbox to))
         (fname (format "%s.eld" id))
         (tmp (expand-file-name (concat "tmp/" fname) in))
         (new (expand-file-name (concat "new/" fname) in)))
    (with-temp-file tmp
      (let ((print-length nil) (print-level nil))
        (prin1 msg (current-buffer)) (insert "\n")))
    (rename-file tmp new t)            ; atomic within the filesystem
    id))

(defun cc-butler--mail-file-drain (agent)
  "Drain AGENT's new/ (oldest first), archiving each; ignore half-written tmp/."
  (cc-butler--mail-ensure agent)
  (let* ((in (cc-butler--mail-inbox agent))
         (newdir (expand-file-name "new/" in))
         (files (sort (directory-files newdir t "\\.eld\\'") #'string<))
         msgs)
    (dolist (f files)
      (let ((msg (ignore-errors
                   (with-temp-buffer (insert-file-contents f) (read (current-buffer))))))
        (when msg (push msg msgs))
        (ignore-errors
          (rename-file f (expand-file-name
                          (concat "archive/" (file-name-nondirectory f)) in) t))))
    (nreverse msgs)))

(defun cc-butler--mail-file-poke (agent)
  "Type the fixed wake signal into AGENT's terminal (content stays in the inbox)."
  (when-let* ((dir (cc-butler--dir-by-name agent))
              (b (get-buffer (claude-code-ide--get-buffer-name dir)))
              ((buffer-live-p b)))
    (ignore-errors (cc-butler--send-input dir cc-butler-mail--poke-signal t))))

(defun cc-butler--file-channel ()
  (cc-butler-make-channel
   :deliver #'cc-butler--mail-file-deliver
   :drain   #'cc-butler--mail-file-drain
   :poke    #'cc-butler--mail-file-poke))

;;;; ------------------------------------------------------------------
;;;; Routing (against the channel port — the contract-tested logic)
;;;; ------------------------------------------------------------------

(defun cc-butler--mail-butler-agent ()
  "Agent id of the user-facing butler (never poked)."
  (and cc-butler--butler (cc-butler--display-name cc-butler--butler)))

(defun cc-butler--mail-reply-handle (msg)
  "Opaque handle a recipient passes to `reply_message' to answer MSG."
  (format "%s#%s" (plist-get msg :reply-to) (plist-get msg :id)))

(defun cc-butler--route-ask (from to question)
  "FROM asks agent TO a QUESTION; the reply returns to FROM.  Return the id."
  (prog1 (cc-butler--ch-deliver
          to (list :kind 'ask :from from :reply-to from :body question))
    (cc-butler--ch-poke to)))

(defun cc-butler--route-reply (from reply-handle body)
  "FROM answers a query via REPLY-HANDLE; delivered to the asker (return path).
The asker is poked unless it is the butler (whose input box stays clean).
Return the recipient agent."
  (unless (and reply-handle (string-match "\\`\\(.+\\)#\\([^#]+\\)\\'" reply-handle))
    (error "Invalid reply_handle %S" reply-handle))
  (let ((to (match-string 1 reply-handle))
        (id (match-string 2 reply-handle)))
    (cc-butler--ch-deliver to (list :kind 'reply :from from :in-reply-to id :body body))
    (unless (equal to (cc-butler--mail-butler-agent))
      (cc-butler--ch-poke to))
    to))

(defun cc-butler--route-report (from body ops-agent)
  "A worker's routine report from FROM routes to OPS-AGENT (the steward)."
  (prog1 (cc-butler--ch-deliver ops-agent (list :kind 'report :from from :body body))
    (cc-butler--ch-poke ops-agent)))

;;;; ------------------------------------------------------------------
;;;; Up-direction transport (B): report / escalate / drain over the channel
;;;; ------------------------------------------------------------------
;;
;; These back the existing report_to_butler / escalate_to_butler /
;; pending_events / pending_decisions tools when `cc-butler-message-transport'
;; is `maildir': the message is delivered to the recipient's durable file
;; inbox, and draining archives it (the audit trail).  No poke — up-direction
;; is pull-only, so nothing is typed into any terminal.

(defun cc-butler-mail-up-report (from-dir body)
  "Deliver a worker report (BODY, from session FROM-DIR) to the ops inbox."
  (cc-butler--ch-deliver
   (cc-butler--display-name (cc-butler--ops-dir))
   (list :kind 'report
         :from (and from-dir (cc-butler--display-name from-dir))
         :body body)))

(defun cc-butler-mail-up-decision (from-dir summary needs)
  "Deliver a decision (SUMMARY/NEEDS, from FROM-DIR) to the butler inbox."
  (cc-butler--ch-deliver
   (cc-butler--mail-butler-agent)
   (list :kind 'decision
         :from (and from-dir (cc-butler--display-name from-dir))
         :summary summary :needs needs)))

(defun cc-butler-mail-up-drain (agent-dir)
  "Drain AGENT-DIR's own durable inbox (archives each; returns the messages)."
  (and agent-dir (cc-butler--ch-drain (cc-butler--display-name agent-dir))))

;;;; ------------------------------------------------------------------
;;;; MCP tools (resolve session -> agent id, then route)
;;;; ------------------------------------------------------------------

(defun cc-butler--mail-self ()
  "Agent id of the calling session (its display name), or nil."
  (when-let ((dir (cc-butler--caller-dir)))
    (cc-butler--display-name dir)))

(defun cc-butler-tool-ask-worker (name question)
  "MCP tool: ask session NAME a QUESTION; the reply returns to YOUR inbox."
  (let ((self (cc-butler--mail-self)))
    (unless self (error "No calling session context for this request"))
    (unless (and question (not (string-empty-p (string-trim question))))
      (error "A question is required"))
    (unless (cc-butler--dir-by-name name)
      (error "No live session named %S.  Use list_claude_sessions for names." name))
    (let ((id (cc-butler--route-ask self name (string-trim question))))
      (format "Asked %s (id %s).  The reply will arrive in YOUR inbox — call check_inbox to read it."
              name id))))

(defun cc-butler-tool-check-inbox ()
  "MCP tool: drain YOUR inbox (queries, replies, notes)."
  (let ((self (cc-butler--mail-self)))
    (unless self (error "No calling session context for this request"))
    (let ((msgs (cc-butler--ch-drain self)))
      (if (null msgs)
          "No new inbox messages."
        (mapconcat
         (lambda (m)
           (let ((kind (plist-get m :kind)))
             (concat
              (format "- from %s" (plist-get m :from))
              (pcase kind
                ('ask (format " asks (reply with reply_message reply_handle=\"%s\")"
                              (cc-butler--mail-reply-handle m)))
                ('reply (if (plist-get m :in-reply-to)
                            (format " replied to your query %s" (plist-get m :in-reply-to))
                          " replied"))
                (_ (format " (%s)" kind)))
              "\n    " (string-trim (or (plist-get m :body) "")))))
         msgs "\n")))))

(defun cc-butler-tool-reply-message (reply_handle body)
  "MCP tool: answer a query using its REPLY_HANDLE from check_inbox."
  (let ((self (cc-butler--mail-self)))
    (unless self (error "No calling session context for this request"))
    (unless (and body (not (string-empty-p (string-trim body))))
      (error "A reply body is required"))
    (let ((to (cc-butler--route-reply self (string-trim (or reply_handle ""))
                                      (string-trim body))))
      (format "Replied to %s." to))))

;; Idempotent (re)registration.
(setq claude-code-ide-mcp-server-tools
      (seq-remove
       (lambda (spec)
         (member (plist-get (claude-code-ide--normalize-tool-spec spec) :name)
                 '("ask_worker" "check_inbox" "reply_message")))
       claude-code-ide-mcp-server-tools))

(claude-code-ide-make-tool
 :function #'cc-butler-tool-ask-worker
 :name "ask_worker"
 :description "Ask another session (a worker) a question over the cc-butler channel so the answer RETURNS TO YOUR INBOX automatically (unlike send_to_session, whose reply you would have to poll for). The worker is poked to read its inbox; when it answers with reply_message the reply lands in your inbox — call check_inbox to read it."
 :args '((:name "name" :type string
                :description "Target session name from list_claude_sessions.")
         (:name "question" :type string
                :description "What you are asking the worker.")))

(claude-code-ide-make-tool
 :function #'cc-butler-tool-check-inbox
 :name "check_inbox"
 :description "Drain YOUR cc-butler inbox: messages other sessions sent you — questions (each with a reply_handle to answer via reply_message), replies to questions you asked, and notes. Call it at the start of a turn and whenever you are poked. Returns and clears them (archived for the audit trail)."
 :args nil)

(claude-code-ide-make-tool
 :function #'cc-butler-tool-reply-message
 :name "reply_message"
 :description "Answer a question from your inbox. Pass the reply_handle exactly as check_inbox gave it, and your answer as body; it is delivered to the asker's inbox (the query's return path)."
 :args '((:name "reply_handle" :type string
                :description "The reply_handle from check_inbox for the question you are answering.")
         (:name "body" :type string
                :description "Your answer.")))

(provide 'cc-butler-mail)
;;; cc-butler-mail.el ends here
