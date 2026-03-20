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

;; ── GitHub API ───────────────────────────────────────────────────────

(define (github-api-call method path body-jsexpr token
                         #:api-base [api-base "https://api.github.com"])
  (define u (string->url (string-append api-base path)))
  (define host (url-host u))
  (define request-path (url->string (struct-copy url u [scheme #f] [host #f] [port #f])))
  (define headers
    (list (format "Authorization: token ~a" token)
          "Accept: application/vnd.github.v3+json"
          "Content-Type: application/json"
          "User-Agent: pr-review-rkt"))
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

(unless meta
  (error 'send-comment "No (section . meta) record found in ~a" (comment-file)))
(unless decision
  (error 'send-comment "No (section . decision) record found in ~a" (comment-file)))

(define platform (get 'platform meta))
(define owner (get 'owner meta))
(define repo (get 'repo meta))
(define pr-number (get 'pr-number meta))

;; configure auth parameters for this platform; token resolved lazily
(configure-auth-for-platform! platform)

;; filter nitpicks if requested
(define comments
  (if (skip-nitpicks?)
      (filter (lambda (c) (not (eq? (get* 'severity c) 'nitpick))) all-comments)
      all-comments))

(printf "\n~a Review: ~a/~a#~a\n" (color 1 "PR") owner repo pr-number)
(printf "Decision: ~a\n" (get 'event decision))
(printf "Comments: ~a total (~a after filter)\n\n"
        (length all-comments) (length comments))

;; interactive filtering
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

(printf "\n~a: ~a comments to send\n" (color 1 "Final") (length final-comments))

;; build payload
(define payload (build-review-payload decision final-comments))

(cond
  [(dry-run?)
   (displayln "\n--- DRY RUN ---")
   (printf "POST /repos/~a/~a/pulls/~a/reviews\n" owner repo pr-number)
   (displayln (jsexpr->string payload))
   (displayln "--- END DRY RUN ---")]
  [else
   (define token (force current-token))
   (define api-path (format "/repos/~a/~a/pulls/~a/reviews" owner repo pr-number))
   (printf "Sending review to ~a ...\n" api-path)
   (define-values (status resp-body)
     (github-api-call "POST" api-path payload token))
   (cond
     [(regexp-match? #rx"^HTTP/[0-9.]+ 200" status)
      (displayln (color 32 "Review submitted successfully!"))]
     [else
      (printf "~a: ~a\n" (color 31 "Error") status)
      (displayln resp-body)])])
