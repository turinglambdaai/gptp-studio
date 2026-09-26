#lang racket/base

;; Parsers for linuxptp command output. Pure functions over text so the
;; golden tests can pin the formats shipped by linuxptp 3.x (Ubuntu 22.04+).
;;
;; ptp4l -m writes lines like:
;;   ptp4l[128.926]: selected local clock b62f08.fffe.1a2b3c as best master
;;   ptp4l[128.926]: assuming the grand master role
;;   ptp4l[128.929]: port 1: INITIALIZING to LISTENING on INIT_COMPLETE
;;   ptp4l[131.668]: master offset      -1234 s2 freq    -5679 path delay      8912
;;   ptp4l[131.700]: path delay      8812 neighbor rate ratio  -0.000000012
;;   ptp4l[133.001]: port 1: new foreign master a0b1c2.fffe.d3e4f5-1
;;
;; pmc GET responses come as indented key/value blocks.

(require racket/list
         racket/match
         racket/string)

(provide parse-ptp4l-line
         parse-ptp4l-log
         parse-pmc-output)

;; ---- ptp4l -------------------------------------------------------------------

;; Returns #f when the line carries nothing we track, otherwise one of
;;   (list 'offset ns freq-ppb path-delay-ns)
;;   (list 'path-delay ns neighbor-rate-ratio)
;;   (list 'state port from to reason)
;;   (list 'best-master clock-id)
;;   (list 'gm-role)
;;   (list 'foreign-master id-port)
;;   (list 'note level message)   ; level: 'info | 'warn | 'error
(define (parse-ptp4l-line line)
  (define (strip prefix)
    (define m (regexp-match (format "^~a" (regexp-quote prefix)) line))
    (and m (substring line (string-length prefix))))
  ;; normalize "ptp4l[...]: rest" / "ptp4l: rest"
  (define rest
    (or (let ([m (regexp-match #px"^ptp4l\\[[^]]*\\]:\\s*(.*)$" line)])
          (and m (second m)))
        (strip "ptp4l: ")))
  (cond
    [(not rest) #f]
    [(regexp-match #px"^master offset\\s+(-?[0-9.]+)\\s+s[0-9]+\\s+freq\\s+(-?[0-9]+)\\s+path delay\\s+(-?[0-9.]+)" rest)
     => (lambda (m)
          (list 'offset (num (second m)) (num (third m)) (num (fourth m))))]
    [(regexp-match #px"^path delay\\s+(-?[0-9.]+)\\s+neighbor rate ratio\\s+(-?[0-9.e+-]+)" rest)
     => (lambda (m)
          (list 'path-delay (num (second m)) (num (third m))))]
    [(regexp-match #px"^port ([0-9]+):\\s+([A-Z_]+) to ([A-Z_]+) on (.+)$" rest)
     => (lambda (m)
          (list 'state (num (second m)) (third m) (fourth m) (fifth m)))]
    [(regexp-match #px"^port ([0-9]+):\\s+([A-Z_]+) to ([A-Z_]+)$" rest)
     => (lambda (m)
          (list 'state (num (second m)) (third m) (fourth m) "unknown"))]
    [(regexp-match #px"^selected local clock ([0-9a-f.]+) as best master" rest)
     => (lambda (m) (list 'best-master (second m)))]
    [(regexp-match #px"assuming the grand master role" rest) (list 'gm-role)]
    [(regexp-match #px"new foreign master ([0-9a-f.]+-[0-9]+)" rest)
     => (lambda (m) (list 'foreign-master (second m)))]
    [(or (regexp-match #px"(?i:error)" rest) (regexp-match #px"(?i:failed)" rest))
     (list 'note 'error rest)]
    [(regexp-match #px"(?i:warning)" rest) (list 'note 'warn rest)]
    [else (list 'note 'info rest)]))

(define (num s)
  (define v (string->number s))
  (if (real? v) v 0))

;; Convenience: parse a full log dump; returns the list of non-#f events.
(define (parse-ptp4l-log text)
  (filter values (map parse-ptp4l-line (string-split text "\n"))))

;; ---- pmc ---------------------------------------------------------------------

;; Parse pmc's text output into a list of response blocks. Each block is a
;; hash with the command name plus every parseable key/value field:
;;   (list (hasheq 'command "GET CURRENT_DATA_SET" 'portState "SLAVE"
;;                 'offsetFromMaster 12.0 ...))
;; pmc prints:
;;   \tsending: GET CURRENT_DATA_SET <id>
;;   \tb62f08.fffe.1a2b3c-1\t <some id>
;;   \tportState                    SLAVE
;;   \toffsetFromMaster             12.000000
;; Hex values (e.g. gmClockAccuracy 0xfe) are stored as decimal numbers.
(define (parse-pmc-output text)
  (define blocks '())
  (define current (make-hasheq))
  (define (flush!)
    (when (> (hash-count current) 0)
      (set! blocks (cons current blocks))
      (set! current (make-hasheq))))
  (define (hex-string->number v)
    (string->number (string-replace (string-downcase v) "0x" "#x")))
  (for ([raw (in-list (string-split text "\n"))])
    (define line (string-trim raw))
    (cond
      [(regexp-match #px"^(?:sending|settle):\\s*(?:GET|SET) ([A-Z_]+)" line)
       => (lambda (m)
            (flush!)
            (hash-set! current 'command (second m)))]
      [(regexp-match #px"^(GET|SET) ([A-Z_]+)" line)
       => (lambda (m)
            (flush!)
            (hash-set! current 'command (third m)))]
      [(regexp-match #px"^([A-Za-z_][A-Za-z0-9_.]*)\\s+(-?[0-9.]+|0[xX][0-9a-fA-F]+|ok|SLAVE|MASTER|LISTENING|PASSIVE|PRE_MASTER|UNCALIBRATED|FAULTY|DISABLED|INITIALIZING)$" line)
       => (lambda (m)
            (define key (string->symbol (second m)))
            (define vstr (third m))
            (hash-set! current key (or (string->number vstr)
                                       (hex-string->number vstr)
                                       vstr)))]
      [(regexp-match #px"^([A-Za-z_][A-Za-z0-9_.]*)\\s+([0-9a-f:.]+-[0-9]+)$" line)
       => (lambda (m)
            (hash-set! current (string->symbol (second m)) (third m)))]
      [else (void)]))
  (flush!)
  (reverse blocks))
