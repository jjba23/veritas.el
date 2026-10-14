# SPDX-License-Identifier: LGPL-3.0-or-later
#
# Tasks for the veritas.el package itself.

EMACS ?= emacs
SRC = veritas.el
TEST = test/veritas-test.el

.PHONY: all compile test clean check

all: compile

compile:
	$(EMACS) -Q --batch -L . -f batch-byte-compile $(SRC)

test:
	$(EMACS) -Q --batch -L . -L test -l $(TEST) -f ert-run-tests-batch-and-exit

clean:
	rm -f $(SRC)c

check: clean compile test
