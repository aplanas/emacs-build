# emacs-build

Simple bash script to build GNU/Emacs from git in openSUSE Tumbleweed.

## Usage

    ./build.sh                  # update the sources and rebuild what changed
    ./build.sh --update         # also update the tarballs to their last version
    ./build.sh --check-updates  # report new versions of the tarballs
    ./build.sh --list           # versions and dependencies of the packages
    ./build.sh --help           # all the options

Only the packages that changed since the last build (and the ones
that depend on them, see `DEPENDS` in `build.sh`) are rebuilt.  If
the build fails, the previous installation is restored, and the
script shows the last version of the package that built, and the
packages that depend on it.  `./build.sh --restore [YYYYMMDD]` brings
back the installation of a previous day.

The packages in `build.sh` are built and installed in
`~/.local/bin/emacs-git`, nothing is installed in the system (the
rest of the libraries, like GTK or Cairo, are the system ones).  The
packages are taken from git when possible, so each build
uses their last version.  If one fails to build, pin it to the last
commit that worked with `./build.sh --pin <package>` (or to a tag,
branch or commit with `./build.sh --pin <package> <ref>`), and go back
to the default branch later with `./build.sh --unpin <package>`.  The
pins are kept in the file `pins`, and `--check-updates` shows the last
tag of the pinned packages.

The packages that only come as tarballs are verified with
`SHA256SUMS`.  `--update` moves them (and their checksums) to the
last version of the same series; a new series (like GnuTLS v3.9) is
reported by `--check-updates` and needs to be changed by hand in
`build.sh`.  Patches in
`patches/<package>/*.patch` are applied before the compilation.

Emacs is built for Wayland (PGTK) when `XDG_SESSION_TYPE` is
`wayland`, and for X11 (GTK3) otherwise.  The packages only needed by
X11 (like libXpm) are marked with `x11` in the packages list.
