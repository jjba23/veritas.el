;; veritas.el

;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; veritas.el is free software: you can redistribute it and/or modify
;; it under the terms of the Lesser GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; veritas.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; Lesser GNU General Public License for more details.

;; You should have received a copy of the Lesser GNU General Public License
;; along with veritas.el.  If not, see <https://www.gnu.org/licenses/>.

(define-module (maak)
  #:declarative? #t
  #:use-module (maak maak)
  ;; The container helpers are imported under a prefix because the tasks below
  ;; are named the way maak exposes them on the command line -- `maak
  ;; container-build' -- and a task may not shadow the helper it calls.
  #:use-module ((maak container) #:prefix ct:))

;; ====== Maak constants ======

;; The Emacs the package is compiled and tested with, overridable with the
;; EMACS environment variable, exactly as one would expect.
(define emacs-command
  (or (getenv "EMACS") "emacs"))

;; The package itself.
(define source-file
  "veritas.el")

;; The ERT suite.
(define test-file
  "test/veritas-test.el")

;; What byte-compilation leaves behind.
(define compiled-files
  '("veritas.elc" "test/veritas-test.elc"))

;; ====== Maak tasks ======

(define (compile)
  "Byte-compile the package."
  (run (list emacs-command "-Q" "--batch" "-L" "." "-f" "batch-byte-compile"
             source-file)
       #:verbose? #t))

(define (test)
  "Run the ERT suite, which includes a real run against the fixture."
  (run (list emacs-command "-Q" "--batch" "-L" "." "-L" "test" "-l" test-file
             "-f" "ert-run-tests-batch-and-exit")
       #:verbose? #t))

(define (lint)
  "Compile with the warnings turned into errors, and report checkdoc findings."
  (run (list emacs-command "-Q" "--batch" "-L" "."
             "--eval" "(setq byte-compile-error-on-warn t)"
             "-f" "batch-byte-compile" source-file)
       #:verbose? #t)
  (run (list emacs-command "-Q" "--batch" "-L" "."
             "--eval" "(progn (require (quote checkdoc)) (checkdoc-file \"veritas.el\"))")
       #:verbose? #t))

(define (clean)
  "Remove the byte-compiled files."
  (for-each (lambda (file)
              (when (file-exists? file) (delete-file file)))
            compiled-files))

(define (check)
  "Compile and test, from a clean tree."
  (clean)
  (compile)
  (test))

(define (repl)
  "Open an Emacs with the package loaded for hacking."
  (run (list emacs-command "-Q" "-L" "."
             "--eval" "(progn (require (quote veritas)) (message \"veritas.el loaded: C-c v dispatches the commands\"))")))

(define (hot-reload)
  "Compile and test again whenever a source or test file changes."
  (run (list "watchexec" "--clear" "--exts" "el" "--on-busy-update=restart"
             "--shell" "bash" "--watch" "." "maak" "--" "check")))

(define (hr)
  "Short alias for `hot-reload'."
  (hot-reload))

(define (default)
  "List the available tasks."
  (list-tasks))

;; ====== Container tasks ======

(define (container-build)
  "Build the container image for veritas-el."
  (ct:container-build "." #:tag "veritas-el" #:verbose? #t))

(define (container-run)
  "Run the container image for veritas-el."
  (ct:container-run "veritas-el:latest"
                    #:interactive? #t
                    #:tty? #t))

(define (package-docker)
  "Build the container image for veritas-el."
  (container-build))

;; Local Variables:
;; mode: scheme
;; End:
