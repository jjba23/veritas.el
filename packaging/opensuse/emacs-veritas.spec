#
# spec file for package emacs-veritas
#
# Copyright (c) 2026 SUSE LLC and contributors
#
# All modifications and additions to the file contributed by third parties
# remain the property of their copyright owners, unless otherwise agreed
# upon. The license for this file, and modifications and additions to the
# file, is the same license as for the pristine package itself (unless the
# license for the pristine package is not an Open Source License, in which
# case the license is the MIT License). An "Open Source License" is a
# license that conforms to the Open Source Definition (Version 1.9)
# published by the Open Source Initiative.

# Please submit bugfixes or comments via http://bugs.opensuse.org/
#

Name:           emacs-veritas
Version:        0.1.3
Release:        0
Summary:        Emacs integration for the Veritas test framework
License:        LGPL-3.0-or-later
URL:            https://codeberg.org/jjba23/veritas.el
Source0:        veritas.el-%{version}.tar.gz
BuildRequires:  emacs
Requires:       emacs

%description
Veritas.el teaches Emacs the language of a Veritas suite (font-lock, Imenu,
which-function) and runs the Veritas CLI for the project, file, test or
suite at point.

%prep
%autosetup -n veritas.el-%{version}

%build
emacs -Q --batch -f batch-byte-compile veritas.el

%install
install -d %{buildroot}%{_datadir}/emacs/site-lisp
install -m 0644 veritas.el veritas.elc %{buildroot}%{_datadir}/emacs/site-lisp/

# The project-root test expects a writable project path and fails when the build runs as root, so the ERT suite is not run.
# %check omitted.

%files
%license COPYING
%doc README.org
%{_datadir}/emacs/site-lisp/veritas.el
%{_datadir}/emacs/site-lisp/veritas.elc

%changelog
