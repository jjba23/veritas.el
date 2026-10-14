;;; veritas-test.el --- Tests for veritas.el  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Josep Bigorra <jjbigorra@gmail.com>

;; This file is not part of GNU Emacs.  It is free software under the GNU Lesser
;; General Public License v3 or later, like the rest of veritas.el.

;;; Commentary:

;; Run with:
;;
;;   emacs -Q --batch -L . -L test -l test/veritas-test.el \
;;         -f ert-run-tests-batch-and-exit
;;
;; The process tests need a real Veritas checkout; they look for one at
;; `veritas-test-veritas-root' and skip when it is not there.

;;; Code:

(require 'ert)
(require 'veritas)

(defvar veritas-test-veritas-root
  (or (getenv "VERITAS_CHECKOUT") (expand-file-name "~/Hacking/veritas"))
  "Veritas checkout the end-to-end tests run against.")

(defvar veritas-test--this-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory holding this test file.")

(defun veritas-test--fixture-root ()
  "Return the root of the sample Veritas project used by the tests."
  (expand-file-name "fixture" veritas-test--this-directory))

(defun veritas-test--data-file (name)
  "Return the path of the recorded runner output called NAME."
  (expand-file-name (concat "data/" name) veritas-test--this-directory))

(defun veritas-test--lines (file)
  "Return the lines of FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (split-string (buffer-string) "\n")))

(defun veritas-test--replay (file &optional exit)
  "Build a run over the fixture and feed it the recorded output FILE.\n\nEXIT is the status the run is taken to have finished with."
  (let* ((root (veritas-test--fixture-root))
         (run (veritas--make-run :id 1
                                 :root root
                                 :cli-flags '("--reporter" "json-reporter")
                                 :layout (veritas--test-layout root)
                                 :command '("true")
                                 :started (current-time)
                                 :buffer (get-buffer-create " *veritas-test-report*")
                                 :log-buffer (get-buffer-create " *veritas-test-log*")
                                 :stderr-buffer (get-buffer-create " *veritas-test-stderr*"))))
    (dolist (line (veritas-test--lines file))
      (veritas--handle-line run line))
    (setf (veritas--run-exit run) (or exit 1))
    (let ((veritas-show-report 'never)
          (veritas-pop-to-report nil))
      (veritas--finalize run))
    run))

(defun veritas-test--node (run name)
  "Return the node of RUN called NAME, or nil."
  (seq-find (lambda (node) (equal name (veritas-node-name node)))
            (veritas--all-nodes-anywhere run)))

(defun veritas--all-nodes-anywhere (run)
  "Return every node of RUN, in tree order."
  (let ((nodes '()))
    (cl-labels ((walk (node)
                  (push node nodes)
                  (dolist (child (veritas-node-children node)) (walk child))))
      (dolist (file (veritas--run-files run)) (walk file)))
    (nreverse nodes)))

(defun veritas-test--totals (run)
  "Return the counter vector of RUN."
  (car (veritas--analysis run)))

(defun veritas-test--count (run index)
  "Return counter INDEX of RUN."
  (aref (veritas-test--totals run) index))

;;; Project detection and layout

(ert-deftest veritas-test-project-root ()
  "The fixture is recognised as a Veritas project, from any depth."
  (let ((root (veritas-test--fixture-root)))
    (should (veritas-project-p root))
    (should (equal (file-truename root)
                   (file-truename (veritas-project-root
                                   (expand-file-name "test/veritas/unit" root)))))
    (should-not (veritas-project-root "/"))))

(ert-deftest veritas-test-layout ()
  "The layout names the directory the runner reports paths against."
  (let* ((root (veritas-test--fixture-root))
         (layout (veritas--test-layout root)))
    (should layout)
    (should (equal "veritas" (cdr layout)))
    (should (file-directory-p (car layout)))
    (should (equal (expand-file-name "demo.scm" (car layout))
                   (veritas--resolve-test-file "demo.scm" layout)))))

;;; The source scanner

(defconst veritas-test--tricky-source
  (concat
   "(define-module (veritas unit tricky))\n"
   "\n"
   ";; (test \"commented out\" (assert-true #t))\n"
   "(define (spec)\n"
   "  (veritas-run #:shuffle? #f\n"
   "               (suite \"Outer Suite\"\n"
   "                 (scenario \"a scenario\"\n"
   "                   (given \"a cart with one item\"\n"
   "                     (assert-equal #:expect 1 #:got 1))\n"
   "                   (when-step \"the cart is emptied\"\n"
   "                     (assert-true #t))\n"
   "                   (then \"the cart is empty\"\n"
   "                     (assert-equal #:expect \"(test \\\"in a string\\\")\"\n"
   "                                   #:got \"x\")))\n"
   "                 (test \"plain test\"\n"
   "                   (assert-equal #:expect 1 #:got 1))\n"
   "                 (benchmark #:name \"a benchmark\"\n"
   "                   #:runs 1\n"
   "                   #:thunk (lambda () #t)))\n"
   "               (test-each \"table\" '((1 2))\n"
   "                 (lambda (case)\n"
   "                   (test \"generated\" #:skip? #t)))))\n")
  "A source with the shapes the scanner has to get right.")

(defun veritas-test--scan (source)
  "Return the definitions of SOURCE, scanned in a Scheme buffer."
  (with-temp-buffer
    (set-syntax-table scheme-mode-syntax-table)
    (insert source)
    (veritas--scan-buffer "tricky.scm")))

(ert-deftest veritas-test-scan-toplevel ()
  "The scanner finds the top level definitions and nothing else."
  (let* ((source (veritas-test--scan veritas-test--tricky-source))
         (names (mapcar #'veritas-node-name (veritas-source-nodes source))))
    (should (equal '("Outer Suite" "table") names))
    (should (equal '(suite test-each)
                   (mapcar #'veritas-node-type (veritas-source-nodes source))))))

(ert-deftest veritas-test-scan-nesting ()
  "A definition is nested inside the form that holds it."
  (let* ((source (veritas-test--scan veritas-test--tricky-source))
         (outer (car (veritas-source-nodes source)))
         (children (veritas-node-children outer)))
    (should (equal '("a scenario" "plain test" "a benchmark")
                   (mapcar #'veritas-node-name children)))
    (should (equal '(scenario test benchmark)
                   (mapcar #'veritas-node-type children)))
    (should (equal '("a cart with one item" "the cart is emptied" "the cart is empty")
                   (mapcar #'veritas-node-name
                           (veritas-node-children (car children)))))))

(ert-deftest veritas-test-scan-ignores-strings-and-comments ()
  "A form that only looks like a definition is not one."
  (let ((names (mapcar #'veritas-node-name
                       (veritas--all-nodes
                        (veritas-test--scan veritas-test--tricky-source)))))
    (should-not (member "commented out" names))
    (should-not (member "in a string" names))
    (should (member "generated" names))))

(ert-deftest veritas-test-scan-benchmark-name ()
  "A benchmark takes its name from its `#:name' argument."
  (let* ((source (veritas-test--scan veritas-test--tricky-source))
         (benchmark (veritas-test--node-in source "a benchmark")))
    (should benchmark)
    (should (eq 'benchmark (veritas-node-type benchmark)))))

(defun veritas-test--node-in (source name)
  "Return the node of SOURCE called NAME."
  (seq-find (lambda (node) (equal name (veritas-node-name node)))
            (veritas--all-nodes source)))

(ert-deftest veritas-test-scan-longest-keyword-wins ()
  "`test-each' is not read as a `test' followed by junk."
  (let ((veritas--group-keywords '("test-each" "test")))
    (should (equal '(test-each)
                   (mapcar #'veritas-node-type
                           (veritas-source-nodes
                            (veritas-test--scan
                             "(test-each \"t\" '() (lambda (c) c))\n")))))))

(ert-deftest veritas-test-skip-detection ()
  "`#:skip? #t' is noticed in the source."
  (let* ((source (veritas-test--scan veritas-test--tricky-source))
         (skipped (veritas-test--node-in source "generated")))
    (should skipped)
    (should (veritas-node-skip skipped))))

(ert-deftest veritas-test-candidate-names ()
  "A step and a scenario are matched by the name the runner reports."
  (let* ((source (veritas-test--scan veritas-test--tricky-source))
         (step (veritas-test--node-in source "the cart is empty"))
         (scenario (veritas-test--node-in source "a scenario")))
    (should (member "Then the cart is empty" (veritas--node-candidate-names step)))
    (should (member "the cart is empty" (veritas--node-candidate-names step)))
    (should (member "Scenario: a scenario" (veritas--node-candidate-names scenario)))))

;;; Imenu, which-function and point queries

(ert-deftest veritas-test-imenu-index ()
  "Imenu nests a test under the suite that holds it."
  (with-temp-buffer
    (set-syntax-table scheme-mode-syntax-table)
    (insert veritas-test--tricky-source)
    (let* ((index (veritas-imenu-create-index))
           (outer (assoc "Outer Suite" index)))
      (should (equal '("Outer Suite" "table") (mapcar #'car index)))
      ;; A group is (NAME POSITION . CHILDREN) and a leaf is (NAME . POSITION).
      (should (markerp (cadr outer)))
      (should (equal '("a scenario" "plain test" "a benchmark")
                     (mapcar #'car (cddr outer))))
      (should (markerp (cadr (assoc "a scenario" (cddr outer)))))
      (should (markerp (cdr (assoc "plain test" (cddr outer)))))
      (should (markerp (cdr (assoc "a benchmark" (cddr outer))))))))

(ert-deftest veritas-test-which-function ()
  "The enclosing test is known from inside it."
  (with-temp-buffer
    (set-syntax-table scheme-mode-syntax-table)
    (insert veritas-test--tricky-source)
    (goto-char (point-min))
    (search-forward "(test \"plain test\"")
    (should (equal "Outer Suite › plain test" (veritas-which-function)))))

(ert-deftest veritas-test-node-at-point ()
  "The innermost definition is the one point is in."
  (with-temp-buffer
    (set-syntax-table scheme-mode-syntax-table)
    (insert veritas-test--tricky-source)
    (goto-char (point-min))
    (search-forward "\"the cart is emptied\"")
    (should (eq 'when-step (veritas-node-type (veritas--node-at-point))))))

(ert-deftest veritas-test-public-api ()
  "The query functions a user builds on answer for the buffer."
  (with-temp-buffer
    (set-syntax-table scheme-mode-syntax-table)
    (insert veritas-test--tricky-source)
    (goto-char (point-min))
    (search-forward "\"the cart is emptied\"")
    (let ((node (veritas-node-at-point)))
      (should (eq 'when-step (veritas-node-type node)))
      (should (equal '("Outer Suite" "a scenario" "the cart is emptied")
                     (veritas-node-titles node)))
      (should (eq 'when-step (veritas-node-type (car (veritas-enclosing-nodes)))))
      (should (equal "Outer Suite"
                     (veritas-node-name (car (veritas-node-path node)))))
      (should (equal "the cart is emptied"
                     (veritas-node-name (car (last (veritas-node-path node)))))))
    ;; Every definition, nested ones included, outermost first.
    (should (equal '("Outer Suite" "a scenario" "a cart with one item"
                     "the cart is emptied" "the cart is empty" "plain test"
                     "a benchmark" "table" "generated")
                   (mapcar #'veritas-node-name (veritas-nodes))))
    (should (seq-find (lambda (one) (equal "a benchmark" (veritas-node-name one)))
                      (veritas-nodes-in-region (point-min) (point-max))))
    (should (seq-find (lambda (one) (eq 'suite (veritas-node-type one)))
                      (veritas-nodes-in-line 6)))
    (should-not (veritas-nodes-in-line 1))))

;;; Command building

(ert-deftest veritas-test-command-list-is-used ()
  "An explicit command is used as it stands."
  (let ((veritas-command '("veritas" "--verbose")))
    (should (equal '("veritas" "--verbose")
                   (veritas--command (veritas-test--fixture-root))))))

(ert-deftest veritas-test-run-flags ()
  "The flags carry the reporter, the layout and the selection."
  (let* ((root (veritas-test--fixture-root))
         (flags (veritas--run-flags root '("--only-test" "addition works"))))
    (should (equal "json-reporter"
                   (cadr (member "--reporter" flags))))
    (should (equal "unit" (cadr (member "--test-type" flags))))
    (should (equal "veritas" (cadr (member "--test-module" flags))))
    (should (member "--no-shuffle" flags))
    (should (member "--benchmarks" flags))
    (should (equal '("--only-test" "addition works")
                   (last flags 2)))))

(ert-deftest veritas-test-run-flags-skip-benchmarks ()
  "A run can be told to leave the benchmarks out."
  (let ((flags (veritas--run-flags (veritas-test--fixture-root) nil t)))
    (should (member "--no-benchmarks" flags))
    (should-not (member "--benchmarks" flags))))

(ert-deftest veritas-test-strip-selecting-flags ()
  "A rerun that selects something new drops the old selection."
  (should (equal '("--reporter" "json-reporter" "--no-shuffle")
                 (veritas--strip-selecting-flags
                  '("--reporter" "json-reporter" "--only-test" "x"
                    "--scan-dir" "/tmp" "--only-failed" "--no-shuffle")))))

(ert-deftest veritas-test-replace-reporter ()
  "The raw run swaps the reporter for the project's own."
  (should (equal '("--reporter" "emoji-reporter" "--no-shuffle")
                 (veritas--replace-reporter
                  '("--reporter" "json-reporter" "--no-shuffle")
                  "emoji-reporter"))))

;;; Reading the runner's stream

(ert-deftest veritas-test-replay-files ()
  "The recorded run is read into one file node, resolved to disk."
  (let* ((run (veritas-test--replay (veritas-test--data-file "fixture-failing.out")))
         (files (veritas--run-files run)))
    (should (equal 1 (length files)))
    (should (equal "demo.scm" (veritas-node-name (car files))))
    (should (file-exists-p (veritas-node-file (car files))))
    (should (equal 'failed (veritas--run-status run)))))

(ert-deftest veritas-test-replay-structure ()
  "Suites, tests and assertions land under the definitions they name."
  (let* ((run (veritas-test--replay (veritas-test--data-file "fixture-failing.out")))
         (math (veritas-test--node run "Math Suite"))
         (failing (veritas-test--node run "a deliberately failing test")))
    (should (equal 'suite (veritas-node-type math)))
    (should (equal 3 (length (veritas-node-children math))))
    (should (equal 'fail (veritas-node-status failing)))
    (should (eq math (veritas-node-parent failing)))
    (should (equal 1 (length (veritas-node-children failing))))
    (should (equal "1 + 1 = 3, which fails"
                   (veritas-node-name (car (veritas-node-children failing)))))
    (should (equal 'fail (veritas-node-status
                          (car (veritas-node-children failing)))))))

(ert-deftest veritas-test-replay-lines ()
  "The failing test points back at its own definition."
  (let* ((run (veritas-test--replay (veritas-test--data-file "fixture-failing.out")))
         (node (veritas-test--node run "a deliberately failing test"))
         (file (veritas-node-file node))
         (expected (with-temp-buffer
                     (insert-file-contents file)
                     (goto-char (point-min))
                     (search-forward "\"a deliberately failing test\"")
                     (line-number-at-pos))))
    (should (equal expected (veritas-node-line node)))))

(ert-deftest veritas-test-replay-counts ()
  "The counters add up: one failure, three passes, one test not run."
  (let ((run (veritas-test--replay (veritas-test--data-file "fixture-failing.out"))))
    (should (equal 4 (veritas-test--count run veritas--stat-tests)))
    (should (equal 1 (veritas-test--count run veritas--stat-benchmarks)))
    (should (equal 3 (veritas-test--count run veritas--stat-passed)))
    (should (equal 1 (veritas-test--count run veritas--stat-failed)))
    (should (equal 1 (veritas-test--count run veritas--stat-not-run)))
    (should (equal 4 (veritas-test--count run veritas--stat-assertions)))
    (should (equal 1 (veritas-test--count run veritas--stat-failed-assertions)))))

(ert-deftest veritas-test-replay-fatal ()
  "The run's own complaint is kept."
  (let ((run (veritas-test--replay (veritas-test--data-file "fixture-failing.out"))))
    (should (seq-find (lambda (message)
                        (string-match-p "aborting due to error" message))
                      (veritas--run-fatal run)))))

(ert-deftest veritas-test-replay-benchmark-not-run ()
  "A benchmark the run skipped is reported as not run, not as passed."
  (let* ((run (veritas-test--replay (veritas-test--data-file "fixture-failing.out")))
         (benchmark (veritas-test--node run "summing a large list")))
    (should benchmark)
    (should (eq 'not-run (veritas-node-status benchmark)))))

(ert-deftest veritas-test-replay-bdd-names ()
  "A step reported under its prefixed name still finds its definition."
  (let* ((run (veritas--make-run :id 2
                                 :root (veritas-test--fixture-root)
                                 :cli-flags '("--reporter" "json-reporter")
                                 :layout (veritas--test-layout (veritas-test--fixture-root))
                                 :command '("true")
                                 :buffer (get-buffer-create " *veritas-test-report2*"))))
    (veritas--begin-file run "demo.scm")
    (setf (veritas--run-current-file run)
          (car (veritas--run-files run)))
    (veritas--on-suite run "Scenario: a scenario")
    (should (veritas--run-current-suite run))))

;;; Drawing the report

(ert-deftest veritas-test-report-rendering ()
  "The report names its failures, its counts and its links."
  (let* ((run (veritas-test--replay (veritas-test--data-file "fixture-failing.out")))
         (text (with-current-buffer (veritas--run-buffer run)
                 (buffer-string))))
    (should (string-match-p "Failures (1)" text))
    (should (string-match-p "a deliberately failing test" text))
    ;; The path in front of a failure names its suites, not the failure again.
    (should-not (string-match-p "a deliberately failing test › a deliberately failing test"
                                text))
    (should (string-match-p "error, expect: 3, got: 2" text))
    (should (string-match-p "demo.scm" text))
    (should (string-match-p "1 failed" text))
    (should (string-match-p "rerun failed" text))))

(ert-deftest veritas-test-report-links-to-definitions ()
  "A line of the report carries the node it stands for."
  (let* ((run (veritas-test--replay (veritas-test--data-file "fixture-failing.out")))
         (node (veritas-test--node run "a deliberately failing test")))
    (with-current-buffer (veritas--run-buffer run)
      (goto-char (point-min))
      (should (veritas--goto-node node))
      (should (eq node (veritas--node-at-position (point)))))))

(ert-deftest veritas-test-report-failures-are-navigable ()
  "`next-error-function' walks the failures of a report."
  (let* ((run (veritas-test--replay (veritas-test--data-file "fixture-failing.out"))))
    (with-current-buffer (veritas--run-buffer run)
      (goto-char (point-min))
      (veritas-results-next-error 1 t)
      (should (veritas--failing-line-p (point))))))

(ert-deftest veritas-test-report-folds ()
  "Folding a suite hides its tests."
  (let* ((run (veritas-test--replay (veritas-test--data-file "fixture-failing.out")))
         (math (veritas-test--node run "Math Suite")))
    (with-current-buffer (veritas--run-buffer run)
      (should (string-match-p "addition works" (buffer-string)))
      (veritas--toggle-node math)
      (should-not (string-match-p "addition works" (buffer-string)))
      (veritas--toggle-node math)
      (should (string-match-p "addition works" (buffer-string))))))

;;; End to end, against a real Veritas checkout

(defun veritas-test--veritas-available-p ()
  "Return non-nil when the end-to-end tests can run."
  (and (file-executable-p (expand-file-name "bin/veritas" veritas-test-veritas-root))
       (executable-find "guix")))

(defun veritas-test--command ()
  "Return the command that runs the checkout's Veritas."
  (list "guix" "shell" "-m" (expand-file-name "manifest.scm" veritas-test-veritas-root)
        "--" (expand-file-name "bin/veritas" veritas-test-veritas-root)))

(defun veritas-test--run-to-completion (root flags &optional overrides)
  "Start a run in ROOT with FLAGS and OVERRIDES, and wait for it."
  (let ((veritas-command (veritas-test--command))
        (veritas-pop-to-report nil)
        (veritas-show-report 'never)
        (run nil))
    (setq run (veritas--start root flags overrides))
    (let ((deadline (+ (float-time) 120)))
      (while (and (veritas-running-p run) (< (float-time) deadline))
        (accept-process-output nil 0.1)))
    (should-not (veritas-running-p run))
    run))

(ert-deftest veritas-test-end-to-end ()
  "A real run of the fixture fails, and the report says why."
  (skip-unless (veritas-test--veritas-available-p))
  (let* ((root (veritas-test--fixture-root))
         (run (veritas-test--run-to-completion
               root (veritas--run-flags root '("--no-benchmarks")))))
    (should (equal 'failed (veritas--run-status run)))
    (should (equal 1 (veritas--run-exit run)))
    (let ((text (with-current-buffer (veritas--run-buffer run) (buffer-string))))
      (should (string-match-p "a deliberately failing test" text))
      (should (string-match-p "error, expect: 3, got: 2" text)))
    (let ((node (veritas-test--node run "a deliberately failing test")))
      (should node)
      (should (veritas-node-line node))
      (should (file-exists-p (veritas-node-file node))))))

(ert-deftest veritas-test-end-to-end-single-file ()
  "The throwaway scan root runs one file on its own."
  (skip-unless (veritas-test--veritas-available-p))
  (let* ((root (veritas-test--fixture-root))
         (file (expand-file-name "test/veritas/unit/demo.scm" root))
         (overrides (veritas--file-run-overrides file root))
         (run nil))
    (should overrides)
    (setq run (veritas-test--run-to-completion
               root (veritas--run-flags root '("--no-benchmarks" "--only-test"
                                               "subtraction")) overrides))
    (should (equal 1 (length (veritas--run-files run))))
    (should (equal 'passed (veritas--run-status run)))))

(provide 'veritas-test)
;;; veritas-test.el ends here
