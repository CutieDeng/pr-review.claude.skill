#!/usr/bin/env racket
#lang racket/base

(require net/http-client
         net/url
         json
         racket/string
         racket/port
         racket/match
         racket/list
         racket/format
         racket/cmdline
         racket/system
         racket/file
         racket/promise)

;; ── helpers ──────────────────────────────────────────────────────────

(define (read-all path)
  (call-with-input-file path
    (lambda (in)
      (let loop ()
        (define v (read in))
        (if (eof-object? v) '() (cons v (loop)))))))

(define (get key alist)
  (cdr (assoc key alist)))

(define (get* key alist [default #f])
  (define p (assoc key alist))
  (if p (cdr p) default))

(define (section=? name rec)
  (equal? (get* 'section rec) name))

;; ── auth ─────────────────────────────────────────────────────────────

;; Parameters — set once after platform is known; library callers can override before force
(define current-token-env          (make-parameter "GITHUB_TOKEN"))
(define current-token-file         (make-parameter ".github.token"))
(define current-token-fallback-cmd (make-parameter "gh auth token 2>/dev/null"))  ; #f = no fallback

;; Read a token file if it exists; return #f otherwise.
(define (read-token-file path)
  (and (file-exists? path)
       (let ([t (string-trim (file->string path))])
         (and (not (string=? t "")) t))))

;; Search: project-local first, then home dir
(define (find-token-file name)
  (define home (or (getenv "HOME") (path->string (find-system-path 'home-dir))))
  (or (read-token-file (build-path (current-directory) name))
      (read-token-file (build-path home name))))

;; Run fallback command, return token string or #f
(define (run-fallback-cmd cmd)
  (and cmd
       (let ([out (open-output-string)]
             [err (open-output-string)])
         (define ok?
           (parameterize ([current-output-port out]
                          [current-error-port err])
             (system cmd)))
         (and ok?
              (let ([t (string-trim (get-output-string out))])
                (and (not (string=? t "")) t))))))

;; Configure parameters by platform — call early, before current-token is forced
(define (configure-auth-for-platform! plat)
  (case plat
    [(github)
     (current-token-env "GITHUB_TOKEN")
     (current-token-file ".github.token")
     (current-token-fallback-cmd "gh auth token 2>/dev/null")]
    [(gitcode)
     (current-token-env "GITCODE_TOKEN")
     (current-token-file ".gitcode.token")
     (current-token-fallback-cmd #f)]
    [else (error 'configure-auth "Unknown platform: ~a" plat)]))

;; Lazy token — resolved once on first (force current-token)
;; Reads current parameter values at force time, not at define time
(define current-token
  (delay
    (or (getenv (current-token-env))
        (find-token-file (current-token-file))
        (run-fallback-cmd (current-token-fallback-cmd))
        (error 'current-token
               "No auth found. Set ~a, create ~a, or configure fallback."
               (current-token-env) (current-token-file)))))

;; ── API ──────────────────────────────────────────────────────────────

(define (api-base-for-platform plat)
  (case plat
    [(github) "https://api.github.com"]
    [(gitcode) "https://api.gitcode.com/api/v5"]
    [else (error 'api-base "Unknown platform: ~a" plat)]))

(define (api-call method path body-jsexpr token plat)
  (define api-base (api-base-for-platform plat))
  (define u (string->url (string-append api-base path)))
  (define host (url-host u))
  (define raw-path (url->string (struct-copy url u [scheme #f] [host #f] [port #f])))
  ;; Both platforms: token via Authorization header
  (define request-path raw-path)
  (define headers
    (case plat
      [(gitcode)
       (list (format "Authorization: Bearer ~a" token)
             "Accept: application/json"
             "Content-Type: application/json"
             "User-Agent: pr-review-rkt")]
      [else
       (list (format "Authorization: token ~a" token)
             "Accept: application/vnd.github.v3+json"
             "Content-Type: application/json"
             "User-Agent: pr-review-rkt")]))
  (define body-bytes
    (if body-jsexpr
        (jsexpr->string body-jsexpr)
        #f))
  (define-values (status resp-headers resp-port)
    (http-sendrecv host request-path
                   #:ssl? #t
                   #:method method
                   #:headers headers
                   #:data (or body-bytes #"")))
  (define resp-body (port->string resp-port))
  (close-input-port resp-port)
  (values (bytes->string/utf-8 status) resp-body))

;; ── color output ─────────────────────────────────────────────────────

(define (color code text)
  (format "\033[~am~a\033[0m" code text))

(define (severity-color sev)
  (match sev
    ['critical (color 31 "CRITICAL")]    ; red
    ['warning  (color 33 "WARNING")]     ; yellow
    ['suggestion (color 36 "SUGGEST")]   ; cyan
    ['nitpick (color 90 "NITPICK")]      ; gray
    [_ (~a sev)]))

;; ── display ──────────────────────────────────────────────────────────

(define (display-comment c idx total)
  (printf "\n~a [~a/~a] ~a:~a\n"
          (severity-color (get* 'severity c 'unknown))
          idx total
          (get 'path c) (get 'line c))
  (printf "  Category: ~a\n" (get* 'category c "—"))
  (printf "  ~a\n" (get 'body c))
  (when (get* 'rule-ref c)
    (printf "  Rule: ~a\n" (get* 'rule-ref c))))

(define (prompt-action)
  (display "\n  [s]end  [S]kip  [e]dit  [q]uit > ")
  (flush-output)
  (define line (read-line))
  (cond
    [(eof-object? line) 'quit]
    [else
     (match (string-trim line)
       ["s" 'send]
       ["S" 'skip]
       ["e" 'edit]
       ["q" 'quit]
       [""  'send]   ; default = send
       [_   (displayln "  Invalid choice, try again.")
            (prompt-action)])]))

(define (prompt-edit c)
  (printf "  Current body:\n  ~a\n" (get 'body c))
  (display "  New body (enter to keep): ")
  (flush-output)
  (define line (read-line))
  (if (or (eof-object? line) (string=? (string-trim line) ""))
      c
      (map (lambda (pair)
             (if (eq? (car pair) 'body)
                 (cons 'body (string-trim line))
                 pair))
           c)))

;; ── build API payload ────────────────────────────────────────────────

(define (build-review-payload decision comments)
  (define body-text (get 'body decision))
  (define event (get 'event decision))
  (define api-comments
    (for/list ([c (in-list comments)])
      (define h (make-hasheq))
      (hash-set! h 'path (get 'path c))
      (hash-set! h 'line (get 'line c))
      (hash-set! h 'side (get* 'side c "RIGHT"))
      (hash-set! h 'body (get 'body c))
      h))
  (define payload (make-hasheq))
  (hash-set! payload 'body body-text)
  (hash-set! payload 'event event)
  (hash-set! payload 'comments api-comments)
  payload)

;; ── main ─────────────────────────────────────────────────────────────

(define dry-run? (make-parameter #f))
(define non-interactive? (make-parameter #f))
(define skip-nitpicks? (make-parameter #f))
(define comment-file (make-parameter "comment.rktd"))

(define remaining
  (command-line
   #:program "send-comment"
   #:once-each
   ["--dry-run" "Preview API calls without sending"
    (dry-run? #t)]
   ["--non-interactive" "Send all comments without confirmation"
    (non-interactive? #t)]
   ["--skip-nitpicks" "Skip nitpick-severity comments"
    (skip-nitpicks? #t)]
   ["--file" f "Path to comment.rktd (default: comment.rktd)"
    (comment-file f)]
   #:args rest
   rest))

;; read data
(unless (file-exists? (comment-file))
  (error 'send-comment "File not found: ~a" (comment-file)))

(define records (read-all (comment-file)))
(define meta (findf (lambda (r) (section=? 'meta r)) records))
(define decision (findf (lambda (r) (section=? 'decision r)) records))
(define all-comments
  (filter (lambda (r) (section=? 'inline-comment r)) records))
(define all-replies
  (filter (lambda (r) (section=? 'reply r)) records))
(define all-issues
  (filter (lambda (r) (section=? 'issue r)) records))
(define all-issue-updates
  (filter (lambda (r) (section=? 'issue-update r)) records))

(unless meta
  (error 'send-comment "No (section . meta) record found in ~a" (comment-file)))

(define platform (get 'platform meta))
(define review-type (get* 'review-type meta 'pr))  ; 'pr or 'commit
(define owner (get 'owner meta))
(define repo (get 'repo meta))
(define pr-number (get* 'pr-number meta #f))
(define commit-sha (get* 'commit-sha meta #f))

;; configure auth parameters for this platform; token resolved lazily
(configure-auth-for-platform! platform)

;; filter nitpicks if requested
(define comments
  (if (skip-nitpicks?)
      (filter (lambda (c) (not (eq? (get* 'severity c) 'nitpick))) all-comments)
      all-comments))

(define target-label
  (case review-type
    [(pr)     (format "~a/~a#~a" owner repo pr-number)]
    [(commit) (format "~a/~a@~a" owner repo (substring (~a commit-sha) 0 (min 7 (string-length (~a commit-sha)))))]
    [(issue)  (format "~a/~a (new issues)" owner repo)]
    [else     (format "~a/~a" owner repo)]))

(printf "\n~a Review: ~a\n" (color 1 (string-upcase (~a review-type))) target-label)
(when decision
  (define evt (get* 'event decision #f))
  (when evt (printf "Decision: ~a\n" evt)))
(printf "Comments: ~a total (~a after filter), ~a replies, ~a issues, ~a issue-updates\n\n"
        (length all-comments) (length comments) (length all-replies)
        (length all-issues) (length all-issue-updates))

;; interactive: confirm decision first
(define send-decision?
  (cond
    [(not decision) #f]
    [(non-interactive?) #t]
    [else
     (printf "\n~a Summary:\n  ~a\n"
             (color 1 "Decision")
             (get 'body decision))
     (define action (prompt-action))
     (match action
       ['send #t]
       ['skip #f]
       ['edit
        (set! decision (prompt-edit decision))
        #t]
       ['quit
        (displayln "\nAborted. No comments sent.")
        (exit 0)])]))

;; interactive: filter inline comments
(define final-comments
  (cond
    [(non-interactive?) comments]
    [else
     (let loop ([cs comments] [idx 1] [acc '()])
       (if (null? cs)
           (reverse acc)
           (let ([c (car cs)])
             (display-comment c idx (length comments))
             (define action (prompt-action))
             (match action
               ['send (loop (cdr cs) (add1 idx) (cons c acc))]
               ['skip (loop (cdr cs) (add1 idx) acc)]
               ['edit (let ([edited (prompt-edit c)])
                        (loop (cdr cs) (add1 idx) (cons edited acc)))]
               ['quit (begin
                        (displayln "\nAborted. No comments sent.")
                        (exit 0))]))))]))

;; interactive: filter replies
(define (display-reply r idx total)
  (printf "\n~a [~a/~a] Reply to comment #~a\n"
          (color 35 "REPLY")   ; magenta
          idx total
          (get 'in-reply-to r))
  (printf "  ~a\n" (get 'body r)))

(define final-replies
  (cond
    [(null? all-replies) '()]
    [(non-interactive?) all-replies]
    [else
     (let loop ([rs all-replies] [idx 1] [acc '()])
       (if (null? rs)
           (reverse acc)
           (let ([r (car rs)])
             (display-reply r idx (length all-replies))
             (define action (prompt-action))
             (match action
               ['send (loop (cdr rs) (add1 idx) (cons r acc))]
               ['skip (loop (cdr rs) (add1 idx) acc)]
               ['edit (let ([edited (prompt-edit r)])
                        (loop (cdr rs) (add1 idx) (cons edited acc)))]
               ['quit (begin
                        (displayln "\nAborted. No comments sent.")
                        (exit 0))]))))]))

;; interactive: filter issues
(define (display-issue iss idx total)
  (printf "\n~a [~a/~a] ~a\n"
          (color 34 "ISSUE")   ; blue
          idx total
          (get 'title iss))
  (define labels (get* 'labels iss '()))
  (when (and (list? labels) (not (null? labels)))
    (printf "  Labels: ~a\n" (string-join (map ~a labels) ", ")))
  (define assignees (get* 'assignees iss '()))
  (when (and (list? assignees) (not (null? assignees)))
    (printf "  Assignees: ~a\n" (string-join (map ~a assignees) ", ")))
  (printf "  ~a\n" (get 'body iss)))

(define (prompt-edit-issue iss)
  (printf "  Current title: ~a\n" (get 'title iss))
  (display "  New title (enter to keep): ")
  (flush-output)
  (define title-line (read-line))
  (define iss2
    (if (or (eof-object? title-line) (string=? (string-trim title-line) ""))
        iss
        (map (lambda (pair)
               (if (eq? (car pair) 'title)
                   (cons 'title (string-trim title-line))
                   pair))
             iss)))
  (printf "  Current body:\n  ~a\n" (get 'body iss2))
  (display "  New body (enter to keep): ")
  (flush-output)
  (define body-line (read-line))
  (if (or (eof-object? body-line) (string=? (string-trim body-line) ""))
      iss2
      (map (lambda (pair)
             (if (eq? (car pair) 'body)
                 (cons 'body (string-trim body-line))
                 pair))
           iss2)))

(define final-issues
  (cond
    [(null? all-issues) '()]
    [(non-interactive?) all-issues]
    [else
     (let loop ([is all-issues] [idx 1] [acc '()])
       (if (null? is)
           (reverse acc)
           (let ([iss (car is)])
             (display-issue iss idx (length all-issues))
             (define action (prompt-action))
             (match action
               ['send (loop (cdr is) (add1 idx) (cons iss acc))]
               ['skip (loop (cdr is) (add1 idx) acc)]
               ['edit (let ([edited (prompt-edit-issue iss)])
                        (loop (cdr is) (add1 idx) (cons edited acc)))]
               ['quit (begin
                        (displayln "\nAborted. Nothing sent.")
                        (exit 0))]))))]))

;; interactive: filter issue-updates
(define (display-issue-update upd idx total)
  (define issue-num (get 'issue-number upd))
  (define state (get* 'state upd #f))
  (define state-reason (get* 'state-reason upd #f))
  (printf "\n~a [~a/~a] Issue #~a"
          (color 33 "UPDATE")   ; yellow
          idx total
          issue-num)
  (when state (printf " → ~a" state))
  (when state-reason (printf " (~a)" state-reason))
  (newline)
  (when (get* 'title upd #f)
    (printf "  New title: ~a\n" (get* 'title upd)))
  (when (get* 'body upd #f)
    (printf "  New body: ~a\n" (get* 'body upd))))

(define final-issue-updates
  (cond
    [(null? all-issue-updates) '()]
    [(non-interactive?) all-issue-updates]
    [else
     (let loop ([us all-issue-updates] [idx 1] [acc '()])
       (if (null? us)
           (reverse acc)
           (let ([u (car us)])
             (display-issue-update u idx (length all-issue-updates))
             (define action (prompt-action))
             (match action
               ['send (loop (cdr us) (add1 idx) (cons u acc))]
               ['skip (loop (cdr us) (add1 idx) acc)]
               ['edit (loop (cdr us) (add1 idx) (cons u acc))]  ; edit not meaningful for state changes
               ['quit (begin
                        (displayln "\nAborted. Nothing sent.")
                        (exit 0))]))))]))

(printf "\n~a: ~a comments + ~a replies + ~a issues + ~a updates to send~a\n"
        (color 1 "Final")
        (length final-comments)
        (length final-replies)
        (length final-issues)
        (length final-issue-updates)
        (if send-decision? " + summary" ""))

;; ── send: PR review (batch) ──────────────────────────────────────────

;; Build individual PR comment payload (for GitCode per-comment sending)
;; 支持 inline：body*(必填), path(文件名), position(diff 行偏移)
(define (build-pr-comment-payload c)
  (define h (make-hasheq))
  (hash-set! h 'body (get 'body c))
  (when (get* 'path c) (hash-set! h 'path (get* 'path c)))
  (when (get* 'position c) (hash-set! h 'position (get* 'position c)))
  h)

(define (send-pr-review! final-comments)
  (unless decision
    (error 'send-comment "PR review requires a (section . decision) record"))
  (case platform
    [(gitcode) (send-pr-review/individual! final-comments)]
    [else      (send-pr-review/batch! final-comments)]))

;; GitHub: batch via /reviews endpoint
(define (send-pr-review/batch! final-comments)
  (define payload (build-review-payload decision final-comments))
  (define api-path (format "/repos/~a/~a/pulls/~a/reviews" owner repo pr-number))
  (cond
    [(dry-run?)
     (displayln "\n--- DRY RUN ---")
     (printf "POST ~a\n" api-path)
     (displayln (jsexpr->string payload))
     (displayln "--- END DRY RUN ---")]
    [else
     (define token (force current-token))
     (printf "Sending review to ~a ...\n" api-path)
     (define-values (status resp-body)
       (api-call "POST" api-path payload token platform))
     (if (regexp-match? #rx"^HTTP/[0-9.]+ 200" status)
         (displayln (color 32 "Review submitted successfully!"))
         (begin (printf "~a: ~a\n" (color 31 "Error") status)
                (displayln resp-body)))]))

;; GitCode: /reviews 不可用，逐条通过 /comments 发送
(define (send-pr-review/individual! final-comments)
  (define comment-path (format "/repos/~a/~a/pulls/~a/comments" owner repo pr-number))
  (cond
    [(dry-run?)
     (displayln "\n--- DRY RUN ---")
     (when send-decision?
       (printf "POST ~a  [decision]\n" comment-path)
       (displayln (jsexpr->string (hasheq 'body (get 'body decision)))))
     (for ([c (in-list final-comments)] [i (in-naturals 1)])
       (printf "POST ~a  [inline ~a/~a]\n" comment-path i (length final-comments))
       (displayln (jsexpr->string (build-pr-comment-payload c))))
     (displayln "--- END DRY RUN ---")]
    [else
     (define token (force current-token))
     (when send-decision?
       (printf "Sending decision to ~a ...\n" comment-path)
       (define-values (status resp-body)
         (api-call "POST" comment-path (hasheq 'body (get 'body decision)) token platform))
       (if (regexp-match? #rx"^HTTP/[0-9.]+ 20[01]" status)
           (displayln (color 32 "Decision sent."))
           (begin (printf "~a: ~a\n" (color 31 "Error") status)
                  (displayln resp-body))))
     (for ([c (in-list final-comments)] [i (in-naturals 1)])
       (printf "Sending comment ~a/~a ...\n" i (length final-comments))
       (define-values (status resp-body)
         (api-call "POST" comment-path (build-pr-comment-payload c) token platform))
       (if (regexp-match? #rx"^HTTP/[0-9.]+ 20[01]" status)
           (printf "  ~a\n" (color 32 "OK"))
           (begin (printf "  ~a: ~a\n" (color 31 "Error") status)
                  (displayln resp-body))))]))

;; ── send: commit comments (individual) ──────────────────────────────

(define (build-commit-comment-payload c)
  (define h (make-hasheq))
  (define path (get* 'path c))
  (define line (get* 'line c))
  (define raw-body (get 'body c))
  ;; GitCode v5 commit comment API ignores path/position — embed in body text
  (define body
    (cond
      [(and (eq? platform 'gitcode) path line)
       (format "**`~a:~a`**\n\n~a" path line raw-body)]
      [(and (eq? platform 'gitcode) path)
       (format "**`~a`**\n\n~a" path raw-body)]
      [else raw-body]))
  (hash-set! h 'body body)
  ;; GitHub supports inline positioning
  (when (and (not (eq? platform 'gitcode)) path)
    (hash-set! h 'path path)
    (hash-set! h 'position line))
  h)

(define (send-commit-comments! final-comments)
  (define api-path (format "/repos/~a/~a/commits/~a/comments" owner repo commit-sha))
  (cond
    [(dry-run?)
     (displayln "\n--- DRY RUN ---")
     ;; general comment from decision body if confirmed
     (when send-decision?
       (printf "POST ~a\n" api-path)
       (displayln (jsexpr->string (hasheq 'body (get 'body decision)))))
     (for ([c (in-list final-comments)])
       (printf "POST ~a\n" api-path)
       (displayln (jsexpr->string (build-commit-comment-payload c))))
     (displayln "--- END DRY RUN ---")]
    [else
     (define token (force current-token))
     ;; general comment from decision body if confirmed
     (when send-decision?
       (printf "Sending summary comment ...\n")
       (define-values (st rb)
         (api-call "POST" api-path (hasheq 'body (get 'body decision)) token platform))
       (unless (regexp-match? #rx"^HTTP/[0-9.]+ 201" st)
         (printf "~a: ~a\n~a\n" (color 31 "Error") st rb)))
     ;; inline comments one by one
     (for ([c (in-list final-comments)]
           [i (in-naturals 1)])
       (printf "Sending [~a/~a] ~a:~a ...\n" i (length final-comments)
               (get* 'path c "—") (get* 'line c "—"))
       (define-values (st rb)
         (api-call "POST" api-path (build-commit-comment-payload c) token platform))
       (if (regexp-match? #rx"^HTTP/[0-9.]+ 201" st)
           (printf "  ~a\n" (color 32 "ok"))
           (printf "  ~a: ~a\n~a\n" (color 31 "Error") st rb)))
     (displayln (color 32 "Done."))]))

;; ── send: replies (both PR and commit) ──────────────────────────────

(define (send-replies! final-replies)
  (unless (null? final-replies)
    (define token (if (dry-run?) #f (force current-token)))
    (for ([r (in-list final-replies)]
          [i (in-naturals 1)])
      (define comment-id (get 'in-reply-to r))
      (define body (get 'body r))
      (define comment-type (get* 'comment-type r 'review-comment))
      ;; determine API path based on review-type and comment-type
      ;; GitCode uses discussion_id for PR comment replies;
      ;; GitHub uses in_reply_to on the PR comments endpoint
      (define discussion-id (get* 'discussion-id r #f))
      (define api-path
        (case review-type
          [(pr)
           (cond
             ;; GitCode: reply via discussions endpoint
             [(and (eq? platform 'gitcode) discussion-id)
              (format "/repos/~a/~a/pulls/~a/discussions/~a/comments"
                      owner repo pr-number discussion-id)]
             ;; GitHub: reply to review comment via in_reply_to
             [(eq? comment-type 'review-comment)
              (format "/repos/~a/~a/pulls/~a/comments" owner repo pr-number)]
             ;; issue comment (conversation)
             [(eq? comment-type 'issue-comment)
              (format "/repos/~a/~a/issues/~a/comments" owner repo pr-number)]
             [else
              (format "/repos/~a/~a/pulls/~a/comments" owner repo pr-number)])]
          [(commit)
           (format "/repos/~a/~a/commits/~a/comments" owner repo commit-sha)]
          [else (error 'send-replies "Unknown review-type: ~a" review-type)]))
      (define payload
        (cond
          ;; GitCode discussion reply: just body
          [(and (eq? platform 'gitcode) discussion-id)
           (hasheq 'body body)]
          ;; GitHub PR review comment reply: needs in_reply_to
          [(eq? comment-type 'review-comment)
           (hasheq 'body body 'in_reply_to comment-id)]
          [else
           ;; issue comment or commit comment: just body
           (hasheq 'body body)]))
      (cond
        [(dry-run?)
         (printf "POST ~a\n" api-path)
         (displayln (jsexpr->string payload))]
        [else
         (printf "Sending reply [~a/~a] to comment #~a ...\n"
                 i (length final-replies) comment-id)
         (define-values (st rb)
           (api-call "POST" api-path payload token platform))
         (if (regexp-match? #rx"^HTTP/[0-9.]+ 20[01]" st)
             (printf "  ~a\n" (color 32 "ok"))
             (printf "  ~a: ~a\n~a\n" (color 31 "Error") st rb))]))))

;; ── send: issues ────────────────────────────────────────────────────

(define (build-issue-payload iss)
  (define h (make-hasheq))
  (hash-set! h 'title (get 'title iss))
  (hash-set! h 'body (get 'body iss))
  (define labels (get* 'labels iss '()))
  (when (and (list? labels) (not (null? labels)))
    (hash-set! h 'labels (map ~a labels)))
  (define assignees (get* 'assignees iss '()))
  (when (and (list? assignees) (not (null? assignees)))
    (hash-set! h 'assignees (map ~a assignees)))
  (define milestone (get* 'milestone iss #f))
  (when milestone
    (hash-set! h 'milestone milestone))
  h)

(define (send-issues! issues)
  (unless (null? issues)
    (define api-path (format "/repos/~a/~a/issues" owner repo))
    (cond
      [(dry-run?)
       (displayln "\n--- DRY RUN (issues) ---")
       (for ([iss (in-list issues)] [i (in-naturals 1)])
         (printf "POST ~a  [issue ~a/~a] ~a\n" api-path i (length issues) (get 'title iss))
         (displayln (jsexpr->string (build-issue-payload iss))))
       (displayln "--- END DRY RUN (issues) ---")]
      [else
       (define token (force current-token))
       (for ([iss (in-list issues)] [i (in-naturals 1)])
         (printf "Creating issue [~a/~a] \"~a\" ...\n" i (length issues) (get 'title iss))
         (define-values (st rb)
           (api-call "POST" api-path (build-issue-payload iss) token platform))
         (if (regexp-match? #rx"^HTTP/[0-9.]+ 201" st)
             (let ([resp (string->jsexpr rb)])
               (printf "  ~a ~a\n"
                       (color 32 "Created:")
                       (hash-ref resp 'html_url (hash-ref resp 'url "ok"))))
             (printf "  ~a: ~a\n~a\n" (color 31 "Error") st rb)))])))

;; ── send: issue updates ──────────────────────────────────────────────

(define (build-issue-update-payload upd)
  (define h (make-hasheq))
  (define state (get* 'state upd #f))
  (when state (hash-set! h 'state (~a state)))
  (define state-reason (get* 'state-reason upd #f))
  (when state-reason (hash-set! h 'state_reason (~a state-reason)))
  (define title (get* 'title upd #f))
  (when title (hash-set! h 'title title))
  (define body (get* 'body upd #f))
  (when body (hash-set! h 'body body))
  (define labels (get* 'labels upd #f))
  (when (and labels (list? labels) (not (null? labels)))
    (hash-set! h 'labels (map ~a labels)))
  (define assignees (get* 'assignees upd #f))
  (when (and assignees (list? assignees))
    (hash-set! h 'assignees (map ~a assignees)))
  h)

(define (send-issue-updates! updates)
  (unless (null? updates)
    (cond
      [(dry-run?)
       (displayln "\n--- DRY RUN (issue-updates) ---")
       (for ([upd (in-list updates)] [i (in-naturals 1)])
         (define issue-num (get 'issue-number upd))
         (define api-path (format "/repos/~a/~a/issues/~a" owner repo issue-num))
         (printf "PATCH ~a  [update ~a/~a]\n" api-path i (length updates))
         (displayln (jsexpr->string (build-issue-update-payload upd))))
       (displayln "--- END DRY RUN (issue-updates) ---")]
      [else
       (define token (force current-token))
       (for ([upd (in-list updates)] [i (in-naturals 1)])
         (define issue-num (get 'issue-number upd))
         (define api-path (format "/repos/~a/~a/issues/~a" owner repo issue-num))
         (define state (get* 'state upd #f))
         (printf "Updating issue #~a [~a/~a]~a ...\n"
                 issue-num i (length updates)
                 (if state (format " → ~a" state) ""))
         (define-values (st rb)
           (api-call "PATCH" api-path (build-issue-update-payload upd) token platform))
         (if (regexp-match? #rx"^HTTP/[0-9.]+ 200" st)
             (let ([resp (string->jsexpr rb)])
               (printf "  ~a #~a (~a)\n"
                       (color 32 "Updated:")
                       (hash-ref resp 'number issue-num)
                       (hash-ref resp 'state "ok")))
             (printf "  ~a: ~a\n~a\n" (color 31 "Error") st rb)))])))

;; ── dispatch ────────────────────────────────────────────────────────

(when (dry-run?)
  (when (not (null? final-replies))
    (displayln "\n--- DRY RUN (replies) ---")))

;; only send review/comments if there are comments or a decision to send
(when (or (not (null? final-comments)) send-decision?)
  (case review-type
    [(pr)     (send-pr-review! final-comments)]
    [(commit) (send-commit-comments! final-comments)]
    [(issue)  (void)]  ; issue-only mode has no review comments
    [else     (error 'send-comment "Unknown review-type: ~a" review-type)]))

(send-replies! final-replies)
(send-issues! final-issues)
(send-issue-updates! final-issue-updates)

(when (dry-run?)
  (when (not (null? final-replies))
    (displayln "--- END DRY RUN (replies) ---")))
