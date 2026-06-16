#lang racket/base

(provide read-rktd-records
         rec-get
         rec-get*
         section=?
         load-review-json
         files->patch-map
         find-file-entry
         find-line-location
         patch-entry->jsexpr
         validate-comment-records
         validation-ok?
         validation->jsexpr
         print-validation)

(require json
         racket/list
         racket/match
         racket/string)

(define (read-rktd-records path)
  (call-with-input-file path
    (lambda (in)
      (let loop ([acc '()])
        (define v (read in))
        (if (eof-object? v)
            (reverse acc)
            (loop (cons v acc)))))))

(define (rec-get key alist)
  (cdr (assoc key alist)))

(define (rec-get* key alist [default #f])
  (define p (assoc key alist))
  (if p (cdr p) default))

(define (section=? name rec)
  (equal? (rec-get* 'section rec) name))

(define (load-review-json path)
  (call-with-input-file path read-json))

(struct patch-entry (path patch-index kind old-line new-line text raw)
  #:transparent)

(define (patch-entry->jsexpr e)
  (hasheq 'path (patch-entry-path e)
          'patch_index (patch-entry-patch-index e)
          'kind (symbol->string (patch-entry-kind e))
          'old_line (or (patch-entry-old-line e) 'null)
          'new_line (or (patch-entry-new-line e) 'null)
          'text (patch-entry-text e)
          'raw (patch-entry-raw e)))

(define (hash-ref* h k [default #f])
  (if (hash? h) (hash-ref h k default) default))

(define (file-name f)
  (or (hash-ref* f 'filename #f)
      (hash-ref* f 'new_path #f)
      (hash-ref* f 'path #f)
      (hash-ref* f 'name #f)
      "?"))

(define (file-diff f)
  (define patch (hash-ref* f 'patch #f))
  (cond
    [(string? patch) patch]
    [(hash? patch) (or (hash-ref* patch 'diff #f)
                       (hash-ref* patch 'patch #f)
                       "")]
    [(string? (hash-ref* f 'diff #f)) (hash-ref f 'diff)]
    [else ""]))

(define hunk-re
  #px"^@@ -(\\d+)(?:,(\\d+))? \\+(\\d+)(?:,(\\d+))? @@")

(define (parse-patch path diff-text)
  (define entries '())
  (define old-line #f)
  (define new-line #f)
  (define patch-index 0)
  (for ([line (in-list (string-split diff-text "\n" #:trim? #f))])
    (define m (regexp-match hunk-re line))
    (cond
      [m
       (set! old-line (string->number (list-ref m 1)))
       (set! new-line (string->number (list-ref m 3)))]
      [(and old-line new-line
            (not (string-prefix? line "\\ No newline")))
       (set! patch-index (add1 patch-index))
       (define prefix (if (zero? (string-length line)) #\space (string-ref line 0)))
       (define raw-text
         (if (zero? (string-length line)) "" (substring line 1)))
       (cond
         [(char=? prefix #\+)
          (set! entries
                (cons (patch-entry path patch-index 'added #f new-line raw-text line)
                      entries))
          (set! new-line (add1 new-line))]
         [(char=? prefix #\-)
          (set! entries
                (cons (patch-entry path patch-index 'removed old-line #f raw-text line)
                      entries))
          (set! old-line (add1 old-line))]
         [else
          (set! entries
                (cons (patch-entry path patch-index 'context old-line new-line raw-text line)
                      entries))
          (set! old-line (add1 old-line))
          (set! new-line (add1 new-line))])]))
  (reverse entries))

(define (review-files review-json)
  (define files (hash-ref* review-json 'files #f))
  (cond
    [(list? files) files]
    [(hash? (hash-ref* review-json 'meta #f))
     (define meta-files (hash-ref* (hash-ref review-json 'meta) 'files #f))
     (if (list? meta-files) meta-files '())]
    [else '()]))

(define (files->patch-map review-json)
  (apply append
         (for/list ([f (in-list (review-files review-json))]
                    #:when (hash? f))
           (parse-patch (file-name f) (file-diff f)))))

(define (find-file-entry patch-map path)
  (findf (lambda (e) (equal? (patch-entry-path e) path)) patch-map))

(define (find-line-location patch-map path line side)
  (define side-sym
    (cond
      [(symbol? side) side]
      [(string? side) (string->symbol (string-upcase side))]
      [else 'RIGHT]))
  (findf
   (lambda (e)
     (and (equal? (patch-entry-path e) path)
          (case side-sym
            [(RIGHT)
             (and (patch-entry-new-line e)
                  (= (patch-entry-new-line e) line)
                  (not (eq? (patch-entry-kind e) 'removed)))]
            [(LEFT)
             (and (patch-entry-old-line e)
                  (= (patch-entry-old-line e) line)
                  (not (eq? (patch-entry-kind e) 'added)))]
            [else #f])))
   patch-map))

(struct issue (level id message data) #:transparent)
(struct validation (errors warnings infos locations) #:transparent)

(define (issue->jsexpr i)
  (hasheq 'level (symbol->string (issue-level i))
          'id (issue-id i)
          'message (issue-message i)
          'data (issue-data i)))

(define (validation-ok? v)
  (null? (validation-errors v)))

(define (validation->jsexpr v)
  (hasheq 'ok (validation-ok? v)
          'errors (map issue->jsexpr (reverse (validation-errors v)))
          'warnings (map issue->jsexpr (reverse (validation-warnings v)))
          'infos (map issue->jsexpr (reverse (validation-infos v)))
          'locations (map patch-entry->jsexpr (reverse (validation-locations v)))))

(define (validate-comment-records records #:review-json [review-json #f])
  (define meta-records (filter (lambda (r) (section=? 'meta r)) records))
  (define decision-records (filter (lambda (r) (section=? 'decision r)) records))
  (define inline-records (filter (lambda (r) (section=? 'inline-comment r)) records))
  (define errors '())
  (define warnings '())
  (define infos '())
  (define locations '())
  (define (add-error id msg data)
    (set! errors (cons (issue 'error id msg data) errors)))
  (define (add-warning id msg data)
    (set! warnings (cons (issue 'warning id msg data) warnings)))
  (define (add-info id msg data)
    (set! infos (cons (issue 'info id msg data) infos)))

  (unless (= (length meta-records) 1)
    (add-error "meta-count"
               (format "expected exactly one meta record, got ~a"
                       (length meta-records))
               (hasheq)))

  (define meta (and (= (length meta-records) 1) (car meta-records)))
  (define platform (and meta (rec-get* 'platform meta #f)))
  (define review-type (and meta (rec-get* 'review-type meta 'pr)))

  (when (and (eq? review-type 'pr) (not (= (length decision-records) 1)))
    (add-error "decision-count"
               (format "PR review requires exactly one decision record, got ~a"
                       (length decision-records))
               (hasheq)))

  (define patch-map (and review-json (files->patch-map review-json)))
  (when (and review-json (null? patch-map) (not (null? inline-records)))
    (add-warning "empty-patch-map"
                 "review JSON has no usable patch data for inline validation"
                 (hasheq)))

  (for ([c (in-list inline-records)])
    (define id (rec-get* 'id c #f))
    (define path (rec-get* 'path c #f))
    (define line (rec-get* 'line c #f))
    (define side (rec-get* 'side c "RIGHT"))
    (define side-text
      (cond
        [(symbol? side) (string-upcase (symbol->string side))]
        [(string? side) side]
        [else (format "~a" side)]))
    (define position (rec-get* 'position c #f))
    (define data (hasheq 'id (or id 'null)
                         'path (or path 'null)
                         'line (or line 'null)
                         'side side-text
                         'position (or position 'null)))
    (unless path
      (add-error "inline-missing-path" "inline comment is missing path" data))
    (unless (integer? line)
      (add-error "inline-missing-line" "inline comment line must be an integer" data))
    (unless (member side '("RIGHT" "LEFT" RIGHT LEFT))
      (add-error "inline-bad-side" "inline comment side must be RIGHT or LEFT" data))

    (when (and patch-map path (integer? line))
      (cond
        [(not (find-file-entry patch-map path))
         (add-error "inline-path-not-in-diff"
                    "inline comment path does not exist in changed files"
                    data)]
        [else
         (define loc (find-line-location patch-map path line side))
         (if loc
             (begin
               (set! locations (cons loc locations))
               (add-info "inline-location"
                         (format "~a:~a ~a -> ~a"
                                 path line side-text (patch-entry-text loc))
                         data))
             (add-error "inline-line-not-in-diff"
                        "inline comment line is not present on the selected side of the diff"
                        data))]))

    (when (and (eq? review-type 'pr) (eq? platform 'gitcode) path (integer? line))
      (cond
        [(not position)
         (add-info "gitcode-position-derived"
                   "GitCode PR inline position will be derived from line"
                   data)]
        [(not (equal? position line))
         (add-error "gitcode-position-mismatch"
                    "GitCode PR inline position must equal the source line; do not use diff offsets"
                    data)]))

    (when (and (eq? review-type 'pr) (eq? platform 'github) position)
      (add-warning "github-pr-position-ignored"
                   "GitHub PR review uses line+side; position is ignored"
                   data)))

  (validation errors warnings infos locations))

(define (print-issue prefix i)
  (printf "~a ~a: ~a\n" prefix (issue-id i) (issue-message i)))

(define (print-validation v)
  (for ([i (in-list (reverse (validation-errors v)))])
    (print-issue "ERROR" i))
  (for ([i (in-list (reverse (validation-warnings v)))])
    (print-issue "WARN" i))
  (for ([i (in-list (reverse (validation-infos v)))])
    (print-issue "INFO" i))
  (printf "location validation: ~a\n" (if (validation-ok? v) "ok" "failed")))
