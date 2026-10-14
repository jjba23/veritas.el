;; veritas.el fixture
;;
;; A tiny, deliberately deterministic Veritas project: suites and tests run in
;; declaration order and without shuffling, so the integration's golden output
;; stays stable.  One test fails on purpose, so the failure reporting has
;; something to show.

(define-module (veritas unit demo)
  #:use-module (veritas veritas)
  #:use-module (veritas reporter)
  #:export (spec))

(define math-suite
  (suite "Math Suite"
         #:shuffle? #f
         #:concurrent? #f
         (test "addition works"
               #:shuffle? #f
               (assert-equal #:expect 4
                             #:got (+ 2 2)
                             #:name "2 + 2 = 4"))
         (test "subtraction works"
               #:shuffle? #f
               (assert-equal #:expect 2
                             #:got (- 3 1)
                             #:name "3 - 1 = 2"))
         (test "a deliberately failing test"
               #:shuffle? #f
               (assert-equal #:expect 3
                             #:got (+ 1 1)
                             #:name "1 + 1 = 3, which fails"))))

(define string-suite
  (suite "String Suite"
         #:shuffle? #f
         #:concurrent? #f
         (test "concatenation"
               #:shuffle? #f
               (assert-equal #:expect "ab"
                             #:got (string-append "a" "b")
                             #:name "a + b = ab"))))

(define bench
  (benchmark #:name "summing a large list"
             #:runs 2
             #:thunk (lambda ()
                       (apply + (iota 10000)))))

(define (spec)
  (veritas-run #:shuffle? #f
               math-suite
               string-suite
               bench))
