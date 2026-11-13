# Vision

`veritas.el` is the Emacs side of the Veritas test framework: it reads a Veritas suite with its own
Scheme-aware scanner, runs the CLI, and turns the runner's JSON event stream into a report buffer
that is more useful than the terminal output it replaces. It is one file, it needs only Emacs 27.1 and
its bundled libraries, and Guile is required only when you actually run something. This document is
about where that integration should go: which parts of the edit–run–fix loop it should own, which
inconsistencies are already visible, and what the scanner makes possible that no other integration
here has.

## Where veritas.el is today

The package is roughly two and a half thousand lines of one file, organised around four ideas:

- **A scanner, not a REPL.** `veritas-mode` derives from `scheme-mode` and adds a small reader that
  follows paren depth and skips strings and comments, so what Emacs believes about a file is what the
  file declares. Definitions are found by their head keyword — `suite`, `describe`, `context`,
  `scenario`, `feature`, `story`, `fabula`, `scaena`, `test`, `it`, `spec`, `example`, `benchmark`,
  `test-each`, `suite-each` and the BDD steps with their English and Latin spellings. A `#:name "..."`
  is read as the name, `#:skip? #t` is noticed, and a name computed at run time keeps the token that
  stood in its place so the definition stays visible and runnable.
- **Four views of that understanding.** Font lock for the vocabulary without disturbing
  `scheme-mode`, an Imenu index of the suite hierarchy, `which-function-mode` and
  `add-log-current-defun` answers that read as `Math Suite › a deliberately failing test`, and point
  queries (`veritas-node-at-point`, `-in-line`, `-in-region`, `enclosing-nodes`, `node-path`) that
  everything else is built on.
- **Commands that act on a definition.** `C-c v` dispatch, run all, run file, run here, run a test or
  suite or tag by name, rerun what failed, rerun the last command, run with the project's own
  reporter, show the report, show the raw log, stop the run. A prefix argument skips benchmarks,
  which are the slow part of a feedback loop. Every name in the report is a button: `mouse-1` visits
  the definition, `mouse-3` runs it.
- **A report buffer built from the JSON stream.** Failures first with the runner's message and a
  `file:line`, `next-error` integration so `M-g n` walks them, folding per file and per suite,
  rerun and raw-log links, a provenance headline naming the reporter, test type and module that
  produced it, and `w` to copy the command line.

The runner discovery is where most of the hard-won knowledge lives, and it is worth preserving as a
design: `bin/veritas` in the project wrapped in `guix shell -m manifest.scm` when a manifest exists,
otherwise a `veritas` on `PATH`, otherwise the CLI module run with Guile and a load path built from
the project's own directories. Before any of that runs, a preflight imports `(veritas cli)` and
`(veritas runner)` with the same environment and refuses to start when the import fails, naming the
module Guile could not find. Because the CLI cannot select a single file,
`veritas-file-run-restricted` builds a throwaway directory of symbolic links, runs there, and deletes
it afterwards, resolving the reported paths back against the configured test root.

What is honestly inconsistent today: `Version:` in the header says `0.2.1`, the packaging recipes and
the README's installation section still name `0.1.3`, and the tag line has reached `0.2.3`. That is
three version strings disagreeing, in a project whose sibling packages check theirs with a `maak`
task — the same task belongs here.

## The vision

1. **The whole edit–run–fix loop happens inside one Emacs and never needs a terminal.** A failure, its
   definition, the rerun of exactly that test, and the reason it failed should be four keystrokes
   apart, with no shell command typed by hand and no state that lives only in a scrollback buffer.
2. **A failure is navigation in both directions.** Report to definition and definition to run, each
   one keystroke, and a third direction that does not exist yet: definition to the last run that
   touched it, so "was this always failing?" stops being a question about memory.
3. **What Emacs knows about a file equals what Veritas knows about it.** The scanner and the runner
   should agree on the same hierarchy, the same names and the same skipped state, including table
   tests that expand at run time and tags that select at run time.
4. **The integration is a client of the JSON contract and nothing else.** No parsing of the runner's
   human output, no coupling to internal module names, so a Veritas release that keeps its contract
   keeps this package working.
5. **Emacs can be a CI surface.** Run, compare against the previous run, and publish the result — the
   same report the pipeline produced, read in the editor where the fix will be written.

## Features that are in scope and not built yet

- **Tags in the scanner and the report.** `#:tags` selects tests in the runner and appears nowhere in
  Emacs: not in the Imenu entry, not in the report. The hard part is reading keyword arguments
  reliably with a paren-and-string scanner, and showing tag state in a folding buffer without
  turning every line into a form.
- **A table test's real name.** `test-each` expands into one test per case at run time, so the name at
  point is a token rather than a name — `veritas-run-here` runs it, but `--only-test` selection needs
  the mapping from token to the expanded names. The hard part is that the mapping lives in the runner,
  not in the source.
- **Coverage in the editor.** The core already writes LCOV, Cobertura, JaCoCo and a self-contained
  HTML page; nothing here reads any of it. The hard part is per-line hit counts in a source buffer
  without fighting font-lock, without a second package, and without repainting the buffer on every
  keystroke.
- **The trace viewer.** `--show-trace` prints a numbered timeline and `reports/traces/last.scm` holds
  the frames; the report buffer ignores both. The hard part is presenting a long sequential frame list
  in a buffer where folding, not scrolling, is the navigation model.
- **Change-aware runs on the dispatch.** The CLI has `--changed` and `--since`; `C-c v` does not. The
  hard part is choosing a base ref sensibly per project and making the selection visible before and
  after the run, so nobody mistakes a filtered run for a passing suite.
- **Per-project settings.** `veritas-command` and friends are global, and real work means several
  projects with different layouts. The hard part is re-resolving detection when the project changes
  without a restart and without surprising a user who set a variable by hand.
- **Report persistence.** Killing the report buffer loses the last run, and comparing a run with its
  predecessor is the most common thing a developer does. The hard part is serialising a report the
  JSON stream describes, and not writing it into the project directory.

## New features that would be worth having

- **Run history and a failure diff.** Keep the last N runs in memory and show what changed: newly
  failing, newly fixed, still failing. One key, and the question "did I make it worse?" becomes
  answerable inside the editor.
- **Watch mode on top of the scanner.** Emacs already owns file notifications, and the CLI already
  knows how to select what changed, so this is a hook and a timer — rerun the file or project on save
  and keep the report in place.
- **A margin mark for failing lines.** The report knows the `file:line` of every failure; a
  git-gutter-style mark in the visited buffer would put the failure exactly where the work happens.
- **A test skeleton generator.** The scanner knows every declaration keyword and the shape of a test
  form; `veritas-insert-test` in a suite should write a body with the right keywords and the right
  nesting.
- **Benchmark history.** `benchmark` definitions already parse and the report already shows them as
  not-run; showing durations across runs would make the slowest part of the suite a visible trend.
- **A dispatch that shows the suite's tags.** A transient listing the tags around point, each one
  runnable, turns the tag vocabulary from a CLI flag into something clickable.
- **A jump to the module under test.** From a test to the source it names, using the same
  name-matching the CLI's impact graph uses, so the loop closes in both directions.

## Contributions that would move the needle

1. **Tags in the scanner and in the report.** Small, self-contained, and it fixes an inconsistency
   anyone hits the first time they tag a test. One scanner clause, one report line, two tests.
2. **`--changed` and `--since` on the dispatch,** with the selected files shown in the headline. It
   makes the largest Veritas feature usable without a terminal.
3. **Run history with a failure diff.** The report structs already hold everything needed; the work is
   in comparing them and rendering the difference honestly.
4. **Report persistence.** Prerequisite for history across sessions, and the thing that makes a
   broken build resumable after lunch.
5. **Watch mode.** The most requested shape of integration in every editor, and here the hard part is
   already solved by the CLI's selection.
6. **Coverage gutters.** Deferred by the font-lock problem, not by the data: LCOV is there.
7. **`veritas-command` from `.dir-locals.el`,** with the detection order documented as the fallback.
8. **One version string.** Header, packaging recipes and README saying the same number, checked by the
   same `maak` task the sibling projects already use.

## Compared to related projects

| Project | What it is | Where veritas.el differs |
| --- | --- | --- |
| `cider-test` | CIDER's Clojure test integration: run at point or namespace, an error buffer with expected/actual, stacktrace navigation | The closest analogue, and better than this at showing assertion diffs. It needs a live REPL; veritas.el needs none, because the scanner understands the file without evaluating it. |
| ERT and `ert-results-mode` (built-in) | Emacs Lisp's own test framework and its results buffer, with jump-to-test, conditional re-runs and a batch runner | ERT runs inside the same Emacs, so all of its integration is direct. veritas.el is an out-of-process client and has to reconstruct the hierarchy from a stream. |
| `buttercup` | A BDD framework for Emacs Lisp with `describe`/`it` nesting and its own runner | Same language, same editor, so its reporting can be native. Its `describe`/`it` vocabulary is also what the Veritas scanner understands, which is where the two meet. |
| Geiser | Scheme REPL integration for Guile, Racket and friends: evaluation, a debugger, module navigation | Geiser evaluates; this package reads and runs. The two are complementary, and a project using both gets editing from one and the test loop from the other. |
| `compile` and `next-error` (built-in) | The generic compile buffer plus an error regexp: the baseline every runner integrates through | Universal and dependency-free, but the report is text: no suite hierarchy, no not-run state, no rerun of one definition, no provenance. |
| `quickrun` | A generic "run the thing at point" package with per-language configurations | quickrun runs a command; this package runs a definition and interprets the answer. |
| `emacs-eask` | Emacs Lisp tooling for building, testing and packaging, with a test command for ert/buttercup | Tooling for a different language and a different runner, driven from the command line rather than from the buffer. |

What the others do that veritas.el could still add: CIDEr's inline expected/actual diff inside the
error buffer, ERT's conditional re-run and its batch mode, buttercup's native nesting, geiser's
module-aware navigation, and grep-style error regexps so that a report pasted from CI is still
navigable. Where veritas.el is ahead and should stay ahead: the scanner means no REPL, no Guile and no
evaluation is needed to understand a file, so Imenu, `which-function-mode` and run-at-point all work
in a plain buffer; the report is built from the runner's own JSON and cross-checked against the
sources, which is why it can distinguish "defined but not run" from "not defined"; the preflight check
turns a ten-minute mystery into a tenth-of-a-second error with a remedy; running a single file is
possible through a symlink directory even though the CLI has no such flag; and the report always
names the command that produced it, so the run can be copied into a terminal, a commit message or a
bug report.

## In the long run

The long bet is that **the scanner is the reusable part**: a small, tested reader of a declaration
vocabulary is useful to any front end — another editor, a documentation generator, a `describe`
command — and publishing it as its own module would let the test integration stay thin. The second bet
is that **the JSON contract is the interface, so the integration can outlive the framework's
internals**: the package should keep working across Veritas releases that change modules, reporters
and flags, and it should never need to read the runner's human output. The third is that **the report
buffer becomes the place a Guile project's failures live**, with history, diffs and coverage in the
same buffer, so that "run the tests" stops meaning "switch to a terminal". The fourth is that **the
package stays one file with no dependency beyond Emacs**: optional `transient` when it is there, nothing
else required, because a test integration that breaks because a third-party package changed is worse
than no integration at all.

## What this document is for

Use it to place a change. Anything that reads a file, runs a declaration, or explains a result belongs
here; anything that computes results belongs in Veritas. New parsers of human output, new required
dependencies, and features that only work with a live Guile process are out of scope. Anything that
makes a failure reachable in fewer keystrokes, or makes what Emacs knows agree with what the runner
knows, is the work this package is for.

*This document describes intent, not commitments; the code, the release notes and the issue tracker
say what is actually true today.*
