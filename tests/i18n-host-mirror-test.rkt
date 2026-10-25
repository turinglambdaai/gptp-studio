#lang racket/base

;; The GTK host compiles a fallback copy of the shared string table into
;; linux/src/main.cpp (kStrings). This test keeps that copy honest: every
;; host key must exist in app/i18n.rkt with byte-identical zh and en
;; strings, so the single-source table cannot drift from the shipped host
;; (issue #40's language-consistent primary controls).

(require rackunit
         racket/file
         racket/runtime-path
         "../app/i18n.rkt")

(define-runtime-path host-source "../linux/src/main.cpp")

;; ---- C++ table scanner ----------------------------------------------------
;; Follows C++ lexing rules for the constructs the table uses: adjacent
;; string literals concatenate, commas separate the key/zh/en groups, and
;; braces inside literals are data, not structure.

(define (string-index text needle)
  (let loop ([i 0])
    (cond [(> (+ i (string-length needle)) (string-length text)) #f]
          [(equal? (substring text i (+ i (string-length needle))) needle) i]
          [else (loop (add1 i))])))

;; Read one C++ string literal starting at the opening quote.
;; Returns (values literal index-after-closing-quote).
(define (read-literal text i)
  (let loop ([i (add1 i)] [acc '()])
    (define c (string-ref text i))
    (cond
      [(char=? c #\\) (loop (+ i 2) (cons (string-ref text (add1 i)) acc))]
      [(char=? c #\") (values (list->string (reverse acc)) (add1 i))]
      [else (loop (add1 i) (cons c acc))])))

;; Split the table body into entry bodies (the text between each entry's
;; outer braces, ignoring braces that live inside string literals).
;; The scan stops when the table's own closing brace arrives.
(define (entry-bodies text)
  (define anchor "TrEntry const kStrings[] = {")
  (define start (string-index text anchor))
  (unless start
    (error 'i18n-host-mirror "host table anchor not found"))
  (let loop ([i (+ start (string-length anchor))]
             [table-depth 1]        ; the anchor consumed the table's {
             [in-entry? #f]
             [entry-depth 0]
             [acc '()]              ; entry body pieces, in reverse
             [entries '()])
    (cond
      [(>= i (string-length text)) (reverse entries)]
      [(char=? (string-ref text i) #\")
       (define-values (lit next) (read-literal text i))
       ;; keep the literal verbatim (quotes included) so parse-entry can
       ;; re-lex the body with the same rules
       (loop next table-depth in-entry? entry-depth
             (if in-entry? (cons "\"" (cons lit (cons "\"" acc))) acc)
             entries)]
      [(char=? (string-ref text i) #\{)
       (if in-entry?
           (loop (add1 i) table-depth #t (add1 entry-depth) (cons "{" acc) entries)
           (loop (add1 i) table-depth #t 1 '() entries))]
      [(char=? (string-ref text i) #\})
       (cond
         [in-entry?
          (if (= entry-depth 1)
              (loop (add1 i) table-depth #f 0 '()
                    (cons (apply string-append (reverse (cons "}" acc))) entries))
              (loop (add1 i) table-depth #t (sub1 entry-depth) (cons "}" acc) entries))]
         [(= table-depth 1) (reverse entries)]   ; table's closing brace
         [else (loop (add1 i) (sub1 table-depth) #f entry-depth acc entries)])]
      [else
       (loop (add1 i) table-depth in-entry? entry-depth
             (if in-entry? (cons (string (string-ref text i)) acc) acc)
             entries)])))

;; One entry body -> the (key zh en) groups: literals concatenate within a
;; group, a comma starts the next group.
(define (parse-entry body)
  (define (skip-ws i)
    (if (and (< i (string-length body)) (char-whitespace? (string-ref body i)))
        (skip-ws (add1 i))
        i))
  (let loop ([i 0] [groups '()] [current '()])   ; current: literal pieces, reversed
    (define i2 (skip-ws i))
    (cond
      [(>= i2 (string-length body))
       (reverse (cons (apply string-append (reverse current)) groups))]
      [(char=? (string-ref body i2) #\")
       (define-values (lit next) (read-literal body i2))
       (loop next groups (cons lit current))]
      [(char=? (string-ref body i2) #\,)
       (loop (add1 i2)
             (cons (apply string-append (reverse current)) groups)
             '())]
      [else (loop (add1 i2) groups current)])))

(define host-entries
  (for/list ([body (entry-bodies (file->string host-source))])
    (define groups (parse-entry body))
    (unless (= (length groups) 3)
      (error 'i18n-host-mirror
             "host table entry does not parse into key/zh/en: ~a" body))
    groups))

;; ---- checks ----------------------------------------------------------------

(check-true (pair? host-entries) "the host table should not be empty")

(for ([entry host-entries])
  (define key (list-ref entry 0))
  (define zh (list-ref entry 1))
  (define en (list-ref entry 2))
  (define shared-zh (t "zh" (string->symbol key)))
  (check-false (string=? shared-zh key)
               (format "host key ~s is missing from app/i18n.rkt" key))
  (check-equal? shared-zh zh
                (format "zh text drifted for ~s" key))
  (check-equal? (t "en" (string->symbol key)) en
                (format "en text drifted for ~s" key)))
