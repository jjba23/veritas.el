# veritas.el

# Copyright © Josep Bigorra <jjbigorra@gmail.com>

# veritas.el is free software: you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# veritas.el is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Lesser General Public License for more details.

# You should have received a copy of the GNU Lesser General Public License
# along with veritas.el.  If not, see <https://www.gnu.org/licenses/>.

# The package of this checkout, built with `melpaBuild' -- the builder MELPA
# itself uses, which reads the headers, writes the -pkg.el and the autoloads,
# and byte-compiles, so that `(require 'veritas)' and the autoloaded commands
# work for whoever installs it.
#
# The arguments have defaults so that `nix-build' works here; a flake that
# pins nixpkgs passes `lib' and `melpaBuild' from its own Emacs package scope
# instead, since `melpaBuild' belongs to that scope and not to `pkgs'.

{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
, melpaBuild ? pkgs.emacsPackages.melpaBuild
}:

let
  # The version is written once, in the package's own header, which is where
  # Emacs reads it.  Reading it here instead of repeating the literal is what
  # keeps a release to one edit: the derivation cannot fall behind the file.
  headerLines = builtins.filter
    (line: lib.hasPrefix ";; Version:" line)
    (lib.splitString "\n" (builtins.readFile ./veritas.el));
in
melpaBuild {
  pname = "veritas";
  version =
    if headerLines == [ ] then
      throw ''
        veritas.el has no `;; Version:' header, which is where default.nix
        reads the version from.  Put it back, or set the version by hand here.
      ''
    else
      lib.trim (lib.removePrefix ";; Version:" (builtins.head headerLines));

  # `cleanSource' because the name `melpaBuild' gives this path must not end in
  # `.el': its unpack hook reads that suffix as "a single .el file", and a
  # directory by that name would then not be found.  It also keeps .git and
  # editor backups out of the store.
  src = lib.cleanSource ./.;

  # The repository carries its tests, its README and its COPYING next to the
  # package; the package is the .el files at the top level and nothing else.
  files = ''("*.el")'';

  meta = {
    description = "Tight Emacs integration for the Veritas test framework";
    homepage = "https://codeberg.org/jjba23/veritas.el";
    license = lib.licenses.lgpl3Plus;
    maintainers = [ lib.maintainers.jjba23 ];
  };
}
