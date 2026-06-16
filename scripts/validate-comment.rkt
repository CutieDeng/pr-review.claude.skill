#!/usr/bin/env racket
#lang racket/base

(require "location-lib.rkt"
         json
         racket/cmdline
         racket/file
         racket/port
         racket/runtime-path
         racket/system)

(define-runtime-path script-dir ".")

(define opt-file (make-parameter "comment.rktd"))
(define opt-url (make-parameter #f))
(define opt-json-file (make-parameter #f))
(define opt-self-check? (make-parameter #f))

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
    (error 'validate-comment "fetch-diff failed: ~a" (get-output-string err)))
  (with-input-from-string (get-output-string out) read-json))

(command-line
 #:program "validate-comment"
 #:once-each
 ["--file" f "Path to comment.rktd (default: comment.rktd)" (opt-file f)]
 ["--url" u "Fetch PR/commit JSON with fetch-diff.rkt for location checks" (opt-url u)]
 ["--json-file" p "Read fetch-diff --output json from file for location checks" (opt-json-file p)]
 ["--self-check" "Emit machine-readable JSON diagnostics" (opt-self-check? #t)]
 #:args () (void))

(unless (file-exists? (opt-file))
  (error 'validate-comment "File not found: ~a" (opt-file)))

(define records (read-rktd-records (opt-file)))
(define review-json
  (cond
    [(opt-json-file) (load-review-json (opt-json-file))]
    [(opt-url) (fetch-json (opt-url))]
    [else #f]))

(define result (validate-comment-records records #:review-json review-json))

(cond
  [(opt-self-check?)
   (write-json (validation->jsexpr result))
   (newline)]
  [else
   (print-validation result)])

(unless (validation-ok? result)
  (exit 1))
