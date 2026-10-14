;;; veritas.el --- Tight Emacs integration for the Veritas test framework -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Josep Bigorra <jjbigorra@gmail.com>

;; Author: Josep Bigorra <jjbigorra@gmail.com>
;; Maintainer: Josep Bigorra <jjbigorra@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: tools, lisp, scheme, languages
;; Homepage: https://jointhefreeworld.org

;; This file is not part of GNU Emacs.

;; veritas.el is free software: you can redistribute it and/or modify it under
;; the terms of the GNU Lesser General Public License as published by the Free
;; Software Foundation, either version 3 of the License, or (at your option) any
;; later version.

;; veritas.el is distributed in the hope that it will be useful, but WITHOUT ANY
;; WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
;; A PARTICULAR PURPOSE.  See the GNU Lesser General Public License for more
;; details.

;; You should have received a copy of the GNU Lesser General Public License
;; along with veritas.el.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This package gives Emacs a tight understanding of Veritas, the Guile Scheme
;; testing framework (see the Veritas manual, README.org in the Veritas
;; sources).  It does three things:
;;
;; 1. It teaches Emacs the language of a Veritas suite: `suite', `test',
;;    `benchmark', `scenario' and their BDD, table, container, double and
;;    snapshot companions are fontified, appear in the Imenu index, drive
;;    `which-function-mode', and can be run from point.
;;
;; 2. It runs the Veritas CLI for you, from the project, the current file, the
;;    test, suite, tag or benchmark at point, or just what failed last time.
;;
;; 3. It reports the run in a dedicated buffer that is built from the runner's
;;    JSON event stream and cross-referenced with the sources: every test and
;;    assertion is a link to its own definition, failures are collected at the
;;    top with their expected/got detail, tests that did not run are shown as
;;    such, and the whole thing is navigable with `next-error'.
;;
;; The runner is invoked with its `json-reporter', which is what makes the
;; structured report possible; `veritas-run-raw' runs the project's own
;; reporter instead and shows its output in a plain log buffer.
;;
;; Use `veritas-dispatch' (bound to `C-c v' in Veritas buffers) or the
;; individual `veritas-run-*' commands.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'json)
(require 'imenu)
(require 'easymenu)
(require 'simple)
;; Needed for `scheme-mode-syntax-table', which is what makes the definition
;; scanner aware of Scheme strings and comments.
(require 'scheme)

(defconst veritas-version "0.1.0"
  "Version of this package.")

(defgroup veritas nil
  "Run and report Veritas (Guile Scheme) test suites."
  :group 'tools
  :prefix "veritas-")

;;; Customization

(defcustom veritas-command nil
  "Command used to run the Veritas CLI, as a list of strings.\n\nThe list is the program and its leading arguments; the CLI flags are appended\nto it, so the default `(\"guix\" \"shell\" \"-m\" \"manifest.scm\" \"--\")'\nwould run a Veritas installed in the project's manifest.\n\nWhen nil, the command is detected: a `bin/veritas' inside the project is\npreferred (wrapped in `guix shell' when the project has a `manifest.scm' and\nGuix is installed, which is how the Veritas sources ask to be run), falling\nback to a `veritas' executable on `PATH'.\n\nThis may also be a function taking the project root and returning such a\nlist."
  :type '(choice (const :tag "Detect automatically" nil)
                 (repeat string)
                 (function :tag "Function of the project root"))
  :group 'veritas)

(defcustom veritas-run-flags nil
  "Extra flags appended to every Veritas run.\n\nUseful for flags this package does not model, such as `--partition'."
  :type '(repeat string)
  :group 'veritas)

(defcustom veritas-test-type "unit"
  "Test category the runner loads, as `--test-type'.\n\nVeritas looks for test files under `VERITAS_TEST_TOP_DIR/VERITAS_TEST_MODULE/\nFROM THIS VALUE', and this package resolves the files the runner reports\nrelative to the same directory, so the two must agree."
  :type 'string
  :group 'veritas)

(defcustom veritas-test-module "veritas"
  "Top level module prefix of the tests, as `--test-module'.\n\nWhen the project has a single directory under `veritas-test-top-dir', that\ndirectory's name is detected and used instead, so most projects need not set\nthis."
  :type 'string
  :group 'veritas)

(defcustom veritas-test-top-dir "test"
  "Directory holding the test hierarchy, as `--test-top-dir'."
  :type 'string
  :group 'veritas)

(defcustom veritas-entrypoint "spec"
  "No-argument function called in each test file, as `--entrypoint'."
  :type 'string
  :group 'veritas)

(defcustom veritas-scan-dir nil
  "Root directory to scan for tests, as `--scan-dir'.\n\nWhen nil the project root is used, which is where the runner is invoked from\nand therefore its default."
  :type '(choice (const :tag "Project root" nil) directory)
  :group 'veritas)

(defcustom veritas-jobs nil
  "Number of worker processes the runner should use, as `--jobs'.\n\nnil leaves the runner's own default, which runs the files in this process."
  :type '(choice (const :tag "Runner default" nil) integer)
  :group 'veritas)

(defcustom veritas-seed nil
  "Seed fixing every shuffle of the run, as `--seed'.\n\nnil draws a fresh seed, which the runner then reports so the order can be\nreplayed."
  :type '(choice (const :tag "Fresh seed" nil) integer)
  :group 'veritas)

(defcustom veritas-shuffle nil
  "Whether the runner shuffles the discovered files and the tasks.\n\nRandom order finds order-dependent bugs, so Veritas itself defaults to\nshuffling; this package defaults to a fixed order because a report that moves\nbetween runs is harder to read.  Set it to t to let the order vary, and set\n`veritas-seed' to replay a failing order."
  :type 'boolean
  :group 'veritas)

(defcustom veritas-run-benchmarks t
  "Whether benchmarks are run, as `--benchmarks' and `--no-benchmarks'.\n\nBenchmarks are measured with Guile's statistical profiler and are slow, so\nskipping them gives a much faster feedback loop."
  :type 'boolean
  :group 'veritas)

(defcustom veritas-env nil
  "Extra environment variables for the runner, as a list of name/value pairs.\n\nEach element is a cons of a string name and a string value, for example\n`((\"VERITAS_SNAPSHOT_DIR\" . \"test/snapshots\"))'."
  :type '(alist :key-type string :value-type string)
  :group 'veritas)

(defcustom veritas-report-buffer-name "*veritas*"
  "Name of the structured report buffer."
  :type 'string
  :group 'veritas)

(defcustom veritas-log-buffer-name "*veritas log*"
  "Name of the raw output log buffer."
  :type 'string
  :group 'veritas)

(defcustom veritas-report-show-passed nil
  "Whether the report lists the assertions of a passing test.\n\nWhen nil only failing assertions are listed, which keeps a green run short;\n`veritas-results-toggle-passed' flips it for the current report."
  :type 'boolean
  :group 'veritas)

(defcustom veritas-report-show-output nil
  "Whether the report shows the raw output a test file produced.\n\nThe output is the text the runner printed that was not part of its JSON event\nstream, such as `display' calls in a test."
  :type 'boolean
  :group 'veritas)

(defcustom veritas-show-report 'on-failure
  "When the report buffer is shown.\n\n`on-failure' shows it when the run failed, `always' shows it whenever a run\nfinishes, and `never' only updates it in the background."
  :type '(choice (const :tag "When the run fails" on-failure)
                 (const :tag "After every run" always)
                 (const :tag "Never" never))
  :group 'veritas)

(defcustom veritas-pop-to-report t
  "Whether starting a run selects the report buffer immediately.\n\nThe report fills in while the run goes, so showing it early gives live\nfeedback; when nil it stays in the background until it finishes."
  :type 'boolean
  :group 'veritas)

(defcustom veritas-auto-enable t
  "Whether `veritas-mode' turns itself on in Veritas projects.\n\nWhen non-nil, `veritas-mode-maybe' is added to `scheme-mode-hook' and enables\nthe minor mode in any Scheme buffer that belongs to a detected Veritas\nproject."
  :type 'boolean
  :group 'veritas)

(defcustom veritas-mode-line-format " Veritas:%s"
  "Mode line indicator for `veritas-mode', or nil for none.\n\nThe `%s' is replaced by the name of the enclosing test, suite or benchmark."
  :type '(choice (const :tag "No indicator" nil) string)
  :group 'veritas)

(defcustom veritas-file-run-restricted t
  "Whether running a single test file scans a temporary tree of links.\n\nVeritas has no command line option selecting one test file, so this package\nbuilds a throwaway scan root containing a symbolic link to the file and points\nthe runner at it.  Set this to nil to run the whole project instead."
  :type 'boolean
  :group 'veritas)

;;; Faces

(defface veritas-pass-face
  '((t :inherit success))
  "Face used for passing tests and assertions."
  :group 'veritas)

(defface veritas-fail-face
  '((t :inherit error))
  "Face used for failing tests and assertions."
  :group 'veritas)

(defface veritas-error-face
  '((t :inherit error :weight bold))
  "Face used for a fatal error and for a run that aborted."
  :group 'veritas)

(defface veritas-skip-face
  '((t :inherit shadow))
  "Face used for skipped tests and benchmarks."
  :group 'veritas)

(defface veritas-not-run-face
  '((t :inherit shadow :slant italic))
  "Face used for tests that the run did not reach."
  :group 'veritas)

(defface veritas-suite-face
  '((t :inherit bold))
  "Face used for a suite name in the report."
  :group 'veritas)

(defface veritas-test-face
  '((t))
  "Face used for a test name in the report."
  :group 'veritas)

(defface veritas-benchmark-face
  '((t :inherit font-lock-constant-face))
  "Face used for a benchmark name in the report."
  :group 'veritas)

(defface veritas-assertion-face
  '((t :inherit shadow))
  "Face used for an assertion name in the report."
  :group 'veritas)

(defface veritas-file-face
  '((t :inherit bold :box nil))
  "Face used for a test file name in the report."
  :group 'veritas)

(defface veritas-summary-face
  '((t :inherit bold :height 1.1))
  "Face used for the report's headline."
  :group 'veritas)

(defface veritas-stat-face
  '((t :inherit shadow))
  "Face used for the counts and the command line of a report."
  :group 'veritas)

(defface veritas-link-face
  '((t :inherit link :underline nil))
  "Face used for an actionable link such as \"rerun failed\"."
  :group 'veritas)

(defface veritas-detail-face
  '((t :inherit shadow))
  "Face used for the expected/got detail of an assertion."
  :group 'veritas)

(defface veritas-definition-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face used for `suite', `test' and `benchmark' in Veritas sources."
  :group 'veritas)

(defface veritas-assert-face
  '((t :inherit font-lock-function-name-face))
  "Face used for the assertion and matcher names."
  :group 'veritas)

(defface veritas-step-face
  '((t :inherit font-lock-function-name-face :slant italic))
  "Face used for the given/when/then step names."
  :group 'veritas)

(defface veritas-runner-face
  '((t :inherit font-lock-preprocessor-face))
  "Face used for `veritas-run' and the other runner entry points."
  :group 'veritas)

(defface veritas-keyword-face
  '((t :inherit font-lock-builtin-face))
  "Face used for the `#:keyword' arguments of a Veritas form."
  :group 'veritas)

;;; Utilities

(defun veritas--stringify (value)
  "Return VALUE as a string, for values that may be numbers or booleans."
  (cond ((stringp value) value)
        ((null value) "")
        ((eq value t) "true")
        (t (format "%s" value))))

(defvar veritas--ansi-regexp "\033\\[[0-9;?]*[A-Za-z]"
  "Regular expression matching the terminal colour escapes Veritas emits.")

(defun veritas--strip-ansi (string)
  "Return STRING without terminal colour escapes and stray carriage returns."
  (thread-last string
               (replace-regexp-in-string veritas--ansi-regexp "")
               (replace-regexp-in-string "\r" "")))

(defun veritas--json-read (string)
  "Parse the JSON object in STRING, returning an alist of symbols, or nil."
  (condition-case nil
      (if (fboundp 'json-parse-string)
          (json-parse-string string :object-type 'alist :array-type 'list
                             :null-object nil :false-object nil)
        ;; `json-parse-string' needs native JSON support, so keep a path for
        ;; older builds that have only the Lisp reader.
        (let ((json-object-type 'alist)
              (json-array-type 'list)
              (json-null nil)
              (json-false nil))
          (json-read-from-string string)))
    (error nil)))

;;; Project detection
;;
;; A buffer belongs to a Veritas project when one of its parent directories
;; holds the runner's launcher, a `.veritas' marker, or the test hierarchy the
;; runner would discover.

(defun veritas--test-layout (&optional root)
  "Return the test layout of the project at ROOT as (BASE . MODULE), or nil.\n\nBASE is the directory the runner's discovered paths are relative to, that is\n`TEST_TOP_DIR/TEST_MODULE/TEST_TYPE' inside ROOT, and MODULE is the module\nprefix actually found, which is `veritas-test-module' unless the project has a\nsingle directory under `veritas-test-top-dir' and that name differs."
  (let* ((root (file-name-as-directory
                (expand-file-name (or root default-directory))))
         (top (expand-file-name veritas-test-top-dir root)))
    (when (file-directory-p top)
      (let* ((modules (seq-filter #'file-directory-p
                                  (directory-files
                                   top t directory-files-no-dot-files-regexp)))
             (preferred (expand-file-name veritas-test-module top))
             (module-dir (cond ((file-directory-p
                                 (expand-file-name veritas-test-type preferred))
                                preferred)
                               ((seq-find (lambda (dir)
                                            (file-directory-p
                                             (expand-file-name veritas-test-type dir)))
                                          modules)))))
        (when module-dir
          (cons (expand-file-name veritas-test-type module-dir)
                (file-name-nondirectory (directory-file-name module-dir))))))))

(defun veritas-project-p (dir)
  "Return non-nil when DIR looks like a Veritas project."
  (let ((dir (file-name-as-directory (expand-file-name dir))))
    (or (file-exists-p (expand-file-name "bin/veritas" dir))
        (file-exists-p (expand-file-name ".veritas" dir))
        (and (veritas--test-layout dir) t))))

(defun veritas-project-root (&optional dir)
  "Return the root of the Veritas project containing DIR, or nil.\n\nDIR defaults to `default-directory'.  The search walks up from DIR, so a test\nfile, a suite and the repository root all resolve to the same project."
  (let ((dir (file-name-as-directory
              (expand-file-name (or dir default-directory)))))
    (cl-loop for candidate = dir then (file-name-directory
                                       (directory-file-name candidate))
             while (and candidate (not (string-empty-p candidate)))
             when (veritas-project-p candidate)
             return (directory-file-name candidate)
             ;; Stop at the file system root instead of looping on "/".
             until (string-equal candidate
                                 (file-name-directory (directory-file-name candidate))))))

(defun veritas--resolve-test-file (relative layout)
  "Return the absolute path of RELATIVE, which the runner reported.\n\nLAYOUT is a (BASE . MODULE) pair as returned by `veritas--test-layout'.  The\nrunner reports paths relative to the directory holding the test files, not\nrelative to the project, which is what this reconciles."
  (when (and relative layout (car layout))
    (expand-file-name relative (car layout))))

;;; Command resolution

(defun veritas--default-command (root)
  "Return the Veritas command to use inside ROOT.\n\nThe project's own `bin/veritas' wins, because it pins the Veritas version the\nproject is written against; it is wrapped in `guix shell -m manifest.scm' when\nthe project has a manifest and Guix is installed, since that is how the Veritas\nsources ask to be run and it is the only way the runner's fiber and JSON\ndependencies are guaranteed to be present."
  (let ((launcher (expand-file-name "bin/veritas" root))
        (manifest (expand-file-name "manifest.scm" root)))
    (cond
     ((file-executable-p launcher)
      (if (and (executable-find "guix") (file-exists-p manifest))
          (list "guix" "shell" "-m" manifest "--" launcher)
        (list launcher)))
     ((executable-find "veritas") (list "veritas"))
     ((executable-find "guile")
      (list "guile" "-L" (expand-file-name "src" root)))
     (t (list "veritas")))))

(defun veritas--command (root)
  "Return the command list to run Veritas inside ROOT."
  (cond ((functionp veritas-command) (funcall veritas-command root))
        ((consp veritas-command) veritas-command)
        ((stringp veritas-command) (list veritas-command))
        (t (veritas--default-command root))))

(defun veritas--run-flags (root &optional extra no-benchmarks)
  "Return the CLI flags for a run in ROOT.\n\nEXTRA is appended last, so it can override what came before.  When\nNO-BENCHMARKS is non-nil the benchmarks are skipped whatever\n`veritas-run-benchmarks' says."
  (let ((layout (veritas--test-layout root))
        (benchmarks (if (or no-benchmarks (not veritas-run-benchmarks))
                        "--no-benchmarks" "--benchmarks")))
    (append (list "--reporter" "json-reporter"
                  "--test-type" veritas-test-type
                  "--test-top-dir" veritas-test-top-dir
                  "--test-module" (or (cdr layout) veritas-test-module)
                  "--entrypoint" veritas-entrypoint)
            (when veritas-scan-dir
              (list "--scan-dir" (expand-file-name veritas-scan-dir root)))
            (list (if veritas-shuffle "--shuffle" "--no-shuffle")
                  benchmarks)
            (when veritas-jobs (list "--jobs" (number-to-string veritas-jobs)))
            (when veritas-seed (list "--seed" (number-to-string veritas-seed)))
            veritas-run-flags
            extra)))

(defun veritas--ensure-directory (dir)
  "Create DIR and its parents unless they are already there."
  (unless (file-directory-p dir)
    (make-directory dir t)))

(defun veritas--file-run-overrides (file root)
  "Return (FLAGS ENV CLEANUP) restricting a run in ROOT to FILE, or nil.\n\nVeritas selects by name, never by file, so the only faithful way to run one\ntest file is to give the runner a scan root of its own.  A throwaway directory\nof symbolic links is built whose shape matches what the runner expects, and\n`GUILE_LOAD_PATH' is extended with the real test directory so the file's own\n`use-modules' still resolve."
  (let* ((layout (veritas--test-layout root))
         (base (car layout))
         (module (cdr layout))
         (top (expand-file-name veritas-test-top-dir root)))
    (when (and veritas-file-run-restricted
               layout
               (file-exists-p file)
               (string-prefix-p (file-name-as-directory base)
                                (file-name-as-directory
                                 (file-name-directory (expand-file-name file)))))
      (let* ((tmp (make-temp-file "veritas-file-" t))
             (target (expand-file-name
                      (concat veritas-test-top-dir "/" module "/"
                              veritas-test-type "/"
                              (file-relative-name file base))
                      tmp))
             (existing (getenv "GUILE_LOAD_PATH")))
        (veritas--ensure-directory (file-name-directory target))
        (make-symbolic-link file target)
        (list (list "--scan-dir" tmp)
              (list (cons "GUILE_LOAD_PATH"
                          (if (and existing (not (string-empty-p existing)))
                              (concat top ":" existing)
                            top)))
              tmp)))))

;;; The source model
;;
;; A Veritas source file is read into a tree of nodes, one per `suite',
;; `test', `benchmark' and so on.  Names and line numbers come from the tree
;; itself, which is what lets the report link back to a definition and lets
;; Imenu, `which-function-mode' and "run what is at point" share one parser.

(defconst veritas--group-keywords
  '("suite" "scenario" "feature" "story" "fabula" "scaena"
    "test-each" "suite-each" "with-container")
  "Veritas forms that group tests and other groups.")

(defconst veritas--test-keywords
  '("test"
    ;; A BDD step is an ordinary test under a prefixed name; see
    ;; `veritas--node-candidate-names'.
    "given" "when-step" "then" "and-step" "but-step"
    "Given" "When" "Then"
    "dato" "quando" "tunc" "etiam" "sed")
  "Veritas forms that hold assertions.")

(defconst veritas--unit-keywords (cons "benchmark" veritas--test-keywords)
  "Veritas forms that are reported as a test or a benchmark.")

(defconst veritas--test-types (mapcar #'intern veritas--test-keywords)
  "Node types the runner reports as tests.")

(defconst veritas--definition-regexp
  (concat "(\\("
          (regexp-opt (append veritas--group-keywords veritas--unit-keywords)
                      'symbols)
          "\\)")
  "Regular expression matching the head of a Veritas definition.\n\n`regexp-opt' puts the longest names first, so `test-each' is never read as\n`test', and outlines each name with symbol boundaries, so a name inside another\nword never matches.  Group 1 is the keyword.")

(cl-defstruct (veritas-node (:constructor veritas--make-node) (:copier nil))
              "A test, suite, benchmark or assertion."
              (type 'test :documentation "Source keyword, or `assert' for an assertion.")
              (name "" :documentation "The name the runner reports it under.")
              (status 'unknown :documentation "One of pass, fail, error, skip, not-run, running.")
              (start nil :documentation "Start of the form, as a buffer position of the scan.")
              (end nil :documentation "End of the form, as a buffer position of the scan.")
              (line nil :documentation "Line of the form, counted from one.")
              (depth 0 :documentation "Paren depth of the definition, for nesting.")
              (skip nil :documentation "Non-nil when the source declares `#:skip? #t'.")
              (file nil :documentation "Absolute path of the file the node came from.")
              (children nil :documentation "Nested groups, tests and assertions.")
              (parent nil :documentation "The enclosing node, or nil.")
              (collapsed nil :documentation "Non-nil when the report folds this group.")
              (matched nil :documentation "Non-nil once a result has been attached to it.")
              (messages nil :documentation "The pass/fail messages reported for it.")
              (output "" :documentation "Raw output the runner printed for it.")
              (duration nil :documentation "Seconds the runner reported for the file."))

(cl-defstruct (veritas-source (:constructor veritas--make-source) (:copier nil))
              "The definitions of one file."
              (file nil :documentation "Absolute path, or nil for an unsaved buffer.")
              (nodes nil :documentation "Top level definitions, in source order.")
              (index nil :documentation "Hash of definition name to a list of nodes."))

(defun veritas--in-string-or-comment-p (position)
  "Return non-nil when POSITION sits inside a string, comment or char literal."
  (let ((state (save-excursion (syntax-ppss position))))
    (or (nth 3 state) (nth 4 state))))

(defun veritas--read-name (&optional limit)
  "Return the name at point, advancing past it, or nil.\n\nA string literal is read as a string and anything else as a bare token, which\nis what a name computed at run time looks like."
  (cond
   ((looking-at "\"")
    (condition-case nil
        (progn (forward-sexp 1)
               (let* ((start (save-excursion (backward-sexp 1) (point)))
                      (raw (buffer-substring-no-properties start (point))))
                 (condition-case nil (read raw) (error raw))))
      (error nil)))
   ((looking-at "[^ \11\n()\"]")
    (let ((start (point)))
      (skip-chars-forward "^ \11\n()\"" limit)
      (buffer-substring-no-properties start (point))))
   (t nil)))

(defun veritas--form-name (start end)
  "Return the name of the Veritas form between START and END, or nil.\n\nThe name is the string that follows the form's head, or the value of a\n`#:name' argument, which is how `benchmark' spells it."
  (save-excursion
    (goto-char start)
    ;; Skip the opening paren and the head symbol.
    (forward-char 1)
    (skip-chars-forward "^ \11\n()" end)
    (catch 'name
      ;; The walk is bounded and every step has to make progress, so that a
      ;; malformed form can never turn the scan into a loop.
      (let ((budget 10000))
        (while (and (< (point) end) (> (setq budget (1- budget)) 0))
          (skip-chars-forward " \11\n" end)
          (cond
           ((>= (point) end) (throw 'name nil))
           ((looking-at "#:\\([[:alnum:]?!*<>=+/-]+\\)")
            (let ((key (match-string-no-properties 1)))
              (goto-char (match-end 0))
              (skip-chars-forward " \11\n" end)
              (if (string-equal key "name")
                  (throw 'name (veritas--read-name end))
                ;; Skip the value that belongs to this keyword.
                (goto-char (or (ignore-errors (scan-sexps (point) 1)) end)))))
           ((looking-at "\"")
            (throw 'name (veritas--read-name end)))
           ((looking-at "[)'`]")
            (throw 'name nil))
           (t (goto-char (or (ignore-errors (scan-sexps (point) 1)) end)))))))))

(defun veritas--scan-buffer (&optional file)
  "Return a `veritas-source' for the current buffer.\n\nFILE is recorded on the nodes so the report can jump to them.  A definition\nwhose name cannot be read, such as one produced by a table, is still recorded,\nwith whatever token stood in the name's place."
  (let ((case-fold-search nil)
        (definitions '()))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward veritas--definition-regexp nil t)
        (let ((head (match-string-no-properties 1))
              (keyword-start (match-beginning 1))
              (form-start (match-beginning 0)))
          (unless (veritas--in-string-or-comment-p keyword-start)
            (let* ((end (save-excursion
                          (goto-char form-start)
                          (condition-case nil (forward-sexp 1) (error nil))
                          (point)))
                   (body (and end (> end form-start)
                              (buffer-substring-no-properties form-start end))))
              (when (and end (> end form-start))
                (push (veritas--make-node
                       :type (intern head)
                       :name (or (veritas--form-name form-start end) head)
                       :start form-start
                       :end end
                       :line (line-number-at-pos form-start)
                       ;; `syntax-ppss' leaves point where it was asked
                       ;; about, which would restart the search forever.
                       :depth (save-excursion
                                (car (syntax-ppss form-start)))
                       :skip (and body
                                  (string-match-p "#:skip?[ \11\n]+#t" body)
                                  t)
                       :file file)
                      definitions)))))))
    (veritas--link-nodes (nreverse definitions) file)))

(defun veritas--link-nodes (definitions file)
  "Return a `veritas-source' for DEFINITIONS, ordered by position.\n\nA definition is nested inside the nearest preceding one at a shallower paren\ndepth, which is the same nesting Scheme's own reader sees."
  (let ((stack '())
        (index (make-hash-table :test #'equal))
        (roots '()))
    (dolist (node definitions)
      (let ((depth (veritas-node-depth node)))
        (while (and stack (>= (veritas-node-depth (car stack)) depth))
          (pop stack))
        (let ((parent (car stack)))
          (setf (veritas-node-parent node) parent)
          (if parent
              (push node (veritas-node-children parent))
            (push node roots))
          (push node stack)
          (puthash (veritas-node-name node)
                   (cons node (gethash (veritas-node-name node) index))
                   index))))
    (dolist (node definitions)
      (setf (veritas-node-children node) (nreverse (veritas-node-children node))))
    (veritas--make-source :file file :nodes (nreverse roots) :index index)))

(defvar veritas--file-source-cache (make-hash-table :test #'equal)
  "Cache of file names to (WRITE-TIME . `veritas-source').")

(defun veritas--file-source (file)
  "Return the `veritas-source' of FILE, scanning it only when it changed."
  (let* ((file (expand-file-name file))
         (cached (gethash file veritas--file-source-cache))
         (write-time (or (file-attribute-modification-time
                          (file-attributes file))
                         (current-time))))
    (if (and cached (equal (car cached) write-time))
        (cdr cached)
      (let ((source (when (and (file-readable-p file)
                               (not (file-directory-p file)))
                      (with-temp-buffer
                        (set-syntax-table scheme-mode-syntax-table)
                        (insert-file-contents file)
                        (veritas--scan-buffer file)))))
        (puthash file (cons write-time source) veritas--file-source-cache)
        source))))

(defvar-local veritas--buffer-source-cache nil
  "Cons of (MODIFICATION TICK . `veritas-source') for this buffer.")

(defun veritas--buffer-source ()
  "Return the `veritas-source' of the current buffer, rescanning when it changed."
  (let ((tick (buffer-chars-modified-tick)))
    (unless (and veritas--buffer-source-cache
                 (eq (car veritas--buffer-source-cache) tick))
      (let ((file (and buffer-file-name (expand-file-name buffer-file-name))))
        (setq veritas--buffer-source-cache
              (cons tick (veritas--scan-buffer file)))))
    (cdr veritas--buffer-source-cache)))

(defun veritas--all-nodes (source)
  "Return every definition of SOURCE, outermost first."
  (let ((acc '()))
    (cl-labels ((walk (node)
                  (push node acc)
                  (dolist (child (veritas-node-children node)) (walk child))))
               (dolist (node (veritas-source-nodes source)) (walk node)))
    (nreverse acc)))

(defun veritas--test-node-p (node)
  "Return non-nil when NODE is a test, including a BDD step."
  (memq (veritas-node-type node) veritas--test-types))

(defun veritas--unit-node-p (node)
  "Return non-nil when NODE is a test or a benchmark."
  (or (veritas--test-node-p node)
      (eq (veritas-node-type node) 'benchmark)))

(defun veritas--node-candidate-names (node)
  "Return the names the runner may report NODE under.\n\nA BDD step is a test named after its keyword, and the runner prefixes that\nkeyword when reporting the step, so both the plain name and the prefixed one\nare accepted.  A scenario is reported under a Scenario: prefix in the same\nway."
  (let ((name (veritas-node-name node)))
    (pcase (veritas-node-type node)
      ((or 'scenario 'feature 'story 'fabula 'scaena)
       (list (concat "Scenario: " name) name))
      ((or 'given 'dato) (list (concat "Given " name) name))
      ((or 'when-step 'quando) (list (concat "When " name) name))
      ((or 'then 'tunc) (list (concat "Then " name) name))
      ((or 'and-step 'etiam) (list (concat "And " name) name))
      ((or 'but-step 'sed) (list (concat "But " name) name))
      (_ (list name)))))

(defun veritas--group-node-p (node)
  "Return non-nil when NODE groups other definitions."
  (not (or (veritas--unit-node-p node)
           (eq (veritas-node-type node) 'assert))))

(defun veritas--node-at-point (&optional point)
  "Return the innermost definition containing POINT in the current buffer."
  (let ((point (or point (point)))
        (innermost nil))
    (dolist (node (veritas--all-nodes (veritas--buffer-source)))
      (when (and (veritas-node-start node)
                 (<= (veritas-node-start node) point)
                 (<= point (or (veritas-node-end node) point))
                 (or (null innermost)
                     (> (veritas-node-depth node)
                        (veritas-node-depth innermost))))
        (setq innermost node)))
    innermost))

(defun veritas--enclosing-nodes (point)
  "Return the definitions containing POINT, innermost first."
  (let ((nodes (veritas--all-nodes (veritas--buffer-source)))
        (result '()))
    (dolist (node nodes)
      (when (and (veritas-node-start node)
                 (<= (veritas-node-start node) point)
                 (<= point (or (veritas-node-end node) point)))
        (push node result)))
    (sort result (lambda (a b) (> (veritas-node-depth a)
                                  (veritas-node-depth b))))))

(defun veritas--node-path (node)
  "Return NODE and its ancestors, outermost first."
  (let ((path '()))
    (while node
      (push node path)
      (setq node (veritas-node-parent node)))
    path))

;;; The run

(cl-defstruct (veritas--run (:constructor veritas--make-run) (:copier nil))
              "One invocation of the Veritas CLI and everything it reported."
              (id nil)
              (root nil :documentation "Project root the runner was invoked in.")
              (command nil :documentation "Full argv, as a list of strings.")
              ;; Named `cli-flags' rather than `flags' because the accessor would
              ;; otherwise collide with `veritas--run-flags', which builds them.
              (cli-flags nil :documentation "Just the Veritas flags, for reruns.")
              (layout nil :documentation "Test layout used to resolve the reported files.")
              (buffer nil :documentation "The structured report buffer.")
              (log-buffer nil :documentation "The raw output buffer.")
              (stderr-buffer nil :documentation "Where the runner's standard error goes.")
              (process nil)
              (partial "" :documentation "Bytes of the line being read, not yet terminated.")
              (timer nil :documentation "Pending debounced render.")
              (started nil :documentation "Time the run was started.")
              (ended nil :documentation "Time the run finished.")
              (exit nil :documentation "The process exit status, once there is one.")
              (status 'running :documentation "One of running, passed, failed, aborted.")
              (files nil :documentation "Per-file nodes, in the order the runner reached them.")
              (current-file nil)
              (current-suite nil)
              (current-test nil)
              (pending-assert nil :documentation "The assertion awaiting its pass or fail.")
              (bench-state nil :documentation "Where inside a benchmark report the stream is.")
              (pending-bench nil)
              (last-bench nil)
              (seed nil)
              (fatal nil :documentation "Messages that describe a failure of the run itself.")
              (discovered nil :documentation "Relative paths the runner said it found.")
              (env nil :documentation "Extra environment variables used.")
              (cleanup nil :documentation "Temporary directory to remove when done.")
              (analysis nil :documentation "Cached walk of the result tree, for rendering."))

(defvar veritas--runs nil
  "The runs of this Emacs session, newest first.")

(defvar veritas--last-run nil
  "The most recent run, which the rerun commands and the report buffer use.")

(defvar-local veritas--run nil
  "The run whose report this buffer shows.")

(defvar veritas--process-runs (make-hash-table :test #'eq)
  "Map of a live runner process to the `veritas--run' it belongs to.")

(defvar veritas--run-counter 0
  "Number of runs started, used to tell their buffers apart.")

(defun veritas-running-p (&optional run)
  "Return non-nil when RUN, by default the most recent run, is still going."
  (let ((run (or run veritas--last-run)))
    (and run (eq 'running (veritas--run-status run)))))

(defun veritas--kill (run)
  "Stop RUN's process, if it is still going, and clean up after it."
  (when (and run (veritas--run-process run))
    (let ((process (veritas--run-process run)))
      (when (memq (process-status process) '(run stop open listen))
        (delete-process process))
      (remhash process veritas--process-runs)
      (setf (veritas--run-process run) nil)))
  (when (veritas--run-timer run)
    (cancel-timer (veritas--run-timer run))
    (setf (veritas--run-timer run) nil))
  (when (and run (veritas--run-cleanup run))
    (ignore-errors (delete-directory (veritas--run-cleanup run) t))
    (setf (veritas--run-cleanup run) nil))
  run)

(defun veritas-kill (&optional quiet)
  "Stop the running test run, if there is one."
  (interactive)
  (let ((run veritas--last-run))
    (when (veritas-running-p run)
      (veritas--kill run)
      (setf (veritas--run-status run) 'aborted))
    (unless quiet (message "veritas: no run to stop"))))

(defun veritas--get-buffer (name reuse)
  "Return the buffer called NAME, reusing it when REUSE is non-nil."
  (if (and reuse (get-buffer name))
      (progn (with-current-buffer (get-buffer name)
               (let ((inhibit-read-only t)) (erase-buffer)))
             (get-buffer name))
    (generate-new-buffer name)))

(defun veritas--log-text (run text)
  "Append TEXT to RUN's raw output buffer, following it when it is displayed."
  (let ((buffer (veritas--run-log-buffer run)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let* ((inhibit-read-only t)
               (windows (get-buffer-window-list buffer nil t))
               (following (seq-filter (lambda (window)
                                        (= (window-point window) (point-max)))
                                      windows)))
          (goto-char (point-max))
          (insert text)
          (dolist (window following)
            (set-window-point window (point-max))))))))

(defun veritas--next-id ()
  "Return the identifier of the next run."
  (setq veritas--run-counter (1+ veritas--run-counter)))

(defun veritas--start (root flags &optional overrides)
  "Run Veritas in ROOT with FLAGS.\n\nOVERRIDES is a list of (EXTRA-FLAGS EXTRA-ENV CLEANUP) supplied by a command\nthat needs to narrow the run, as `veritas-run-file' does.  Returns the new run."
  (let* ((extra-flags (nth 0 overrides))
         (extra-env (nth 1 overrides))
         (cleanup (nth 2 overrides))
         (command (append (veritas--command root) flags extra-flags))
         (id (veritas--next-id))
         (reuse (and veritas--last-run
                     (not (veritas-running-p veritas--last-run))))
         (run (veritas--make-run
               :id id
               :root root
               :cli-flags flags
               :layout (veritas--test-layout root)
               :command command
               :env extra-env
               :cleanup cleanup
               :started (current-time))))
    (when (veritas-running-p veritas--last-run)
      (veritas--kill veritas--last-run)
      (setf (veritas--run-status veritas--last-run) 'aborted)
      (message "veritas: stopped the previous run"))
    (setf (veritas--run-buffer run)
          (veritas--get-buffer veritas-report-buffer-name reuse)
          (veritas--run-log-buffer run)
          (veritas--get-buffer veritas-log-buffer-name reuse)
          (veritas--run-stderr-buffer run)
          (get-buffer-create (format " *veritas-stderr-%s*" id)))
    (with-current-buffer (veritas--run-stderr-buffer run)
      (let ((inhibit-read-only t)) (erase-buffer)))
    (with-current-buffer (veritas--run-buffer run)
      (veritas-results-mode)
      (setq veritas--run run
            mode-line-process (list " [" (propertize "running"
                                                     'face 'veritas-stat-face)
                                    "]"))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (veritas--insert-header run)))
    (setq veritas--last-run run)
    (push run veritas--runs)
    (let ((process-environment
           (append (mapcar (lambda (pair)
                             (concat (car pair) "=" (cdr pair)))
                           (append veritas-env extra-env))
                   process-environment))
          (default-directory (file-name-as-directory root)))
      (setf (veritas--run-process run)
            (make-process
             :name (format "veritas-%s" id)
             :command command
             :buffer nil
             :filter #'veritas--filter
             :sentinel #'veritas--sentinel
             :stderr (veritas--run-stderr-buffer run)
             :connection-type 'pipe
             :coding 'utf-8
             :noquery t)))
    (puthash (veritas--run-process run) run veritas--process-runs)
    (when veritas-pop-to-report
      (veritas--display-report run))
    run))

(defun veritas--filter (process output)
  "Read what PROCESS printed, one line at a time, into its run."
  (let ((run (gethash process veritas--process-runs)))
    (when run
      (veritas--log-text run output)
      (let* ((text (concat (veritas--run-partial run) output))
             (lines (split-string text "\n"))
             (partial (car (last lines))))
        (setf (veritas--run-partial run) partial)
        (dolist (line (butlast lines))
          (veritas--handle-line run (string-remove-suffix "\r" line)))))))

(defun veritas--sentinel (process _event)
  "Finish the run PROCESS belonged to when it exits."
  (let ((run (gethash process veritas--process-runs)))
    (when (and run (memq (process-status process) '(exit signal)))
      (remhash process veritas--process-runs)
      (setf (veritas--run-exit run) (process-exit-status process)
            (veritas--run-process run) nil)
      ;; Whatever was printed without a final newline is still a line.
      (let ((partial (veritas--run-partial run)))
        (when (and partial (not (string-empty-p partial)))
          (veritas--handle-line run partial)))
      (setf (veritas--run-partial run) "")
      (veritas--finalize run))))

(defun veritas--schedule-render (run)
  "Arrange for RUN's report to be redrawn, at most every few events."
  (unless (veritas--run-timer run)
    (setf (veritas--run-timer run)
          (run-at-time 0.12 nil
                       (lambda ()
                         (when (veritas--run-buffer run)
                           (setf (veritas--run-timer run) nil)
                           (veritas--render run)))))))

(defun veritas--elapsed (run)
  "Return how long RUN took, as a number of seconds."
  (let ((end (or (veritas--run-ended run) (current-time)))
        (start (veritas--run-started run)))
    (if start (float-time (time-subtract end start)) 0.0)))

;;; Reading the runner's output
;;
;; The runner is asked for its `json-reporter', so each event is one JSON
;; object on one line.  The lines around the events still matter: the runner
;; announces the file it is about to run in plain text, and that line is the
;; only thing that ties a test name to a file.

(defconst veritas--file-marker-regexp
  "\\`running \\(.+?\\) tests from file: \\(.+?\\)\\(?:, entrypoint: \\(.+\\)\\)?\\'"
  "Regular expression matching the runner's announcement of a test file.\n\nGroup 2 is the path relative to the test directory and group 3 the entry\npoint.  The repetitions are non-greedy so the test type stops at the words\nthat follow it.")

(defconst veritas--found-regexp
  "\\`found \\(.+?\\) tests: (\\(.*\\))\\'"
  "Regular expression matching the list of files the runner discovered.")

(defconst veritas--summary-regexp
  "\\`\\([0-9]+\\) files in \\([0-9]+\\) worker processes: .*\\'"
  "Regular expression matching the summary a parallel run ends with.")

(defun veritas--copy-node (node parent)
  "Return a copy of NODE, with PARENT as its parent.\n\nA fresh tree is copied for every run, because the nodes carry the results: a\nrerun that reused the cached parse would start out already failed."
  (let ((copy (veritas--make-node
               :type (veritas-node-type node)
               :name (veritas-node-name node)
               :start (veritas-node-start node)
               :end (veritas-node-end node)
               :line (veritas-node-line node)
               :depth (veritas-node-depth node)
               :skip (veritas-node-skip node)
               :file (veritas-node-file node)
               :parent parent)))
    (setf (veritas-node-children copy)
          (mapcar (lambda (child) (veritas--copy-node child copy))
                  (veritas-node-children node)))
    copy))

(defun veritas--file-node (relative file)
  "Return a fresh file node for RELATIVE, whose source lives at FILE."
  (let* ((node (veritas--make-node :type 'file :name relative :file file))
         (source (and file (veritas--file-source file))))
    (when source
      (setf (veritas-node-children node)
            (mapcar (lambda (child) (veritas--copy-node child node))
                    (veritas-source-nodes source))))
    node))

(defun veritas--node-kind-match-p (node kind)
  "Return non-nil when NODE may receive a result of KIND."
  (pcase kind
    ('group (veritas--group-node-p node))
    ('test (veritas--test-node-p node))
    ('benchmark (eq (veritas-node-type node) 'benchmark))
    (_ t)))

(defun veritas--take-node (container kind name)
  "Return the first unmatched node of KIND named NAME under CONTAINER.\n\nThe node is marked as matched, so a name that occurs twice feeds two results\nin the order they are reported."
  (let (found)
    (cl-labels ((walk (node)
                  (unless found
                    (when (and (not (veritas-node-matched node))
                               (member name (veritas--node-candidate-names node))
                               (veritas--node-kind-match-p node kind))
                      (setq found node))
                    (dolist (child (veritas-node-children node)) (walk child)))))
               (dolist (child (veritas-node-children container)) (walk child)))
    (when found (setf (veritas-node-matched found) t))
    found))

(defun veritas--synthetic-node (run type name)
  "Create a node for a result RUN reported that no source definition matches.\n\nNames computed at run time - a table collapsing `(format #f ...)' into a suite\nof its own - have no literal in the source, so they get a node of their own\nunder whatever group is open."
  (let* ((parent (or (veritas--run-current-suite run)
                     (veritas--run-current-file run)))
         (node (veritas--make-node :type type :name name :parent parent
                                   :file (and (veritas--run-current-file run)
                                              (veritas-node-file
                                               (veritas--run-current-file run)))
                                   :matched t)))
    (when parent
      (setf (veritas-node-children parent)
            (append (veritas-node-children parent) (list node))))
    node))

(defun veritas--begin-file (run relative)
  "Start the file node for RELATIVE, which RUN is about to run."
  (let* ((file (veritas--resolve-test-file relative (veritas--run-layout run)))
         (node (veritas--file-node relative file)))
    (setf (veritas-node-output node) "")
    (setf (veritas--run-pending-assert run) nil
          (veritas--run-current-test run) nil
          (veritas--run-current-suite run) nil
          (veritas--run-bench-state run) nil
          (veritas--run-last-bench run) nil)
    (setf (veritas--run-current-file run) node
          (veritas-node-status node) 'running)
    (setf (veritas--run-files run) (append (veritas--run-files run) (list node)))))

(defun veritas--on-suite (run name)
  "Handle the start of the suite NAME."
  (when (veritas--run-current-file run)
    (let ((node (or (veritas--take-node (veritas--run-current-file run) 'group name)
                    (veritas--synthetic-node run 'suite name))))
      (setf (veritas--run-current-suite run) node
            (veritas--run-current-test run) nil
            (veritas--run-pending-assert run) nil)
      node)))

(defun veritas--on-test (run name)
  "Handle the start of the test or benchmark NAME."
  (when (veritas--run-current-file run)
    (let ((node (or (veritas--take-node (veritas--run-current-file run) 'test name)
                    (veritas--synthetic-node run 'test name))))
      (setf (veritas-node-status node) 'pass
            (veritas--run-current-test run) node
            (veritas--run-pending-assert run) nil)
      node)))

(defun veritas--assertion-node (run name)
  "Return a fresh assertion node named NAME under the current test."
  (let* ((test (veritas--run-current-test run))
         (siblings (and test (veritas-node-children test)))
         (anonymous (format "assertion %d"
                            (1+ (seq-count (lambda (node)
                                             (eq (veritas-node-type node) 'assert))
                                           siblings))))
         (node (veritas--make-node :type 'assert
                                   :name (or name anonymous)
                                   :parent test
                                   :file (veritas-node-file (veritas--run-current-file run))
                                   :matched t)))
    (when test
      (setf (veritas-node-children test)
            (append (veritas-node-children test) (list node))))
    node))

(defun veritas--on-assert (run name)
  "Handle the announcement of the assertion NAME."
  (setf (veritas--run-pending-assert run) (veritas--assertion-node run name)))

(defun veritas--on-result (run status message)
  "Record STATUS and MESSAGE for the assertion that is open."
  (let ((node (or (veritas--run-pending-assert run)
                  ;; An assertion without a `#:name' announces nothing before
                  ;; its result, so one is made for it here.
                  (veritas--assertion-node run nil))))
    (setf (veritas--run-pending-assert run) nil
          (veritas-node-status node) status
          (veritas-node-messages node)
          (append (veritas-node-messages node) (list message)))
    (when (memq status '(fail error))
      ;; The failure of an assertion is the failure of every test, suite and
      ;; file it sits in, so the report can read it off the tree.
      (let ((parent (veritas-node-parent node)))
        (while parent
          (unless (eq (veritas-node-status parent) 'error)
            (setf (veritas-node-status parent) status))
          (setq parent (veritas-node-parent parent)))))))

(defun veritas--on-benchmark (run value)
  "Handle one of the events a benchmark report is made of.\n\nA benchmark emits its name, then a run index and the profiler's own report for\nthat run, once per run, all under the same level.  The name is the only string\nthat does not follow an index."
  (if (numberp value)
      (progn (setf (veritas--run-bench-state run) 'index)
             (let ((node (veritas--run-pending-bench run)))
               (when node
                 (setf (veritas-node-duration node)
                       (1+ (or (veritas-node-duration node) 0))))))
    (let ((text (veritas--stringify value)))
      (cond
       ((eq (veritas--run-bench-state run) 'index)
        (setf (veritas--run-bench-state run) 'details)
        (let ((node (veritas--run-pending-bench run)))
          (when node
            (setf (veritas-node-output node)
                  (concat (veritas-node-output node) text "\n")))))
       (t
        (setf (veritas--run-bench-state run) 'name)
        (let ((node (or (veritas--take-node (veritas--run-current-file run)
                                            'benchmark text)
                        (veritas--synthetic-node run 'benchmark text))))
          (setf (veritas-node-status node) 'pass
                (veritas-node-duration node) 0
                (veritas--run-pending-bench run) node)))))))

(defun veritas--record-file-duration (run seconds microseconds)
  "Note that the file RUN is on took SECONDS and MICROSECONDS."
  (let ((file (veritas--run-current-file run)))
    (when file
      (setf (veritas-node-duration file)
            (+ seconds (/ microseconds 1000000.0))))))

(defconst veritas--timing-regexp
  "\\`ran \\([0-9]+\\) tasks in: \\([0-9]+\\) seconds, \\([0-9]+\\) microseconds"
  "Regular expression matching the line a file ends its run with.")

(defun veritas--on-info (run message)
  "Read the seed and the timings out of an informational MESSAGE."
  (let ((text (veritas--stringify message)))
    (cond
     ((string-match "shuffled with seed \\([0-9]+\\)" text)
      (setf (veritas--run-seed run) (string-to-number (match-string 1 text))))
     ((string-match veritas--timing-regexp text)
      (veritas--record-file-duration run
                                     (string-to-number (match-string 2 text))
                                     (string-to-number (match-string 3 text)))))))

(defun veritas--handle-event (run line)
  "Handle one JSON event LINE of RUN."
  (let* ((object (veritas--json-read line))
         (level (and object (veritas--stringify (alist-get 'level object))))
         (message (and object (alist-get 'message object))))
    (pcase level
      ("suite" (veritas--on-suite run (veritas--stringify message)))
      ("test" (veritas--on-test run (veritas--stringify message)))
      ("assert" (veritas--on-assert run (veritas--stringify message)))
      ("pass" (veritas--on-result run 'pass (veritas--stringify message)))
      ("fail" (veritas--on-result run 'fail (veritas--stringify message)))
      ("skip" (veritas--on-result run 'skip (veritas--stringify message)))
      ("benchmark" (veritas--on-benchmark run message))
      ("info" (veritas--on-info run message))
      ("error" (push (string-trim (veritas--stringify message))
                     (veritas--run-fatal run)))
      ("debug" nil)
      ("warn" (push (veritas--stringify message) (veritas--run-fatal run)))
      (_ (veritas--log-text run (concat line "\n"))))
    (veritas--schedule-render run)))

(defun veritas--handle-line (run line)
  "Handle one line of RUN's standard output."
  (let ((text (string-trim-right line)))
    (cond
     ((string-empty-p text) nil)
     ((string-match veritas--file-marker-regexp text)
      (veritas--begin-file run (match-string 2 text))
      (veritas--schedule-render run))
     ((string-match veritas--found-regexp text)
      (setf (veritas--run-discovered run)
            (split-string (match-string 2 text) "[ \11\n]+" t)))
     ((string-prefix-p "{" text)
      (veritas--handle-event run text))
     ((string-match veritas--summary-regexp text) nil)
     ((string-match "\\`finished running tests\\'" text) nil)
     ((string-match "\\`scanning " text) nil)
     (t
      ;; Anything else is the test file's own output.  Keeping it lets the
      ;; report show it on request without inventing a second log format.
      (let ((file (veritas--run-current-file run)))
        (when file
          (setf (veritas-node-output file)
                (concat (veritas-node-output file) text "\n"))))))))

(defun veritas--stderr-text (run)
  "Return what RUN's standard error produced, as a string."
  (let ((buffer (veritas--run-stderr-buffer run)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer (string-trim (buffer-string))))))

(defun veritas--mark-unrun (node)
  "Flag NODE and its descendants as not having produced a result."
  (when (and (not (veritas-node-matched node))
             (not (eq (veritas-node-type node) 'file)))
    (when (veritas--unit-node-p node)
      (setf (veritas-node-status node) (if (veritas-node-skip node) 'skip 'not-run)))
    (dolist (child (veritas-node-children node)) (veritas--mark-unrun child))))

(defun veritas--finalize (run)
  "Finish RUN: settle its status, fill in what did not run, and draw it."
  (setf (veritas--run-ended run) (current-time))
  (when (veritas--run-timer run)
    (cancel-timer (veritas--run-timer run))
    (setf (veritas--run-timer run) nil))
  (let ((exit (veritas--run-exit run)))
    (setf (veritas--run-status run)
          (cond ((null exit) 'aborted)
                ((zerop exit) (if (veritas--run-fatal run) 'failed 'passed))
                (t 'failed))))
  ;; A run that never got as far as reporting a file should say why.
  (unless (veritas--run-files run)
    (let ((stderr (veritas--stderr-text run)))
      (when (and stderr (not (string-empty-p stderr)))
        (push stderr (veritas--run-fatal run)))))
  (dolist (file (veritas--run-files run))
    (veritas--mark-unrun file))
  ;; Files that were discovered but never reached are part of the report too:
  ;; a run that quietly skipped a file is exactly what one wants to see.
  (let ((unstarted (seq-remove
                    (lambda (relative)
                      (seq-find (lambda (node)
                                  (string-equal relative (veritas-node-name node)))
                                (veritas--run-files run)))
                    (veritas--run-discovered run))))
    (dolist (relative unstarted)
      (let ((node (veritas--file-node relative
                                      (veritas--resolve-test-file
                                       relative (veritas--run-layout run)))))
        (setf (veritas-node-status node) 'not-run)
        (veritas--mark-unrun node)
        (setf (veritas--run-files run)
              (append (veritas--run-files run) (list node))))))
  (setf (veritas--run-analysis run) nil)
  (veritas--render run)
  (veritas--maybe-display-report run)
  (when (veritas--run-cleanup run)
    (ignore-errors (delete-directory (veritas--run-cleanup run) t))
    (setf (veritas--run-cleanup run) nil))
  run)

(defun veritas--maybe-display-report (run)
  "Show RUN's report when the user asked for it."
  (let ((buffer (veritas--run-buffer run)))
    (when (buffer-live-p buffer)
      (when (and (or (eq veritas-show-report 'always)
                     (and (eq veritas-show-report 'on-failure)
                          (not (eq (veritas--run-status run) 'passed))))
                 (not (get-buffer-window buffer t)))
        (pop-to-buffer buffer)))))

(defun veritas--display-report (run)
  "Select RUN's report buffer, creating it if the run has not drawn it yet."
  (let ((buffer (veritas--run-buffer run)))
    (when (buffer-live-p buffer)
      (pop-to-buffer buffer)
      (when (= (point-min) (point-max))
        (let ((inhibit-read-only t)) (veritas--insert-header run))))))

;;; Reading the result tree
;;
;; The statuses recorded while the stream was read already carry the outcome of
;; every ancestor, so the report only has to walk the tree once to count things
;; and to work out what a collapsed group should say.

(defconst veritas--stat-tests 0)
(defconst veritas--stat-passed 1)
(defconst veritas--stat-failed 2)
(defconst veritas--stat-errors 3)
(defconst veritas--stat-skipped 4)
(defconst veritas--stat-not-run 5)
(defconst veritas--stat-assertions 6)
(defconst veritas--stat-failed-assertions 7)
(defconst veritas--stat-benchmarks 8)
(defconst veritas--stat-width 9)

(defun veritas--node-stats (node table)
  "Return the counters of NODE, read through TABLE as a memo."
  (or (gethash node table)
      (let ((stats (make-vector veritas--stat-width 0)))
        (cond
         ((veritas--unit-node-p node)
          (aset stats veritas--stat-tests 1)
          (when (eq (veritas-node-type node) 'benchmark)
            (aset stats veritas--stat-benchmarks 1))
          (pcase (veritas-node-status node)
            ('pass (aset stats veritas--stat-passed 1))
            ('fail (aset stats veritas--stat-failed 1))
            ('error (aset stats veritas--stat-errors 1))
            ('skip (aset stats veritas--stat-skipped 1))
            (_ (aset stats veritas--stat-not-run 1))))
         ((eq (veritas-node-type node) 'assert)
          (aset stats veritas--stat-assertions 1)
          (when (memq (veritas-node-status node) '(fail error))
            (aset stats veritas--stat-failed-assertions 1)))
         (t
          (dolist (child (veritas-node-children node))
            (let ((child-stats (veritas--node-stats child table)))
              (dotimes (index veritas--stat-width)
                (aset stats index (+ (aref stats index)
                                     (aref child-stats index))))))))
        (puthash node stats table)
        stats)))

(defun veritas--analysis (run)
  "Return (TOTALS . TABLE) for RUN, cached until the run is redrawn."
  (or (veritas--run-analysis run)
      (let ((table (make-hash-table :test #'eq))
            (totals (make-vector veritas--stat-width 0)))
        (dolist (file (veritas--run-files run))
          (let ((stats (veritas--node-stats file table)))
            (dotimes (index veritas--stat-width)
              (aset totals index (+ (aref totals index) (aref stats index))))))
        (setf (veritas--run-analysis run) (cons totals table)))))

(defun veritas--derived-status (node)
  "Return the status NODE should be shown with.\n\nA group says what its children say, in the order that matters: an error beats a\nfailure, a failure beats a pass, and a group nothing reported from is one that\ndid not run."
  (cond
   ((or (veritas--unit-node-p node) (eq (veritas-node-type node) 'assert))
    (veritas-node-status node))
   ((eq (veritas-node-status node) 'running) 'running)
   (t
    (let ((statuses (mapcar #'veritas--derived-status
                            (veritas-node-children node))))
      (cond ((memq 'error statuses) 'error)
            ((memq 'fail statuses) 'fail)
            ((memq 'running statuses) 'running)
            ((memq 'pass statuses) 'pass)
            ((memq 'skip statuses) 'skip)
            (t 'not-run))))))

(defun veritas--status-glyph (status)
  "Return the glyph and face used for STATUS."
  (pcase status
    ('pass (cons "\u2714" 'veritas-pass-face))
    ('fail (cons "\u2718" 'veritas-fail-face))
    ('error (cons "\u26a0" 'veritas-error-face))
    ('skip (cons "\u2298" 'veritas-skip-face))
    ('running (cons "\u2026" 'veritas-stat-face))
    (_ (cons "\u00b7" 'veritas-not-run-face))))

(defun veritas--unit-type-label (node)
  "Return what to call NODE in the report."
  (pcase (veritas-node-type node)
    ('test "test")
    ('benchmark "benchmark")
    ('assert "assertion")
    ('file "file")
    ('scenario "scenario")
    ('suite "suite")
    ((or 'given 'when-step 'then 'and-step 'but-step
         'Given 'When 'Then 'dato 'quando 'tunc 'etiam 'sed)
     "step")
    (_ (symbol-name (veritas-node-type node)))))

(defun veritas--node-face (node)
  "Return the face a node's name should be shown with."
  (pcase (veritas-node-type node)
    ((or 'test 'assert) 'veritas-test-face)
    ('benchmark 'veritas-benchmark-face)
    ('file 'veritas-file-face)
    ((or 'given 'when-step 'then 'and-step 'but-step
         'Given 'When 'Then 'dato 'quando 'tunc 'etiam 'sed)
     'veritas-step-face)
    ((or 'suite 'scenario 'feature 'story 'fabula 'scaena 'test-each 'suite-each)
     'veritas-suite-face)
    (_ 'veritas-suite-face)))

(defun veritas--node-position (node)
  "Return (FILE . LINE) for NODE, or nil.\n\nA node that a source definition did not produce - one a table generated at run\ntime, say - borrows the position of the nearest ancestor that has one."
  (let ((cursor node))
    (while (and cursor (not (and (veritas-node-file cursor)
                                 (veritas-node-line cursor))))
      (setq cursor (veritas-node-parent cursor)))
    (when cursor (cons (veritas-node-file cursor) (veritas-node-line cursor)))))

(defun veritas--node-path-names (node)
  "Return the names of NODE and its ancestors, outermost first."
  (delq nil (mapcar #'veritas-node-name (veritas--node-path node))))

(defun veritas--node-title (node)
  "Return the dotted path that names NODE in the report."
  (string-join (cdr (veritas--node-path-names node)) " \u203a "))

(defun veritas--failing-nodes (run)
  "Return every test and benchmark of RUN that failed, in report order."
  (let ((failures '()))
    (cl-labels ((walk (node)
                  (when (memq (veritas--derived-status node) '(fail error))
                    (when (veritas--unit-node-p node)
                      (push node failures))
                    (dolist (child (veritas-node-children node)) (walk child)))))
               (dolist (file (veritas--run-files run)) (walk file)))
    (nreverse failures)))

(defun veritas--failure-message (node)
  "Return the first failure message reported under NODE, or nil."
  (cl-labels ((walk (node)
                (cond
                 ((and (eq (veritas-node-type node) 'assert)
                       (memq (veritas-node-status node) '(fail error))
                       (veritas-node-messages node))
                  (car (veritas-node-messages node)))
                 (t (seq-some #'walk (veritas-node-children node))))))
             (walk node)))

(defun veritas--group-summary (stats)
  "Return a one-line count of STATS, for a group or a file."
  (let ((tests (aref stats veritas--stat-tests))
        (passed (aref stats veritas--stat-passed))
        (failed (aref stats veritas--stat-failed))
        (errors (aref stats veritas--stat-errors))
        (skipped (aref stats veritas--stat-skipped))
        (not-run (aref stats veritas--stat-not-run)))
    (when (> tests 0)
      (string-join
       (delq nil
             (list (format "%d passed" passed)
                   (and (> failed 0) (format "%d failed" failed))
                   (and (> errors 0) (format "%d errored" errors))
                   (and (> skipped 0) (format "%d skipped" skipped))
                   (and (> not-run 0) (format "%d not run" not-run))))
       ", "))))

;;; Drawing the report

(defun veritas--insert (text &rest properties)
  "Insert TEXT, applying PROPERTIES to it."
  (let ((start (point)))
    (insert text)
    (when properties (add-text-properties start (point) properties))
    (point)))

(defun veritas--insert-section (title)
  "Insert a section heading for TITLE."
  (insert "\n" (propertize title 'face 'veritas-summary-face) "\n"))

(defvar veritas--link-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'veritas-results-mouse-activate)
    (define-key map [mouse-2] #'veritas-results-mouse-activate)
    map)
  "Keymap making an actionable span respond to the mouse.")

(defvar veritas--name-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'veritas-results-mouse-goto)
    (define-key map [mouse-2] #'veritas-results-mouse-goto)
    (define-key map [mouse-3] #'veritas-results-mouse-run)
    map)
  "Keymap making a test's name respond to the mouse.")

(defun veritas--insert-link (label face action &optional help)
  "Insert LABEL as a link that calls ACTION when clicked."
  (let ((start (point)))
    (insert label)
    (add-text-properties start (point)
                         (list 'face face
                               'mouse-face 'highlight
                               'keymap veritas--link-keymap
                               'help-echo (or help "mouse-1: activate")
                               'veritas-action action))
    (point)))

(defun veritas--insert-path (node)
  "Insert the suite path leading to NODE, without NODE's own name."
  (let ((names (cdr (veritas--node-path-names node))))
    (insert (propertize (if names (concat (string-join names " \u203a ") " \u203a ")
                          "")
                        'face 'veritas-suite-face))))

(defun veritas--insert-node-name (node)
  "Insert NODE's name as a link to its definition."
  (let ((name (veritas-node-name node)))
    (veritas--insert name
                     'face (veritas--node-face node)
                     'mouse-face 'highlight
                     'keymap veritas--name-keymap
                     'help-echo "mouse-1: go to the definition, mouse-3: run it")))

(defun veritas--insert-fold (node)
  "Insert the fold arrow of the group NODE."
  (veritas--insert-link (if (veritas-node-collapsed node) "\u25b8 " "\u25be ")
                        'veritas-stat-face
                        (lambda () (veritas--toggle-node node))
                        "mouse-1: fold or unfold"))

(defun veritas--insert-output (node depth)
  "Insert the raw output NODE produced, indented by DEPTH."
  (let ((lines (split-string (or (veritas-node-output node) "") "\n" t)))
    (dolist (line lines)
      (insert (propertize (concat (make-string (* 2 depth) ?\s) line "\n")
                          'face 'veritas-detail-face)))))

(defun veritas--run-status-glyph (status)
  "Return the glyph and face used for a run in STATUS."
  (pcase status
    ('passed (cons "\u2714" 'veritas-pass-face))
    ('failed (cons "\u2718" 'veritas-fail-face))
    ('aborted (cons "\u26a0" 'veritas-error-face))
    ('running (cons "\u2026" 'veritas-stat-face))
    (_ (cons "\u00b7" 'veritas-stat-face))))

(defun veritas--status-label (status)
  "Return the word used for a run in STATUS."
  (pcase status
    ('running "running")
    ('passed "passed")
    ('failed "failed")
    ('aborted "aborted")
    (_ (symbol-name status))))

(defun veritas--stats-line (run totals)
  "Return the counts line of RUN's report, from its TOTALS."
  (let* ((files (length (veritas--run-files run)))
         (tests (- (aref totals veritas--stat-tests)
                   (aref totals veritas--stat-benchmarks)))
         (benchmarks (aref totals veritas--stat-benchmarks))
         (assertions (aref totals veritas--stat-assertions))
         (passed (aref totals veritas--stat-passed))
         (failed (aref totals veritas--stat-failed))
         (errors (aref totals veritas--stat-errors))
         (skipped (aref totals veritas--stat-skipped))
         (not-run (aref totals veritas--stat-not-run)))
    (string-join
     (delq nil
           (list (format "%d file%s" files (if (= files 1) "" "s"))
                 (and (> tests 0) (format "%d test%s" tests (if (= tests 1) "" "s")))
                 (and (> benchmarks 0)
                      (format "%d benchmark%s" benchmarks (if (= benchmarks 1) "" "s")))
                 (and (> assertions 0)
                      (format "%d assertion%s" assertions (if (= assertions 1) "" "s")))
                 (format "%d passed" passed)
                 (and (> failed 0) (format "%d failed" failed))
                 (and (> errors 0) (format "%d errored" errors))
                 (and (> skipped 0) (format "%d skipped" skipped))
                 (and (> not-run 0) (format "%d not run" not-run))
                 (format "%.2fs" (veritas--elapsed run))))
     " \u00b7 ")))

(defun veritas--command-line (run)
  "Return the descriptive line of RUN's report."
  (string-join
   (delq nil
         (list (and (veritas--run-seed run)
                    (format "seed %d" (veritas--run-seed run)))
               "json-reporter"
               (and veritas-test-type (format "%s" veritas-test-type))
               (and veritas-jobs (format "%d jobs" veritas-jobs))
               (abbreviate-file-name (veritas--run-root run))))
   " \u00b7 "))

(defun veritas--insert-header (run)
  "Insert the headline and the counts of RUN's report."
  (let* ((inhibit-read-only t)
         (analysis (veritas--analysis run))
         (status (veritas--run-status run))
         (glyph (veritas--run-status-glyph status)))
    (veritas--insert "Veritas  " 'face 'veritas-summary-face)
    (veritas--insert (format "%s %s" (car glyph) (veritas--status-label status))
                     'face (cdr glyph))
    (insert "   ")
    (veritas--insert-link "[rerun]" 'veritas-link-face
                          (lambda () (veritas--rerun run nil)))
    (insert " ")
    (veritas--insert-link "[rerun failed]" 'veritas-link-face
                          (lambda () (veritas--rerun run '("--only-failed"))))
    (insert " ")
    (veritas--insert-link "[raw log]" 'veritas-link-face
                          (lambda () (veritas--show-log run)))
    (insert "\n")
    (veritas--insert (veritas--stats-line run (car analysis)) 'face 'veritas-stat-face)
    (insert "\n")
    (veritas--insert (veritas--command-line run) 'face 'veritas-stat-face)
    (insert "\n")
    (veritas--insert (concat "$ " (mapconcat #'identity (veritas--run-command run) " "))
                     'face 'veritas-stat-face)
    (insert "\n")))

(defun veritas--insert-failures (run)
  "Insert the collected failures of RUN, each one a link."
  (let ((failures (veritas--failing-nodes run)))
    (when failures
      (veritas--insert-section (format "Failures (%d)" (length failures)))
      (dolist (node failures)
        (let ((start (point))
              (message (veritas--failure-message node))
              (location (veritas--node-position node)))
          (insert "  ")
          (veritas--insert (car (veritas--status-glyph
                                 (veritas--derived-status node)))
                           'face (cdr (veritas--status-glyph
                                       (veritas--derived-status node))))
          (insert " ")
          (veritas--insert-path node)
          (veritas--insert (veritas-node-name node)
                           'face (veritas--node-face node)
                           'keymap veritas--name-keymap
                           'mouse-face 'highlight)
          (insert "\n")
          (add-text-properties start (point) (list 'veritas-node node))
          (when (or message location)
            (veritas--insert
             (concat "     "
                     (if message message "")
                     (if (and message location) "  " "")
                     (if location
                         (format "%s:%s" (abbreviate-file-name (car location))
                                 (cdr location))
                       "")
                     "\n")
             'face 'veritas-detail-face)))))))

(defun veritas--visible-children (node)
  "Return the children of NODE the report should show.\n\nA test's assertions are only worth a line when they failed, unless the user\nasked to see the passing ones as well."
  (if (veritas--unit-node-p node)
      (seq-filter (lambda (child)
                    (or veritas-report-show-passed
                        (memq (veritas-node-status child) '(fail error))))
                  (veritas-node-children node))
    (veritas-node-children node)))

(defun veritas--insert-node (run node depth)
  "Insert NODE and its visible children into RUN's report at DEPTH."
  (let* ((line-start (point))
         (status (veritas--derived-status node))
         (glyph (veritas--status-glyph status))
         (table (cdr (veritas--analysis run)))
         (stats (gethash node table))
         (type (veritas-node-type node))
         (children (veritas--visible-children node)))
    (insert (make-string (* 2 depth) ?\s))
    (if (and children (not (eq status 'not-run)))
        (veritas--insert-fold node)
      ;; Keep the columns lined up where there is nothing to fold.
      (insert "   "))
    (veritas--insert (car glyph) 'face (cdr glyph))
    (insert " ")
    (veritas--insert-node-name node)
    (cond
     ((eq type 'file)
      (let ((summary (veritas--group-summary stats)))
        (when summary
          (insert "   ")
          (veritas--insert summary 'face 'veritas-stat-face))))
     ((eq type 'assert)
      (let ((message (string-join (veritas-node-messages node) "; ")))
        (when (not (string-empty-p message))
          (insert "  ")
          (veritas--insert message 'face 'veritas-detail-face))))
     ((and (veritas--unit-node-p node) (memq status '(fail error)))
      (let ((message (veritas--failure-message node)))
        (when message
          (insert "  ")
          (veritas--insert message 'face 'veritas-detail-face))))
     ((eq type 'benchmark)
      (insert "  ")
      (veritas--insert (format "%s run%s" (or (veritas-node-duration node) 0)
                               (if (eql 1 (veritas-node-duration node)) "" "s"))
                       'face 'veritas-detail-face))
     ((veritas--unit-node-p node) nil)
     (t
      (let ((summary (veritas--group-summary stats)))
        (when summary
          (insert "   ")
          (veritas--insert summary 'face 'veritas-stat-face)))))
    (insert "\n")
    (add-text-properties line-start (point) (list 'veritas-node node))
    (when (and veritas-report-show-output
               (or (eq type 'file) (eq type 'benchmark))
               (not (string-empty-p (or (veritas-node-output node) ""))))
      (veritas--insert-output node (1+ depth)))
    (unless (or (null children) (veritas-node-collapsed node))
      (dolist (child children)
        (veritas--insert-node run child (1+ depth))))))

(defun veritas--insert-tree (run)
  "Insert the file tree of RUN's report."
  (when (veritas--run-files run)
    (veritas--insert-section "Files")
    (dolist (file (veritas--run-files run))
      (veritas--insert-node run file 0))))

(defun veritas--insert-footer (run)
  "Insert what the run itself had to say, if anything."
  (let ((fatal (seq-remove #'string-empty-p (veritas--run-fatal run))))
    (when fatal
      (veritas--insert-section "The run itself reported")
      (dolist (message fatal)
        (veritas--insert (concat "  " message "\n") 'face 'veritas-error-face)))))

(defun veritas--node-at-position (position)
  "Return the report node at POSITION, or nil."
  (let ((position (if (or (eobp) (= position (point-max)))
                      (max (point-min) (1- position))
                    position)))
    (get-text-property position 'veritas-node)))

(defun veritas--goto-node (node)
  "Move point to the line of NODE in the report, returning non-nil when there."
  (goto-char (point-min))
  (let ((found nil))
    (while (and (not found) (not (eobp)))
      (if (eq (veritas--node-at-position (point)) node)
          (setq found (point))
        (forward-line 1)))
    (when found (goto-char found))))

(defun veritas--render (run)
  "Redraw RUN's report buffer in place, keeping point where it was."
  (let ((buffer (veritas--run-buffer run)))
    (when (buffer-live-p buffer)
      (let (point-node point-line)
        (with-current-buffer buffer
          (setq point-node (veritas--node-at-position (point))
                point-line (line-number-at-pos)))
        (with-current-buffer buffer
          (setf (veritas--run-analysis run) nil)
          (let ((inhibit-read-only t))
            (save-excursion
              (erase-buffer)
              (condition-case error
                  (progn
                    (veritas--insert-header run)
                    (veritas--insert-failures run)
                    (veritas--insert-tree run)
                    (veritas--insert-footer run))
                (error
                 ;; A half-read stream must not take the buffer down with it.
                 (insert (format "\nveritas: could not draw the report: %s\n"
                                 (error-message-string error)))))))
          (setq mode-line-process
                (list " [" (propertize (veritas--status-label
                                        (veritas--run-status run))
                                       'face 'veritas-stat-face)
                      "]"))
          (if (and point-node (veritas--goto-node point-node))
              nil
            (goto-char (point-min))
            (forward-line (1- (min point-line (line-number-at-pos (point-max))))))
          (set-buffer-modified-p nil))))))

;;; Acting on the report

(defun veritas--report-run ()
  "Return the run whose report is being shown in this buffer."
  (or veritas--run
      (seq-find (lambda (run)
                  (eq (veritas--run-buffer run) (current-buffer)))
                veritas--runs)
      veritas--last-run))

(defconst veritas--selecting-flags
  '("--only-test" "--only-suite" "--only-tag"
    "--only-failed" "--no-only-failed" "--scan-dir")
  "Flags that select part of a suite rather than configuring the runner.")

(defun veritas--strip-selecting-flags (flags)
  "Return FLAGS without the options that select what to run.\n\nA rerun that narrows the selection itself has to start from a full run,\notherwise the old restriction would fight the new one."
  (let ((result '())
        (rest flags))
    (while rest
      (let ((flag (car rest)))
        (cond
         ((not (member flag veritas--selecting-flags))
          (push flag result)
          (setq rest (cdr rest)))
         ((member flag '("--only-failed" "--no-only-failed"))
          (setq rest (cdr rest)))
         (t (setq rest (cddr rest))))))
    (nreverse result)))

(defun veritas--rerun (run &optional extra-flags)
  "Run what RUN ran again, with EXTRA-FLAGS replacing its selection."
  (let ((base (if extra-flags
                  (veritas--strip-selecting-flags (veritas--run-cli-flags run))
                (veritas--run-cli-flags run))))
    (veritas--start (veritas--run-root run) (append base extra-flags))))

(defun veritas--run-node (run node)
  "Start a run selecting just NODE.\n\nVeritas selects tests and suites by name; a file or a benchmark is run by\nrunning the file it lives in, because the command line cannot select either."
  (let ((name (veritas-node-name node))
        (file (veritas-node-file node))
        (root (veritas--run-root run)))
    (pcase (veritas-node-type node)
      ('test (veritas--rerun run (list "--only-test" name)))
      ((or 'benchmark 'file)
       (let ((overrides (and file (veritas--file-run-overrides file root))))
         (if overrides
             (veritas--start root (veritas--run-cli-flags run) overrides)
           (veritas--rerun run nil))))
      (_ (veritas--rerun run (list "--only-suite" name))))))

(defun veritas--show-log (run)
  "Show the raw output RUN produced."
  (let ((buffer (veritas--run-log-buffer run)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer (veritas-log-mode))
      (pop-to-buffer buffer))))

(defun veritas--seek-assertion (node)
  "Try to land on the assertion NODE stands for, after visiting its test.\n\nAn assertion has no definition of its own, but the name it was given is a\nliteral in the test's body, so the report can point at the exact check."
  (when (and (eq (veritas-node-type node) 'assert)
             (not (string-match-p "\\`assertion [0-9]+\\'" (veritas-node-name node))))
    (let ((pattern (concat "#:name[ \t\n]+"
                           (regexp-quote (format "%S" (veritas-node-name node)))))
          (limit (min (point-max) (+ (point) 6000))))
      (save-excursion
        (when (re-search-forward pattern limit t)
          (goto-char (match-beginning 0))
          (back-to-indentation)
          t)))))

(defun veritas--visit-node (node)
  "Visit the source definition NODE stands for."
  (let ((location (veritas--node-position node)))
    (cond
     ((null location)
      (message "veritas: no source definition is known for \"%s\""
               (veritas-node-name node)))
     ((not (file-readable-p (car location)))
      (user-error "veritas: cannot read %s" (abbreviate-file-name (car location))))
     (t
      (pop-to-buffer (find-file-noselect (car location)))
      (goto-char (point-min))
      (forward-line (1- (max 1 (or (cdr location) 1))))
      (back-to-indentation)
      (veritas--seek-assertion node)
      (recenter)))))

(defun veritas--toggle-node (node)
  "Fold or unfold NODE in the report."
  (setf (veritas-node-collapsed node) (not (veritas-node-collapsed node)))
  (veritas--render (veritas--report-run)))

;;; The report buffer

(defun veritas--failing-line-p (position)
  "Return non-nil when POSITION is on the line of a failed test."
  (let ((node (veritas--node-at-position position)))
    (and node
         (veritas--unit-node-p node)
         (memq (veritas--derived-status node) '(fail error)))))

(defun veritas--failing-positions ()
  "Return the positions of the report's failure lines, in order."
  (let ((positions '()))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when (veritas--failing-line-p (point)) (push (point) positions))
        (forward-line 1)))
    (nreverse positions)))

(defun veritas--move-one-failure (direction)
  "Move to the next failure line in DIRECTION, returning non-nil when there."
  (let* ((positions (veritas--failing-positions))
         (here (point))
         (target (if (> direction 0)
                     (seq-find (lambda (position) (> position here)) positions)
                   (car (last (seq-filter (lambda (position) (< position here))
                                          positions))))))
    (when target (goto-char target))))

(defun veritas-results-next-error (arg reset)
  "Move to the ARGth next failure of the report.\n\nThis is `next-error-function' for the report, which is what makes `M-g M-n'\nand `next-error' walk the failures."
  (interactive)
  (when reset (goto-char (point-min)))
  (dotimes (_ (max 1 (abs (or arg 1))))
    (veritas--move-one-failure (if (> (or arg 1) 0) 1 -1))))

(defun veritas-results-mouse-activate (event)
  "Run the action attached to the clicked span in EVENT."
  (interactive "e")
  (let* ((start (event-start event))
         (position (posn-point start))
         (buffer (window-buffer (posn-window start))))
    (with-current-buffer buffer
      (goto-char position)
      (let ((action (get-text-property position 'veritas-action)))
        (if (functionp action)
            (funcall action)
          (veritas-results-activate-at-point))))))

(defun veritas-results-mouse-goto (event)
  "Visit the definition of the test clicked in EVENT."
  (interactive "e")
  (let* ((start (event-start event))
         (position (posn-point start))
         (buffer (window-buffer (posn-window start))))
    (with-current-buffer buffer
      (goto-char position)
      (veritas-results-goto-definition))))

(defun veritas-results-mouse-run (event)
  "Run the test clicked in EVENT."
  (interactive "e")
  (let* ((start (event-start event))
         (position (posn-point start))
         (buffer (window-buffer (posn-window start))))
    (with-current-buffer buffer
      (goto-char position)
      (veritas-results-run-node))))

(defun veritas-results-activate-at-point ()
  "Activate whatever is at point: a link if there is one, else a definition."
  (interactive)
  (let ((action (get-text-property (point) 'veritas-action)))
    (if (functionp action)
        (funcall action)
      (veritas-results-goto-definition))))

(defun veritas-results-goto-definition ()
  "Visit the definition of the test or assertion at point."
  (interactive)
  (let ((node (veritas--node-at-position (point))))
    (if node
        (veritas--visit-node node)
      (user-error "veritas: there is no result on this line"))))

(defun veritas-results-run-node ()
  "Run the test, suite or file at point."
  (interactive)
  (let ((node (veritas--node-at-position (point))))
    (if (null node)
        (user-error "veritas: there is no result on this line")
      (veritas--run-node (veritas--report-run) node))))

(defun veritas-results-rerun (&optional extra-flags)
  "Run the report's command again."
  (interactive)
  (veritas--rerun (veritas--report-run) extra-flags))

(defun veritas-results-rerun-failed ()
  "Run only what failed in the last run."
  (interactive)
  (veritas--rerun (veritas--report-run) '("--only-failed")))

(defun veritas-results-rerun-all ()
  "Run everything the way the report did, without any filter."
  (interactive)
  (veritas--rerun (veritas--report-run) nil))

(defun veritas-results-toggle ()
  "Fold or unfold the group at point."
  (interactive)
  (let ((node (veritas--node-at-position (point))))
    (when (and node (veritas-node-children node))
      (veritas--toggle-node node))))

(defun veritas-results-toggle-passed ()
  "Show or hide the assertions of passing tests in this report."
  (interactive)
  (setq veritas-report-show-passed (not veritas-report-show-passed))
  (veritas--render (veritas--report-run))
  (message "veritas: passing assertions %s"
           (if veritas-report-show-passed "shown" "hidden")))

(defun veritas-results-toggle-output ()
  "Show or hide the raw output the tests produced."
  (interactive)
  (setq veritas-report-show-output (not veritas-report-show-output))
  (veritas--render (veritas--report-run))
  (message "veritas: raw test output %s"
           (if veritas-report-show-output "shown" "hidden")))

(defun veritas-results-next (count)
  "Move to the next result line."
  (interactive "p")
  (dotimes (_ (or count 1))
    (forward-line 1)
    (while (and (not (eobp))
                (null (veritas--node-at-position (point))))
      (forward-line 1))))

(defun veritas-results-previous (count)
  "Move to the previous result line."
  (interactive "p")
  (dotimes (_ (or count 1))
    (forward-line -1)
    (while (and (not (bobp))
                (null (veritas--node-at-position (point))))
      (forward-line -1))))

(defun veritas-results-next-failure (count)
  "Move to the next failure."
  (interactive "p")
  (dotimes (_ (or count 1))
    (veritas--move-one-failure 1)))

(defun veritas-results-previous-failure (count)
  "Move to the previous failure."
  (interactive "p")
  (dotimes (_ (or count 1))
    (veritas--move-one-failure -1)))

(defun veritas-results-show-log ()
  "Show the raw output of the run this report is about."
  (interactive)
  (veritas--show-log (veritas--report-run)))

(defun veritas-results-copy-command ()
  "Put the command behind this report on the kill ring."
  (interactive)
  (let ((command (mapconcat #'identity (veritas--run-command (veritas--report-run))
                            " ")))
    (kill-new command)
    (message "veritas: copied %s" command)))

(defun veritas-results-kill ()
  "Stop the run this report is about, if it is still going."
  (interactive)
  (let ((run (veritas--report-run)))
    (if (veritas-running-p run)
        (progn (veritas--kill run)
               (setf (veritas--run-status run) 'aborted)
               (veritas--render run)
               (message "veritas: stopped the run"))
      (message "veritas: the run has finished"))))

(defvar veritas-results-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'veritas-results-goto-definition)
    (define-key map (kbd "TAB") #'veritas-results-toggle)
    (define-key map (kbd "g") #'veritas-results-rerun-all)
    (define-key map (kbd "r") #'veritas-results-rerun-all)
    (define-key map (kbd "f") #'veritas-results-rerun-failed)
    (define-key map (kbd "R") #'veritas-results-run-node)
    (define-key map (kbd "n") #'veritas-results-next)
    (define-key map (kbd "p") #'veritas-results-previous)
    (define-key map (kbd "M-n") #'veritas-results-next-failure)
    (define-key map (kbd "M-p") #'veritas-results-previous-failure)
    (define-key map (kbd "v") #'veritas-results-toggle-passed)
    (define-key map (kbd "o") #'veritas-results-toggle-output)
    (define-key map (kbd "l") #'veritas-results-show-log)
    (define-key map (kbd "w") #'veritas-results-copy-command)
    (define-key map (kbd "K") #'veritas-results-kill)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap of the Veritas report buffer.")

(define-derived-mode veritas-results-mode special-mode "Veritas"
  "Major mode of the Veritas report buffer.\n\nEvery test and assertion is a link: \\[veritas-results-goto-definition]\nvisits its definition, \\[veritas-results-run-node] runs it on its own, and\n\\[veritas-results-toggle] folds a suite.  The failures come first and\n`next-error' walks them."
  (setq-local next-error-function #'veritas-results-next-error)
  (setq-local truncate-lines nil)
  (setq-local revert-buffer-function
              (lambda (&rest _)
                (veritas--render (veritas--report-run))))
  (add-hook 'kill-buffer-hook #'veritas--results-killed nil t))

(defun veritas--results-killed ()
  "Stop the run whose report buffer has just been killed."
  (let ((run (seq-find (lambda (run) (eq (veritas--run-buffer run) (current-buffer)))
                       veritas--runs)))
    (when (and run (veritas-running-p run))
      (veritas--kill run))))

;;; Running Veritas

(defun veritas--root-or-error ()
  "Return the project root of this buffer, or signal a user error."
  (or (veritas-project-root)
      (user-error "veritas: this buffer is not inside a Veritas project")))

(defun veritas--prefix-means-no-benchmarks (prefix)
  "Return non-nil when PREFIX asks for a run without benchmarks.\n\nA prefix argument means \"skip the benchmarks\", because they are the slow part\nof a run and the common case is a quick feedback loop."
  (and prefix t))

(defun veritas-run-all (&optional prefix)
  "Run every test of the project.\n\nWith a prefix argument the benchmarks are skipped."
  (interactive "P")
  (let ((root (veritas--root-or-error)))
    (veritas--start root (veritas--run-flags root nil
                                             (veritas--prefix-means-no-benchmarks
                                              prefix)))))

(defun veritas--run-file (file root prefix)
  "Run the test FILE of ROOT, skipping benchmarks when PREFIX says so."
  (let ((overrides (and file (veritas--file-run-overrides file root))))
    (veritas--start root
                    (veritas--run-flags root nil
                                        (veritas--prefix-means-no-benchmarks
                                         prefix))
                    overrides)))

(defun veritas-run-file (&optional prefix)
  "Run the test file this buffer is visiting.\n\nVeritas cannot select a single file on its command line, so a throwaway scan\nroot of symbolic links is built for it; see `veritas-file-run-restricted'.\nWith a prefix argument the benchmarks are skipped."
  (interactive "P")
  (let* ((root (veritas--root-or-error))
         (file (cond ((and buffer-file-name
                           (string-suffix-p ".scm" buffer-file-name))
                      (expand-file-name buffer-file-name))
                     ((derived-mode-p 'veritas-results-mode)
                      (let ((node (veritas--node-at-position (point))))
                        (and node (veritas-node-file node)))))))
    (unless file
      (user-error "veritas: there is no test file to run here"))
    (veritas--run-file file root prefix)))

(defun veritas-run-here (&optional prefix)
  "Run the test, suite or benchmark at point.\n\nOutside a definition the file is run instead.  With a prefix argument the\nbenchmarks are skipped."
  (interactive "P")
  (let* ((root (veritas--root-or-error))
         (node (and (derived-mode-p 'scheme-mode) (veritas--node-at-point)))
         (skip (veritas--prefix-means-no-benchmarks prefix)))
    (pcase (and node (veritas-node-type node))
      ('test (veritas--start root (veritas--run-flags
                                   root (list "--only-test" (veritas-node-name node))
                                   skip)))
      ((or 'suite 'scenario 'feature 'story 'fabula 'scaena 'test-each 'suite-each)
       (veritas--start root (veritas--run-flags
                             root (list "--only-suite" (veritas-node-name node))
                             skip)))
      (_ (veritas-run-file prefix)))))

(defun veritas--project-candidates (types)
  "Return every project definition of TYPES, as a list of plists.\n\nEach element holds the name to select it by, a label that shows where it is,\nand the file and line it was found at."
  (let* ((root (veritas--root-or-error))
         (base (car (veritas--test-layout root)))
         (candidates '()))
    (when base
      (dolist (file (directory-files-recursively base "\\.scm\\'"))
        (let ((source (veritas--file-source file)))
          (dolist (node (and source (veritas--all-nodes source)))
            (when (memq (veritas-node-type node) types)
              (push (list :name (veritas-node-name node)
                          :label (string-join
                                  (append (cdr (veritas--node-path-names node))
                                          (list (veritas-node-name node)))
                                  " \u203a ")
                          :type (veritas-node-type node)
                          :file file
                          :line (veritas-node-line node))
                    candidates))))))
    (nreverse candidates)))

(defun veritas--prompt-for-definition (prompt types)
  "Read one of the project's definitions of TYPES by name."
  (let* ((candidates (veritas--project-candidates types))
         (table (mapcar (lambda (candidate)
                          (cons (plist-get candidate :label) candidate))
                        candidates)))
    (unless table
      (user-error "veritas: found no %s definitions in this project"
                  (mapconcat #'symbol-name types "/")))
    (cdr (assoc (completing-read prompt table nil t) table))))

(defun veritas-run-test ()
  "Run one test of the project, chosen by name."
  (interactive)
  (let* ((root (veritas--root-or-error))
         (choice (veritas--prompt-for-definition "Test: " veritas--test-types)))
    (veritas--start root (veritas--run-flags root (list "--only-test"
                                                        (plist-get choice :name))))))

(defun veritas-run-suite ()
  "Run one suite, scenario or table of the project, chosen by name."
  (interactive)
  (let* ((root (veritas--root-or-error))
         (choice (veritas--prompt-for-definition
                  "Suite: " (mapcar #'intern veritas--group-keywords))))
    (veritas--start root (veritas--run-flags root (list "--only-suite"
                                                        (plist-get choice :name))))))

(defun veritas-run-tag (tag)
  "Run the tests and suites carrying TAG."
  (interactive (list (read-string "Tag: ")))
  (let ((root (veritas--root-or-error)))
    (veritas--start root (veritas--run-flags root (list "--only-tag" tag)))))

(defun veritas-run-failed ()
  "Run only what the last run recorded as failing."
  (interactive)
  (let ((root (veritas--root-or-error)))
    (veritas--start root (veritas--run-flags root '("--only-failed")))))

(defun veritas-run-last (&optional prefix)
  "Run the last run's command again.\n\nWith a prefix argument the benchmarks are skipped."
  (interactive "P")
  (let ((skip (veritas--prefix-means-no-benchmarks prefix)))
    (cond
     ((null veritas--last-run) (veritas-run-all prefix))
     (skip (veritas--start (veritas--run-root veritas--last-run)
                           (veritas--run-flags (veritas--run-root veritas--last-run)
                                               nil t)))
     (t (veritas--rerun veritas--last-run nil)))))

(defun veritas-show-report ()
  "Show the report of the most recent run."
  (interactive)
  (if (and veritas--last-run
           (buffer-live-p (veritas--run-buffer veritas--last-run)))
      (veritas--display-report veritas--last-run)
    (user-error "veritas: no run has been made yet")))

(defun veritas-show-log ()
  "Show the raw output of the most recent run."
  (interactive)
  (if veritas--last-run
      (veritas--show-log veritas--last-run)
    (user-error "veritas: no run has been made yet")))

;;; Running with the project's own reporter

(defcustom veritas-raw-reporter "emoji-reporter"
  "Reporter used by `veritas-run-raw'.\n\nThis is the reporter Veritas would use in a terminal, so `emoji-reporter' or\n`monotone-reporter' are the ones that read best in the log buffer."
  :type 'string
  :group 'veritas)

(defvar veritas--raw-process nil
  "The process of the last `veritas-run-raw', if it is still going.")

(defun veritas--kill-raw-process ()
  "Stop the raw run, if there is one."
  (when (and veritas--raw-process
             (memq (process-status veritas--raw-process) '(run stop open listen)))
    (delete-process veritas--raw-process))
  (setq veritas--raw-process nil))

(defun veritas--replace-reporter (flags reporter)
  "Return FLAGS with the reporter it names replaced by REPORTER."
  (let ((result '())
        (rest flags))
    (while rest
      (if (equal (car rest) "--reporter")
          (progn (push "--reporter" result)
                 (push reporter result)
                 (setq rest (cddr rest)))
        (push (car rest) result)
        (setq rest (cdr rest))))
    (nreverse result)))

(defun veritas--raw-filter (buffer text)
  "Append TEXT to the raw BUFFER, following it when it is displayed."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let* ((inhibit-read-only t)
             (windows (get-buffer-window-list buffer nil t))
             (following (seq-filter (lambda (window)
                                      (= (window-point window) (point-max)))
                                    windows)))
        (goto-char (point-max))
        (insert (veritas--strip-ansi text))
        (dolist (window following)
          (set-window-point window (point-max)))))))

(defun veritas-run-raw (&optional prefix)
  "Run Veritas the way a terminal would, into a plain log buffer.\n\nThis is the escape hatch: it uses the project's own reporter instead of the\nJSON one the structured report is built from, so the output looks exactly like\na `veritas' command in a shell.  With a prefix argument the benchmarks are\nskipped."
  (interactive "P")
  (let* ((root (veritas--root-or-error))
         (skip (veritas--prefix-means-no-benchmarks prefix))
         (flags (veritas--replace-reporter
                 (veritas--run-flags root nil skip) veritas-raw-reporter))
         (command (append (veritas--command root) flags))
         (buffer (veritas--get-buffer veritas-log-buffer-name t))
         (default-directory (file-name-as-directory root)))
    (veritas--kill-raw-process)
    (with-current-buffer buffer
      (veritas-log-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (concat "$ " (mapconcat #'identity command " ") "\n")
                            'face 'veritas-stat-face)))
      (add-hook 'kill-buffer-hook #'veritas--kill-raw-process nil t)
      (setq default-directory (file-name-as-directory root)))
    (pop-to-buffer buffer)
    (setq veritas--raw-process
          (make-process :name "veritas-raw"
                        :command command
                        :buffer nil
                        :filter (lambda (_process text)
                                  (veritas--raw-filter buffer text))
                        :stderr buffer
                        :connection-type 'pipe
                        :coding 'utf-8
                        :noquery t))
    (cl-pushnew (veritas--make-run :id 0 :root root :command command :status 'passed)
                veritas--runs)
    veritas--raw-process))

;;; The minor mode for Veritas sources

(defconst veritas-assertion-names
  '("assert" "assert-equal" "assert-eq" "assert-eqv" "assert-true"
    "assert-false" "assert-error" "assert-no-error" "assert-not-eq"
    "assert-not-equal" "assert-not-eqv" "assert-approximate"
    "assert-not-approximate" "assert-contains" "assert-not-contains"
    "assert-matches" "assert-not-matches" "assert-raises" "assert-empty"
    "assert-not-empty" "assert-length" "assert-in-range" "assert-one-of"
    "assert-snapshot" "assert-called" "assert-called-with"
    "assert-call-count" "assert-container-running" "is-approximate?"
    ;; The Latin aliases, which are the same procedures under another name.
    "proba" "aequalis" "idem" "aequivalens" "non-aequalis" "non-idem"
    "non-aequivalens" "verus" "falsus" "propinquus?" "propinquus"
    "non-propinquus" "errat" "non-errat" "suscitat" "continet"
    "non-continet" "congruit" "non-congruit" "inanis" "non-inanis"
    "longitudo" "intra" "unus-ex")
  "Every assertion and matcher Veritas provides, English and Latin.")

(defconst veritas-step-names
  '("given" "when-step" "then" "and-step" "but-step"
    "Given" "When" "Then"
    "dato" "quando" "tunc" "etiam" "sed")
  "The names a BDD scenario's steps go by.")

(defconst veritas-helper-names
  '("generate-integer" "generate-char" "generate-list" "generate-symbol"
    "generate-string" "make-spy" "make-stub" "spy?" "spy-calls"
    "spy-results" "spy-call-count" "spy-called-with?" "snapshot-path"
    "cases->table" "with-temporary-binding" "container-run" "container-exec"
    "container-exec-status" "container-stop" "container-remove"
    "container-logs" "container-running?" "container-build"
    "container-wait-for-log" "container-wait-for-command"
    "container-wait-for-port" "wait-until" "run-command" "run-command!")
  "The helpers Veritas provides around the assertions.")

(defconst veritas-runner-names '("veritas-run")
  "The names that enter a Veritas suite.")

(defconst veritas-font-lock-keywords
  `((,(regexp-opt (append veritas--unit-keywords veritas--group-keywords)
                  'symbols)
     . veritas-definition-face)
    (,(regexp-opt veritas-assertion-names 'symbols)
     . veritas-assert-face)
    (,(regexp-opt veritas-step-names 'symbols)
     . veritas-step-face)
    (,(regexp-opt (append veritas-helper-names veritas-runner-names) 'symbols)
     . veritas-runner-face)
    ("#:[[:alnum:]?!*<>=+/-]+" . veritas-keyword-face))
  "Font lock keywords that teach a Scheme buffer the Veritas vocabulary.")

(defun veritas-imenu-create-index ()
  "Return an Imenu index of this buffer's Veritas definitions.\n\nTests are nested under the suite or scenario that holds them, so Imenu gives\nthe hierarchy a report would."
  (veritas--imenu-entries (veritas-source-nodes (veritas--buffer-source))))

(defun veritas--imenu-entries (nodes)
  "Return Imenu entries for NODES, nesting a group's children under it.

A position is a marker, as Imenu expects, so the index keeps pointing at the
definition while the buffer is edited."
  (mapcar (lambda (node)
            (let ((position (copy-marker (veritas-node-start node)))
                  (children (veritas--imenu-entries (veritas-node-children node))))
              (if children
                  (cons (veritas-node-name node) (cons position children))
                (cons (veritas-node-name node) position))))
          nodes))

(defun veritas-which-function ()
  "Return the path of the Veritas definition at point.\n\nThis is what `which-func-functions' and `add-log-current-defun-function' ask\nfor, so the enclosing suite and test show up in the mode line."
  (let ((node (veritas--node-at-point)))
    (when node (string-join (veritas--node-path-names node) " \u203a "))))

(defun veritas--lighter ()
  "Return the mode line indicator of `veritas-mode'."
  (when veritas-mode-line-format
    (format veritas-mode-line-format
            (or (veritas-which-function) ""))))

(defvar veritas-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c v") #'veritas-dispatch)
    (define-key map (kbd "C-c C-t") #'veritas-run-here)
    (define-key map (kbd "C-c C-a") #'veritas-run-all)
    (define-key map (kbd "C-c C-f") #'veritas-run-file)
    (define-key map (kbd "C-c C-v") #'veritas-show-report)
    (define-key map (kbd "C-c C-b") #'veritas-run-raw)
    map)
  "Keymap of `veritas-mode'.")

;;;###autoload
(define-minor-mode veritas-mode
  "Teach this Scheme buffer about Veritas.\n\nTurning it on fontifies the Veritas vocabulary, adds the definitions to Imenu\nand to `which-function-mode', and binds a command map under \\`C-c v'."
  :lighter (:eval (veritas--lighter))
  :keymap veritas-mode-map
  :group 'veritas
  (if veritas-mode
      (progn
        (font-lock-add-keywords nil veritas-font-lock-keywords 'append)
        (setq-local imenu-create-index-function #'veritas-imenu-create-index)
        (add-hook 'which-func-functions #'veritas-which-function nil t)
        (setq-local add-log-current-defun-function #'veritas-which-function))
    (font-lock-remove-keywords nil veritas-font-lock-keywords)
    (kill-local-variable 'imenu-create-index-function)
    (remove-hook 'which-func-functions #'veritas-which-function t)
    (kill-local-variable 'add-log-current-defun-function))
  (when (fboundp 'font-lock-flush)
    (font-lock-flush)))

;;;###autoload
(defun veritas-mode-maybe ()
  "Enable `veritas-mode' when this buffer belongs to a Veritas project."
  (when (and veritas-auto-enable
             (derived-mode-p 'scheme-mode)
             (veritas-project-root))
    (veritas-mode 1)))

;;; The command menu

(defvar veritas-prefix-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'veritas-run-all)
    (define-key map (kbd "f") #'veritas-run-file)
    (define-key map (kbd "t") #'veritas-run-here)
    (define-key map (kbd "T") #'veritas-run-test)
    (define-key map (kbd "s") #'veritas-run-suite)
    (define-key map (kbd "g") #'veritas-run-tag)
    (define-key map (kbd "F") #'veritas-run-failed)
    (define-key map (kbd "l") #'veritas-run-last)
    (define-key map (kbd "r") #'veritas-run-raw)
    (define-key map (kbd "R") #'veritas-show-report)
    (define-key map (kbd "L") #'veritas-show-log)
    (define-key map (kbd "k") #'veritas-kill)
    map)
  "Keymap of the Veritas command menu.")

(easy-menu-define veritas-menu veritas-mode-map "Veritas"
  '("Veritas"
    ["Run project" veritas-run-all t]
    ["Run this file" veritas-run-file t]
    ["Run what is at point" veritas-run-here t]
    "--"
    ["Run a test by name" veritas-run-test t]
    ["Run a suite by name" veritas-run-suite t]
    ["Run a tag" veritas-run-tag t]
    ["Run what failed" veritas-run-failed t]
    ["Run the last command again" veritas-run-last t]
    "--"
    ["Show the report" veritas-show-report t]
    ["Show the raw output" veritas-show-log t]
    ["Run with the project reporter" veritas-run-raw t]
    "--"
    ["Stop the run" veritas-kill t]))

(eval-when-compile (require 'transient nil t))

;; The macro expands into calls to transient's own internals, which the compiler
;; cannot see as defined even though the `when' below guarantees they are there
;; whenever the prefix itself is.
(with-no-warnings
  (when (require 'transient nil t)
    (transient-define-prefix veritas-transient ()
                             "Run and report Veritas tests."
                             ["Run"
                              ("a" "project" veritas-run-all)
                              ("f" "this file" veritas-run-file)
                              ("t" "test, suite or benchmark at point" veritas-run-here)]
                             ["Select"
                              ("T" "a test, by name" veritas-run-test)
                              ("s" "a suite, by name" veritas-run-suite)
                              ("g" "a tag" veritas-run-tag)
                              ("F" "what failed last time" veritas-run-failed)
                              ("l" "the last command again" veritas-run-last)]
                             ["Report"
                              ("R" "show the report" veritas-show-report)
                              ("L" "show the raw output" veritas-show-log)]
                             ["Other"
                              ("r" "run with the project reporter" veritas-run-raw)
                              ("k" "stop the run" veritas-kill)])))

(defun veritas-dispatch ()
  "Run a Veritas command, choosing from a menu."
  (interactive)
  (if (fboundp 'veritas-transient)
      (call-interactively #'veritas-transient)
    (message "veritas: a=project f=file t=here T=test s=suite g=tag F=failed l=last r=raw R=report L=log k=stop")
    (set-transient-map veritas-prefix-map t)))

;;; The raw output buffer

(defvar veritas-log-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "K") #'veritas--kill-raw-process)
    map)
  "Keymap of the Veritas output log.")

(define-derived-mode veritas-log-mode special-mode "Veritas-Log"
  "Major mode of the buffer holding raw Veritas output."
  (setq-local truncate-lines nil))

(add-hook 'scheme-mode-hook #'veritas-mode-maybe)

(provide 'veritas)
;;; veritas.el ends here
