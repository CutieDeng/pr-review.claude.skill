#!/usr/bin/env racket
#lang racket/base

;; fetch-diff.rkt — 获取 PR/Commit diff 数据，输出到 stdout
;; Agent 通过 Bash 调用本脚本获取 diff，token 仅在脚本内部使用，不泄漏到 Agent 交互。
;;
;; 用法：
;;   racket fetch-diff.rkt --url https://github.com/foo/bar/pull/42
;;   racket fetch-diff.rkt --url https://gitcode.com/foo/bar/pull/1 --output comments
;;   racket fetch-diff.rkt --platform github --owner foo --repo bar --type pr --ref 42
;;
;; --output 模式：
;;   json      完整 JSON（默认，供程序消费）
;;   summary   人类可读的元数据摘要
;;   comments  已有评论列表（含 id/type/discussion_id）
;;   files     变更文件列表
;;   diff      原始 unified diff 文本
;;   patch-map 展开每个 patch hunk 的 old/new 行号映射

(require net/http-client
         net/url
         json
         "location-lib.rkt"
         racket/string
         racket/port
         racket/match
         racket/format
         racket/cmdline
         racket/system
         racket/file
         racket/promise)

;; ── auth（与 send-comment.rkt 一致）────────────────────────────────

(define current-token-env          (make-parameter "GITHUB_TOKEN"))
(define current-token-file         (make-parameter ".github.token"))
(define current-token-fallback-cmd (make-parameter "gh auth token 2>/dev/null"))

(define (read-token-file path)
  (and (file-exists? path)
       (let ([t (string-trim (file->string path))])
         (and (not (string=? t "")) t))))

(define (find-token-file name)
  (define home (or (getenv "HOME") (path->string (find-system-path 'home-dir))))
  (or (read-token-file (build-path (current-directory) name))
      (read-token-file (build-path home name))))

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

(define (configure-auth! plat)
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

(define current-token
  (delay
    (or (getenv (current-token-env))
        (find-token-file (current-token-file))
        (run-fallback-cmd (current-token-fallback-cmd))
        (begin
          (eprintf "Warning: No auth found (checked ~a, ~a, fallback cmd). Proceeding without token — public repos only, rate limits apply.\n"
                   (current-token-env) (current-token-file))
          #f))))

;; ── HTTP ─────────────────────────────────────────────────────────────

;; Current platform — set before API calls
(define current-platform (make-parameter 'github))

;; Auth via Authorization header for both platforms (aligned with gitcode_mcp_server)
(define (auth-headers token platform)
  (define base (list "Accept: application/json"
                     "User-Agent: pr-review-rkt"))
  (if (not token)
      base
      (case platform
        [(gitcode)
         (cons (format "Authorization: Bearer ~a" token) base)]
        [else
         (cons (format "Authorization: token ~a" token) base)])))

(define (api-get api-base path token)
  (define platform (current-platform))
  (define u (string->url (string-append api-base path)))
  (define host (url-host u))
  (define request-path (url->string (struct-copy url u [scheme #f] [host #f] [port #f])))
  (define-values (status _headers resp-port)
    (http-sendrecv host request-path
                   #:ssl? #t
                   #:method "GET"
                   #:headers (auth-headers token platform)))
  (define body (port->string resp-port))
  (close-input-port resp-port)
  (values (bytes->string/utf-8 status) body))

(define (api-get-raw api-base path token accept)
  (define platform (current-platform))
  (define u (string->url (string-append api-base path)))
  (define host (url-host u))
  (define request-path (url->string (struct-copy url u [scheme #f] [host #f] [port #f])))
  (define base (list (format "Accept: ~a" accept)
                     "User-Agent: pr-review-rkt"))
  (define headers
    (if (not token)
        base
        (case platform
          [(gitcode)
           (cons (format "Authorization: Bearer ~a" token) base)]
          [else
           (cons (format "Authorization: token ~a" token) base)])))
  (define-values (status _headers resp-port)
    (http-sendrecv host request-path
                   #:ssl? #t
                   #:method "GET"
                   #:headers headers))
  (define body (port->string resp-port))
  (close-input-port resp-port)
  (values (bytes->string/utf-8 status) body))

;; ── URL 解析 ─────────────────────────────────────────────────────────

;; parse-url returns 5 values: platform owner repo type ref
;; type ∈ {'pr 'commit 'compare 'repo}
;; ref:
;;   pr      → PR number string
;;   commit  → commit SHA
;;   compare → "<base>...<head>" string (URL-decoded preservation of slashes intentional;
;;             callers split on "..." to obtain base/head)
;;   repo    → #f
(define (parse-url url-str)
  (define u (string->url url-str))
  (define host (url-host u))
  (define parts
    (filter (lambda (s) (not (string=? s "")))
            (string-split (url->string (struct-copy url u [scheme #f] [host #f] [port #f] [query '()] [fragment #f])) "/")))
  (define platform
    (cond
      [(regexp-match? #rx"github\\.com" host) 'github]
      [(regexp-match? #rx"gitcode\\.com|atomgit\\.com" host) 'gitcode]
      [else 'github]))  ; assume GHE
  (match parts
    ;; /<owner>/<repo>/pull/<number>
    [(list owner repo "pull" num-str)
     (values platform owner repo 'pr num-str)]
    ;; /<owner>/<repo>/commit/<sha>
    [(list owner repo "commit" sha)
     (values platform owner repo 'commit sha)]
    ;; /<owner>/<repo>/compare/<base>...<head>  (slashes inside base/head not supported here;
    ;; GitHub compare URLs put the full triple-dot/double-dot expression in one path segment)
    [(list owner repo "compare" spec)
     (values platform owner repo 'compare spec)]
    ;; /<owner>/<repo>
    [(list owner repo)
     (values platform owner repo 'repo #f)]
    [_ (error 'parse-url "Cannot parse URL: ~a" url-str)]))

;; split "<base>...<head>" into (values base head); supports "..." (3-dot) and ".." (2-dot)
(define (split-compare-spec spec)
  (cond
    [(regexp-match #rx"^(.+)\\.\\.\\.(.+)$" spec)
     => (lambda (m) (values (cadr m) (caddr m)))]
    [(regexp-match #rx"^(.+)\\.\\.(.+)$" spec)
     => (lambda (m) (values (cadr m) (caddr m)))]
    [else (error 'split-compare-spec "Invalid compare spec: ~a (expected base...head)" spec)]))

;; ── API base per platform ────────────────────────────────────────────

(define (api-base-for platform)
  (case platform
    [(github) "https://api.github.com"]
    [(gitcode) "https://api.gitcode.com/api/v5"]
    [else (error 'api-base "Unknown platform: ~a" platform)]))

;; ── fetch logic ──────────────────────────────────────────────────────

(define (fetch-pr-data api-base owner repo ref token)
  ;; metadata
  (define-values (st1 meta-body)
    (api-get api-base (format "/repos/~a/~a/pulls/~a" owner repo ref) token))
  ;; diff
  (define-values (st2 diff-body)
    (api-get-raw api-base (format "/repos/~a/~a/pulls/~a" owner repo ref) token
                 "application/vnd.github.v3.diff"))
  ;; files
  (define-values (st3 files-body)
    (api-get api-base (format "/repos/~a/~a/pulls/~a/files" owner repo ref) token))
  ;; existing review comments (inline)
  (define-values (st4 review-comments-body)
    (api-get api-base (format "/repos/~a/~a/pulls/~a/comments" owner repo ref) token))
  ;; existing issue comments (conversation)
  (define-values (st5 issue-comments-body)
    (api-get api-base (format "/repos/~a/~a/issues/~a/comments" owner repo ref) token))
  (define result (make-hasheq))
  (hash-set! result 'type "pr")
  (hash-set! result 'meta (with-handlers ([exn:fail? (lambda (_) meta-body)])
                            (string->jsexpr meta-body)))
  (hash-set! result 'diff diff-body)
  (hash-set! result 'files (with-handlers ([exn:fail? (lambda (_) files-body)])
                             (string->jsexpr files-body)))
  (hash-set! result 'review-comments
             (with-handlers ([exn:fail? (lambda (_) '())])
               (string->jsexpr review-comments-body)))
  (hash-set! result 'issue-comments
             (with-handlers ([exn:fail? (lambda (_) '())])
               (string->jsexpr issue-comments-body)))
  result)

(define (fetch-commit-data api-base owner repo ref token)
  (define platform (current-platform))
  ;; metadata
  (define-values (st1 meta-body)
    (api-get api-base (format "/repos/~a/~a/commits/~a" owner repo ref) token))
  ;; existing comments on this commit
  (define-values (st-comments comments-body)
    (api-get api-base (format "/repos/~a/~a/commits/~a/comments" owner repo ref) token))
  ;; diff + files: platform-dependent
  (define-values (diff-text files-json)
    (case platform
      [(github)
       ;; GitHub: commit endpoint includes files; also fetch raw diff
       (define-values (st2 diff-body)
         (api-get-raw api-base (format "/repos/~a/~a/commits/~a" owner repo ref) token
                      "application/vnd.github.v3.diff"))
       (values diff-body #f)]  ; files already in meta
      [(gitcode)
       ;; GitCode v5: use compare endpoint for files + patches
       (define compare-path
           (string-append "/repos/" owner "/" repo "/compare/" ref "~1..." ref))
       (define-values (st2 compare-body)
         (api-get api-base compare-path token))
       (define compare-json
         (with-handlers ([exn:fail? (lambda (_) (hasheq))]) (string->jsexpr compare-body)))
       (define files (if (hash? compare-json) (hash-ref compare-json 'files '()) '()))
       ;; reconstruct unified diff from patches
       (define diff-lines
         (for/list ([f (in-list (if (list? files) files '()))]
                    #:when (hash? f))
           (format "diff --git a/~a b/~a\n~a"
                   (hash-ref f 'filename "")
                   (hash-ref f 'filename "")
                   (hash-ref f 'patch ""))))
       (values (string-join diff-lines "\n") files)]
      [else (values "" #f)]))
  (define result (make-hasheq))
  (hash-set! result 'type "commit")
  (hash-set! result 'meta (with-handlers ([exn:fail? (lambda (_) meta-body)])
                            (string->jsexpr meta-body)))
  (hash-set! result 'diff diff-text)
  (when files-json
    (hash-set! result 'files files-json))
  (hash-set! result 'comments
             (with-handlers ([exn:fail? (lambda (_) '())])
               (string->jsexpr comments-body)))
  result)

(define (fetch-compare-data api-base owner repo spec token)
  (define-values (base head) (split-compare-spec spec))
  ;; URL-encode each side; head may contain ":" (cross-fork); GitHub accepts it raw
  (define compare-path (format "/repos/~a/~a/compare/~a...~a" owner repo base head))
  (define-values (st1 cmp-body)
    (api-get api-base compare-path token))
  (define cmp-json
    (with-handlers ([exn:fail? (lambda (_) (hasheq))])
      (string->jsexpr cmp-body)))
  (define result (make-hasheq))
  (hash-set! result 'type "compare")
  (hash-set! result 'base base)
  (hash-set! result 'head head)
  (hash-set! result 'compare cmp-json)
  ;; surface files for `--output files` reuse
  (when (and (hash? cmp-json) (hash-has-key? cmp-json 'files))
    (hash-set! result 'files (hash-ref cmp-json 'files '())))
  result)

(define (fetch-repo-data api-base owner repo token)
  ;; minimal repo metadata, mainly to verify repo exists and to fetch default branch
  (define-values (st body)
    (api-get api-base (format "/repos/~a/~a" owner repo) token))
  (define meta
    (with-handlers ([exn:fail? (lambda (_) (hasheq))])
      (string->jsexpr body)))
  (define result (make-hasheq))
  (hash-set! result 'type "repo")
  (hash-set! result 'meta meta)
  result)

;; ── output formatters ────────────────────────────────────────────────

(require racket/list)

;; safe hash-ref with nested path
(define (jref h . keys)
  (for/fold ([v h]) ([k (in-list keys)])
    (if (hash? v) (hash-ref v k #f) #f)))

(define (truncate s n)
  (if (> (string-length s) n)
      (string-append (substring s 0 n) "...")
      s))

(define (print-summary result)
  (define meta (hash-ref result 'meta (hasheq)))
  (define type (hash-ref result 'type "?"))
  (printf "Type: ~a\n" type)
  (printf "Platform: ~a\n" (current-platform))
  (case (string->symbol type)
    [(pr)
     (printf "Title: ~a\n" (jref meta 'title))
     (printf "Author: ~a\n" (jref meta 'user 'login))
     (printf "State: ~a\n" (jref meta 'state))
     (define body (or (jref meta 'body) ""))
     (unless (string=? body "")
       (printf "Body: ~a\n" (truncate body 200)))]
    [(commit)
     (printf "SHA: ~a\n" (jref meta 'sha))
     (printf "Message: ~a\n" (jref meta 'commit 'message))
     (printf "Author: ~a\n" (jref meta 'commit 'author 'name))]
    [(compare)
     (printf "Base: ~a\n" (hash-ref result 'base "?"))
     (printf "Head: ~a\n" (hash-ref result 'head "?"))
     (define cmp (hash-ref result 'compare (hasheq)))
     (when (hash? cmp)
       (printf "Status: ~a\n" (hash-ref cmp 'status "?"))
       (printf "Ahead/Behind: ~a/~a\n"
               (hash-ref cmp 'ahead_by "?")
               (hash-ref cmp 'behind_by "?"))
       (define commits (hash-ref cmp 'commits '()))
       (when (list? commits) (printf "Commits: ~a\n" (length commits))))]
    [(repo)
     (printf "Default branch: ~a\n" (or (jref meta 'default_branch) "?"))
     (printf "Description: ~a\n" (truncate (or (jref meta 'description) "") 200))])
  ;; count comments
  (define rc (hash-ref result 'review-comments '()))
  (define ic (hash-ref result 'issue-comments '()))
  (define cc (hash-ref result 'comments '()))
  (when (list? rc) (printf "Review comments: ~a\n" (length rc)))
  (when (list? ic) (printf "Issue comments: ~a\n" (length ic)))
  (when (and (list? cc) (not (null? cc))) (printf "Commit comments: ~a\n" (length cc)))
  ;; file count
  (define files (or (hash-ref result 'files #f)
                    (jref meta 'files)))
  (when (list? files) (printf "Files changed: ~a\n" (length files))))

(define (print-comments result)
  ;; collect all comment sources
  (define rc (let ([v (hash-ref result 'review-comments '())])
               (if (list? v) v '())))
  (define ic (let ([v (hash-ref result 'issue-comments '())])
               (if (list? v) v '())))
  (define cc (let ([v (hash-ref result 'comments '())])
               (if (list? v) v '())))
  (define (print-one label c idx)
    (cond
      [(hash? c)
       (define user (or (jref c 'user 'login) "?"))
       (define body (or (hash-ref c 'body #f) ""))
       (define cid (hash-ref c 'id #f))
       (define ctype (hash-ref c 'comment_type #f))
       (define did (hash-ref c 'discussion_id #f))
       (define path (hash-ref c 'path #f))
       (define line (or (hash-ref c 'line #f) (hash-ref c 'position #f)))
       (printf "\n[~a #~a] by ~a" label idx user)
       (when cid (printf " (id=~a)" cid))
       (when ctype (printf " type=~a" ctype))
       (when did (printf " discussion=~a" did))
       (newline)
       (when (and path line) (printf "  ~a:~a\n" path line))
       (when (and path (not line)) (printf "  ~a\n" path))
       (printf "  ~a\n" (truncate body 500))]
      [else (void)]))  ; skip non-hash entries (error responses)
  (unless (null? rc)
    (printf "── Review Comments (~a) ──\n" (length rc))
    (for ([c (in-list rc)] [i (in-naturals 1)])
      (print-one "RC" c i)))
  (unless (null? ic)
    (printf "\n── Issue Comments (~a) ──\n" (length ic))
    (for ([c (in-list ic)] [i (in-naturals 1)])
      (print-one "IC" c i)))
  (unless (null? cc)
    (printf "\n── Commit Comments (~a) ──\n" (length cc))
    (for ([c (in-list cc)] [i (in-naturals 1)])
      (print-one "CC" c i))))

(define (print-files result)
  (define files (or (hash-ref result 'files #f)
                    (let ([m (hash-ref result 'meta (hasheq))])
                      (if (hash? m) (hash-ref m 'files #f) #f))))
  (cond
    [(list? files)
     (for ([f (in-list files)])
       (when (hash? f)
         (define name (or (hash-ref f 'filename #f) (hash-ref f 'name #f) "?"))
         (define status (hash-ref f 'status #f))
         (define adds (hash-ref f 'additions #f))
         (define dels (hash-ref f 'deletions #f))
         (printf "~a" name)
         (when status (printf " [~a]" status))
         (when (and adds dels) (printf " +~a/-~a" adds dels))
         (newline)))]
    [else (displayln "No file data available.")]))

(define (print-diff result)
  (define diff (hash-ref result 'diff ""))
  (display diff)
  (unless (string=? diff "") (newline)))

(define (print-patch-map result)
  (printf "path\tpatch-index\tkind\told-line\tnew-line\ttext\n")
  (for ([e (in-list (files->patch-map result))])
    (define j (patch-entry->jsexpr e))
    (printf "~a\t~a\t~a\t~a\t~a\t~a\n"
            (hash-ref j 'path)
            (hash-ref j 'patch_index)
            (hash-ref j 'kind)
            (hash-ref j 'old_line)
            (hash-ref j 'new_line)
            (hash-ref j 'text))))

;; ── main ─────────────────────────────────────────────────────────────

(define opt-platform  (make-parameter #f))
(define opt-owner     (make-parameter #f))
(define opt-repo      (make-parameter #f))
(define opt-type      (make-parameter #f))   ; "pr" or "commit"
(define opt-ref       (make-parameter #f))   ; pr number or commit sha
(define opt-url       (make-parameter #f))
(define opt-output    (make-parameter "json")) ; json | summary | comments | files | diff | patch-map

(command-line
 #:program "fetch-diff"
 #:once-each
 ["--platform" p "Platform: github or gitcode" (opt-platform (string->symbol p))]
 ["--owner" o "Repository owner" (opt-owner o)]
 ["--repo" r "Repository name" (opt-repo r)]
 ["--type" t "Review type: pr or commit" (opt-type t)]
 ["--ref" ref "PR number or commit SHA" (opt-ref ref)]
 ["--url" u "Full PR/commit URL (auto-parses all fields)" (opt-url u)]
 ["--output" o "Output mode: json|summary|comments|files|diff|patch-map (default: json)" (opt-output o)]
 #:args () (void))

;; resolve from URL if provided
(when (opt-url)
  (define-values (plat owner repo type ref) (parse-url (opt-url)))
  (opt-platform plat)
  (opt-owner owner)
  (opt-repo repo)
  (opt-type (~a type))
  (opt-ref ref))

;; validate
(unless (and (opt-platform) (opt-owner) (opt-repo) (opt-type))
  (error 'fetch-diff "Missing required arguments. Use --url or provide --platform --owner --repo --type [--ref]"))
;; --ref required except for type=repo
(when (and (not (string=? (opt-type) "repo")) (not (opt-ref)))
  (error 'fetch-diff "--ref is required for type=~a" (opt-type)))

(configure-auth! (opt-platform))
(current-platform (opt-platform))
(define token (force current-token))
(define api-base (api-base-for (opt-platform)))

(define result
  (case (string->symbol (opt-type))
    [(pr)      (fetch-pr-data api-base (opt-owner) (opt-repo) (opt-ref) token)]
    [(commit)  (fetch-commit-data api-base (opt-owner) (opt-repo) (opt-ref) token)]
    [(compare) (fetch-compare-data api-base (opt-owner) (opt-repo) (opt-ref) token)]
    [(repo)    (fetch-repo-data api-base (opt-owner) (opt-repo) token)]
    [else      (error 'fetch-diff "Unknown type: ~a" (opt-type))]))

(case (string->symbol (opt-output))
  [(json)     (write-json result) (newline)]
  [(summary)  (print-summary result)]
  [(comments) (print-comments result)]
  [(files)    (print-files result)]
  [(diff)     (print-diff result)]
  [(patch-map) (print-patch-map result)]
  [else       (error 'fetch-diff "Unknown output mode: ~a. Use json|summary|comments|files|diff|patch-map" (opt-output))])
