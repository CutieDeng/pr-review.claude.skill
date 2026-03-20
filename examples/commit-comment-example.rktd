;; ── meta ──
((section . meta)
 (review-type . commit)
 (commit-url . "https://github.com/example/webapp/commit/a1b2c3d4e5f6789")
 (platform . github)
 (owner . "example")
 (repo . "webapp")
 (commit-sha . "a1b2c3d4e5f6789")
 (commit-message . "Fix login timeout handling")
 (commit-author . "bob")
 (reviewed-at . "2026-03-20T14:00:00Z")
) ;; end meta

;; ── decision ──
((section . decision)
 (body . "The timeout fix looks correct overall, but the error message construction has a format string injection risk.")
) ;; end decision

;; ── inline #1 ──
((section . inline-comment)
 (id . 1)
 (path . "src/auth/timeout.rs")
 (line . 18)
 (side . "RIGHT")
 (body . "Format string injection: `user_msg` is interpolated directly into `format!`. If it contains `{}` placeholders, this will panic at runtime. Use `format!(\"{}\", user_msg)` instead.")
 (severity . critical)
 (category . security)
 (rule-ref . #f)
) ;; end inline #1

;; ── inline #2 ──
((section . inline-comment)
 (id . 2)
 (path . "src/auth/timeout.rs")
 (line . 34)
 (side . "RIGHT")
 (body . "The retry delay is hardcoded to 5s. Consider making this configurable or using exponential backoff.")
 (severity . suggestion)
 (category . performance)
 (rule-ref . #f)
) ;; end inline #2
