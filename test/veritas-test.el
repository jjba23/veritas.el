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

(defmacro veritas-test--detecting (executables &rest body)
  "Run BODY with only EXECUTABLES findable and no checkout named by the env."
  (declare (indent 1) (debug t))
  `(cl-letf (((symbol-function 'executable-find)
              (lambda (name) (and (member name ',executables)
                                  (concat "/usr/bin/" name)))))
     (let ((process-environment
            (seq-remove (lambda (var)
                          (string-prefix-p "VERITAS_CHECKOUT=" var))
                        process-environment))
           (veritas-checkout nil))
       ,@body)))

(defun veritas-test--checkout (dir)
  "Make DIR look like a checkout of the Veritas sources."
  (make-directory (expand-file-name "src/veritas" dir) t)
  (with-temp-file (expand-file-name "src/veritas/cli.scm" dir)
    (insert "(define-module (veritas cli))\n"))
  dir)

(defun veritas-test--project (&rest options)
  "Make a throwaway project, returning its root.

The project holds a manifest and a test directory.  OPTIONS may hold
`launcher' for a `bin/veritas' of its own, `vendored' for a checkout of the
Veritas sources inside it, and `sibling' for one beside it.  It sits alone in
a fresh directory, so nothing else can be discovered next to it."
  (let* ((parent (make-temp-file "veritas-hacking-" t))
         (root (expand-file-name "project" parent)))
    (make-directory (expand-file-name "test/veritas/unit" root) t)
    (with-temp-file (expand-file-name "manifest.scm" root)
      (insert "(packages->manifest (list guile-3.0-latest))\n"))
    (when (memq 'launcher options)
      (make-directory (expand-file-name "bin" root) t)
      (let ((launcher (expand-file-name "bin/veritas" root)))
        (with-temp-file launcher (insert "#!/bin/sh\nexit 0\n"))
        (set-file-modes launcher #o755)))
    (when (memq 'vendored options)
      (veritas-test--checkout (expand-file-name "veritas" root)))
    (when (memq 'sibling options)
      (veritas-test--checkout (expand-file-name "veritas" parent)))
    root))

(defun veritas-test--forget-project (root)
  "Delete ROOT and the throwaway directory holding it."
  (delete-directory (file-name-directory (directory-file-name root)) t))

(defun veritas-test--guile-load-paths (command)
  "Return the directories COMMAND gives to Guile's `-L', in order."
  (let (directories)
    (while (setq command (cdr (member "-L" command)))
      (push (car command) directories))
    (nreverse directories)))

(ert-deftest veritas-test-default-command-prefers-the-project-launcher ()
  "A project's own `bin/veritas' is run, through Guix when it has a manifest."
  (let ((root (veritas-test--project 'launcher)))
    (unwind-protect
        (progn
          (veritas-test--detecting ("guix" "veritas")
            (should (equal (list "guix" "shell" "-m"
                                 (expand-file-name "manifest.scm" root)
                                 "--" (expand-file-name "bin/veritas" root))
                           (veritas--default-command root))))
          ;; Without Guix the launcher is used as it stands, and a `veritas'
          ;; on PATH never takes its place.
          (veritas-test--detecting ("veritas")
            (should (equal (list (expand-file-name "bin/veritas" root))
                           (veritas--default-command root)))))
      (veritas-test--forget-project root))))

(ert-deftest veritas-test-default-command-uses-guile-for-the-cli ()
  "A project without a launcher gets the CLI module, not bare Guile."
  (let ((root (veritas-test--project)))
    (unwind-protect
        (progn
          (veritas-test--detecting ("guile" "guix")
            (let ((command (veritas--default-command root)))
              (should (equal "guix" (car command)))
              (should (member "guile" command))
              (should (equal (list "-c" veritas--cli-program "--")
                             (last command 3)))
              ;; The flags are never handed to Guile itself to parse.
              (should-not (member "--reporter" command))
              ;; The project's own directories are searchable, and the ones
              ;; that are not there are left out.
              (should (member root command))
              (should (member (expand-file-name "test" root) command))
              (should-not (member (expand-file-name "src" root) command))))
          ;; Without a manifest there is no shell to enter, but the rest is
          ;; the same.
          (delete-file (expand-file-name "manifest.scm" root))
          (veritas-test--detecting ("guile" "guix")
            (should (equal (list "guile" "-L" root "-L"
                                 (expand-file-name "test" root)
                                 "-c" veritas--cli-program "--")
                           (veritas--default-command root)))))
      (veritas-test--forget-project root))))

(ert-deftest veritas-test-default-command-finds-a-local-checkout ()
  "With Guile but no Guix, a nearby Veritas checkout is used."
  (dolist (layout '((vendored) (sibling)))
    (let* ((root (apply #'veritas-test--project layout))
           (checkout (expand-file-name (if (memq 'sibling layout)
                                           "../veritas" "veritas")
                                       root)))
      (unwind-protect
          (progn
            (veritas-test--detecting ("guile")
              (let ((command (veritas--default-command root)))
                ;; No Guix anywhere: Guile runs the CLI module itself.
                (should (equal "guile" (car command)))
                (should-not (member "guix" command))
                (should-not (member "shell" command))
                ;; The checkout is on the load path, last, so that it wins for
                ;; the library's own module names.
                (should (equal (expand-file-name "src" checkout)
                               (car (last (veritas-test--guile-load-paths
                                           command)))))
                (should (equal (list "-c" veritas--cli-program "--")
                               (last command 3))))))
        (veritas-test--forget-project root)))))

(ert-deftest veritas-test-checkout-can-be-named ()
  "A named checkout is used, and it outranks the ones lying near the project."
  (let* ((root (veritas-test--project 'vendored 'sibling))
         (parent (file-name-directory (directory-file-name root)))
         (vendored (expand-file-name "src" (expand-file-name "veritas" root)))
         (sibling (expand-file-name "src" (expand-file-name "../veritas" root)))
         (relative "named-checkout")
         (named (expand-file-name
                 "src" (veritas-test--checkout
                        (expand-file-name relative parent)))))
    (unwind-protect
        (progn
          ;; The manifest provides Veritas, so nothing beside or inside the
          ;; project is looked for on its own; only the name reaches one.
          (veritas-test--detecting ("guile" "guix")
            (should-not (member vendored (veritas--default-command root)))
            (let ((veritas-checkout (expand-file-name relative parent)))
              (should (member named (veritas--default-command root)))))
          ;; Named, it is the first directory of the load path -- the last
          ;; `-L', which is the one Guile searches first -- ahead of the
          ;; checkout the project carries and the one it sits beside.
          (veritas-test--detecting ("guile")
            (let ((veritas-checkout (expand-file-name relative parent)))
              (let ((searched (reverse (veritas-test--guile-load-paths
                                        (veritas--default-command root)))))
                (should (equal (list named vendored) (seq-take searched 2)))
                (should (member sibling searched)))))
          ;; Left to itself, the checkout the project carries wins over the one
          ;; beside it: what the project holds is what it was written against.
          (veritas-test--detecting ("guile")
            (let ((searched (reverse (veritas-test--guile-load-paths
                                      (veritas--default-command root)))))
              (should (equal (list vendored sibling) (seq-take searched 2))))))
      (veritas-test--forget-project root))))

;;; The preflight of a run's checkout

(ert-deftest veritas-test-probe-command-keeps-the-load-path ()
  "A probe is the run's own command with an import in place of its program."
  (let ((root (veritas-test--fixture-root)))
    (veritas-test--detecting ("guile")
      (let* ((command (veritas--default-command root))
             (probe (veritas--probe-command command)))
        (should probe)
        (should (equal "guile" (car probe)))
        (should (equal (veritas-test--guile-load-paths command)
                       (veritas-test--guile-load-paths probe)))
        (should (equal (list "-c" veritas--import-program) (last probe 2)))))))

(ert-deftest veritas-test-probe-command-leaves-wrappers-alone ()
  "A wrapper, an installed `veritas' and a bare Guile are not probed."
  (dolist (command (list (append (list "guix" "shell" "-m" "manifest.scm" "--")
                                 (list "guile" "-c" veritas--cli-program "--"))
                         (list "veritas" "--reporter" "json-reporter")
                         (list "/project/bin/veritas")
                         (list "guile" "-L" "/project")))
    (should-not (veritas--probe-command command))))

(ert-deftest veritas-test-probe-message-names-the-missing-module ()
  "Guile's report of a module it could not find is turned into advice."
  (let ((dependency (veritas--probe-message
                     (concat "Backtrace:\nIn procedure resolve-interface:\n"
                             veritas--missing-module-prefix "fibers)\n")))
        (library (veritas--probe-message
                  (concat veritas--missing-module-prefix "veritas cli)\n")))
        (other (veritas--probe-message "Backtrace:\nsomething went wrong\n")))
    (should (string-match-p "(fibers)" dependency))
    (should (string-match-p "veritas-guile-load-path" dependency))
    (should (string-match-p "(veritas cli)" library))
    (should (string-match-p "veritas-checkout" library))
    (should (string-match-p "something went wrong" other))))

(ert-deftest veritas-test-preflight-reports-a-missing-program ()
  "A program that is not on PATH is a reason not to start."
  (let ((root (veritas-test--fixture-root)))
    (veritas-test--detecting ()
      (let ((reasons (veritas--preflight root '("no-such-veritas") nil)))
        (should (seq-find (lambda (reason) (string-match-p "not on PATH" reason))
                          reasons))))))

(ert-deftest veritas-test-preflight-reports-a-checkout-that-is-not-one ()
  "A named `veritas-checkout' that holds no CLI is said to hold none."
  (let ((root (veritas-test--fixture-root))
        (named (make-temp-file "veritas-not-a-checkout-" t)))
    (unwind-protect
        (veritas-test--detecting ("guile")
          ;; Nothing to probe once the named checkout is known to be no
          ;; checkout at all.
          (cl-letf (((symbol-function 'call-process)
                     (lambda (&rest _) (error "no probe was needed"))))
            (let ((veritas-checkout named))
              (let ((reasons (veritas--preflight root
                                                 (veritas--default-command root)
                                                 nil)))
                (should (seq-find (lambda (reason)
                                    (string-match-p "not a checkout" reason))
                                  reasons))))))
      (delete-directory named t))))

(ert-deftest veritas-test-preflight-passes-a-checkout-that-imports ()
  "A probe that exits cleanly leaves nothing to report."
  (let ((root (veritas-test--fixture-root)))
    (veritas-test--detecting ("guile")
      (cl-letf (((symbol-function 'call-process) (lambda (&rest _) 0)))
        (should-not (veritas--preflight root (veritas--default-command root) nil))))))

(ert-deftest veritas-test-preflight-refuses-a-checkout-that-cannot-import ()
  "The module a broken checkout fails on is named, and the run refused."
  (let ((root (veritas-test--fixture-root))
        (probe nil))
    (veritas-test--detecting ("guile")
      (let ((command (veritas--default-command root)))
        (cl-letf (((symbol-function 'call-process)
                   (lambda (program _infile destination _display &rest args)
                     (setq probe (cons program args))
                     (with-current-buffer (car destination)
                       (insert "Backtrace:\n")
                       (insert veritas--missing-module-prefix "fibers)\n"))
                     1)))
          (let ((reasons (veritas--preflight root command nil)))
            (should (= 1 (length reasons)))
            (should (string-match-p "(fibers)" (car reasons)))
            (should (equal (veritas--probe-command command) probe))))))))

(ert-deftest veritas-test-a-run-that-cannot-import-its-checkout-is-not-started ()
  "The report says why, instead of a run that fails for no visible reason."
  (let* ((root (veritas-test--fixture-root))
         (veritas-command (list "guile" "-L" root "-c" veritas--cli-program "--"))
         (veritas-pop-to-report nil)
         (veritas-show-report 'never)
         (run nil))
    (cl-letf (((symbol-function 'call-process)
               (lambda (_program _infile destination &rest _args)
                 (with-current-buffer (car destination)
                   (insert veritas--missing-module-prefix "fibers)\n"))
                 1)))
      (setq run (veritas--start root (veritas--run-flags root '("--no-benchmarks"))))
      (should-not (veritas-running-p run))
      (should (equal 'failed (veritas--run-status run)))
      (should-not (veritas--run-process run))
      (should-not (veritas--run-exit run))
      (let ((text (with-current-buffer (veritas--run-buffer run) (buffer-string))))
        (should (string-match-p "the run did not start" text))
        (should (string-match-p "(fibers)" text))
        ;; What would have run is still there to read.
        (should (string-match-p "guile" text))))))

(ert-deftest veritas-test-a-raw-run-that-cannot-import-is-not-started ()
  "The escape hatch says why instead of leaving a backtrace to read."
  (let* ((root (veritas-test--fixture-root))
         (default-directory (file-name-as-directory root))
         (veritas-command (list "guile" "-L" root "-c" veritas--cli-program "--")))
    (cl-letf (((symbol-function 'call-process)
               (lambda (_program _infile destination _display &rest _args)
                 (with-current-buffer (car destination)
                   (insert veritas--missing-module-prefix "fibers)\n"))
                 1)))
      (should-not (veritas-run-raw))
      (should-not veritas--raw-process)
      (let ((text (with-current-buffer (get-buffer veritas-log-buffer-name)
                    (buffer-string))))
        (should (string-match-p "veritas: Guile cannot find the module (fibers)" text))
        ;; What would have run is still there to read.
        (should (string-match-p "\\$ guile" text))))))

(ert-deftest veritas-test-preflight-can-be-turned-off ()
  "With `veritas-preflight' nil nothing is probed and the run starts."
  (let* ((root (veritas-test--fixture-root))
         (veritas-command '("sh" "-c" "exit 0"))
         (veritas-preflight nil)
         (veritas-pop-to-report nil)
         (veritas-show-report 'never)
         (run nil))
    (cl-letf (((symbol-function 'call-process)
               (lambda (&rest _) (error "nothing should have been probed"))))
      (setq run (veritas--start root (veritas--run-flags root '("--no-benchmarks"))))
      (let ((deadline (+ (float-time) 30)))
        (while (and (veritas-running-p run) (< (float-time) deadline))
          (accept-process-output nil 0.1)))
      (should-not (veritas-running-p run))
      (should (equal 0 (veritas--run-exit run)))
      (should-not (veritas--run-fatal run)))))

(ert-deftest veritas-test-load-path-env-keeps-what-was-there ()
  "The run's `GUILE_LOAD_PATH' adds to what was asked for, never replaces it."
  (let ((root (veritas-test--project 'sibling)))
    (unwind-protect
        (veritas-test--detecting ("guile" "guix")
          (let* ((env (veritas--load-path-env
                       '(("GUILE_LOAD_PATH" . "/asked")) root))
                 (value (cdr (assoc "GUILE_LOAD_PATH" env))))
            (should (equal "/asked" (car (split-string value ":"))))
            (should (member root (split-string value ":")))
            (should (member (expand-file-name "test" root)
                            (split-string value ":")))
            ;; With Guix and a manifest, the library comes from the manifest,
            ;; so a checkout beside the project is left out.
            (should-not (member (expand-file-name "veritas/src" root)
                                (split-string value ":")))))
      (veritas-test--forget-project root))))

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
