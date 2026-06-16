#!/usr/bin/env racket
#lang racket/base

(require "location-lib.rkt"
         json
         racket/cmdline
         racket/port
         racket/runtime-path
         racket/system)

(define-runtime-path script-dir ".")

(define opt-url (make-parameter #f))
(define opt-json-file (make-parameter #f))
(define opt-path (make-parameter #f))
(define opt-around-line (make-parameter #f))
(define opt-context (make-parameter 5))
(define opt-json? (make-parameter #f))

(define (script-path name)
  (build-path script-dir name))

(define (fetch-json url)
  (define racket-exe (or (find-executable-path "racket") "racket"))
  (define out (open-output-string))
  (define err (open-output-string))
  (define ok?
    (parameterize ([current-output-port out]
                   [current-error-port err])
      (system* racket-exe (path->string (script-path "fetch-diff.rkt"))
               "--url" url "--output" "json")))
  (unless ok?
    (error 'patch-map "fetch-diff failed: ~a" (get-output-string err)))
  (with-input-from-string (get-output-string out) read-json))

(define (entry-in-range? e center radius)
  (define j (patch-entry->jsexpr e))
  (define old-line (hash-ref j 'old_line 'null))
  (define new-line (hash-ref j 'new_line 'null))
  (define (near? v)
    (and (integer? v)
         (<= (abs (- v center)) radius)))
  (or (near? old-line) (near? new-line)))

(command-line
 #:program "patch-map"
 #:once-each
 ["--url" u "Fetch PR/commit JSON with fetch-diff.rkt" (opt-url u)]
 ["--json-file" p "Read fetch-diff --output json from file" (opt-json-file p)]
 ["--path" p "Only show one changed path" (opt-path p)]
 ["--around-line" n "Only show entries around source line N" (opt-around-line (string->number n))]
 ["--context" n "Line radius for --around-line (default: 5)" (opt-context (string->number n))]
 ["--json" "Emit JSON instead of TSV" (opt-json? #t)]
 #:args () (void))

(unless (or (opt-url) (opt-json-file))
  (error 'patch-map "use --url or --json-file"))

(define review-json
  (cond
    [(opt-json-file) (load-review-json (opt-json-file))]
    [else (fetch-json (opt-url))]))

(define entries
  (filter
   (lambda (e)
     (define j (patch-entry->jsexpr e))
     (and (or (not (opt-path))
              (equal? (hash-ref j 'path) (opt-path)))
          (or (not (opt-around-line))
              (entry-in-range? e (opt-around-line) (opt-context)))))
   (files->patch-map review-json)))

(cond
  [(opt-json?)
   (write-json (map patch-entry->jsexpr entries))
   (newline)]
  [else
   (printf "path\tpatch-index\tkind\told-line\tnew-line\ttext\n")
   (for ([e (in-list entries)])
     (define j (patch-entry->jsexpr e))
     (printf "~a\t~a\t~a\t~a\t~a\t~a\n"
             (hash-ref j 'path)
             (hash-ref j 'patch_index)
             (hash-ref j 'kind)
             (hash-ref j 'old_line)
             (hash-ref j 'new_line)
             (hash-ref j 'text)))])
