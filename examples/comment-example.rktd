;; ── meta ──
((section . meta)
 (review-type . pr)
 (pr-url . "https://github.com/example/webapp/pull/42")
 (platform . github)
 (owner . "example")
 (repo . "webapp")
 (pr-number . 42)
 (pr-title . "Add user authentication endpoint")
 (pr-author . "alice")
 (reviewed-at . "2026-03-19T10:30:00Z")
) ;; end meta

;; ── decision ──
((section . decision)
 (event . "REQUEST_CHANGES")
 (body . "Overall the authentication approach is sound, but there are critical security issues with SQL injection and plaintext password handling that must be fixed before merging.")
) ;; end decision

;; ── inline #1 ──
((section . inline-comment)
 (id . 1)
 (path . "src/auth/login.rs")
 (line . 23)
 (side . "RIGHT")
 (body . "SQL injection vulnerability: user input is directly concatenated into query string. Use parameterized queries instead:\n```rust\nsqlx::query(\"SELECT * FROM users WHERE email = $1\").bind(&email)\n```")
 (severity . critical)
 (category . security)
 (rule-ref . "no-sql-injection")
) ;; end inline #1

;; ── inline #2 ──
((section . inline-comment)
 (id . 2)
 (path . "src/auth/login.rs")
 (line . 45)
 (side . "RIGHT")
 (body . "Passwords are compared in plaintext. Use bcrypt or argon2 for password hashing:\n```rust\nbcrypt::verify(&input_password, &stored_hash)?\n```")
 (severity . critical)
 (category . security)
 (rule-ref . #f)
) ;; end inline #2

;; ── inline #3 ──
((section . inline-comment)
 (id . 3)
 (path . "src/auth/middleware.rs")
 (line . 12)
 (side . "RIGHT")
 (body . "Token expiration is set to 30 days which is unusually long for an auth token. Consider 24h with refresh token rotation.")
 (severity . warning)
 (category . security)
 (rule-ref . #f)
) ;; end inline #3

;; ── inline #4 ──
((section . inline-comment)
 (id . 4)
 (path . "src/auth/login.rs")
 (line . 67)
 (side . "RIGHT")
 (body . "This database query runs inside the request handler without connection pooling. Consider using a shared pool to avoid connection exhaustion under load.")
 (severity . warning)
 (category . performance)
 (rule-ref . #f)
) ;; end inline #4

;; ── inline #5 ──
((section . inline-comment)
 (id . 5)
 (path . "src/auth/types.rs")
 (line . 8)
 (side . "RIGHT")
 (body . "`AuthError` could derive `thiserror::Error` for cleaner error propagation instead of manual `Display` impl.")
 (severity . suggestion)
 (category . style)
 (rule-ref . #f)
) ;; end inline #5

;; ── reply #1 ──
((section . reply)
 (id . 1)
 (in-reply-to . 987654321)
 (comment-type . review-comment)
 (body . "Good point — I'd also recommend using `argon2id` variant specifically, as it provides better resistance against both GPU and side-channel attacks than plain argon2.")
 (context . "@bob suggested using bcrypt for password hashing")
) ;; end reply #1
