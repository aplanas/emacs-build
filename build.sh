#! /bin/bash
#
# Build GNU/Emacs from git, and the libraries that it uses, into
# ~/.local/bin/emacs-git.  Nothing is installed in the system.  Run
# with --help to see the options.

set -Eeuo pipefail

DIR="$(cd "$(dirname "$0")"; pwd -P)"
SCRIPT="$DIR/$(basename "$0")"

# ----------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------

if [ -e "$HOME/.local/bin" ]; then
    PREFIX_ROOT="$HOME/.local/bin"
else
    PREFIX_ROOT="$HOME/bin"
fi
PREFIX="$PREFIX_ROOT/emacs-git"
# Copy of the installation, to restore it if the build fails.  In the
# same file system than the prefix, so it can be moved quickly
ROLLBACK="$PREFIX_ROOT/.emacs-git.rollback"
# How each package was built, to know which ones need a rebuild
STAMPS="$PREFIX/.build-stamps"

ARTIFACTS="$DIR/artifacts"
BUILD="$ARTIFACTS/build"
BACKUP_DIR="$DIR/backup"
LOG="$DIR/build.log"
CHECKSUMS="$DIR/SHA256SUMS"
PINS_FILE="$DIR/pins"
PATCHES="$DIR/patches"
CONFIG="$DIR/config"

EMACS_CONFIG="$HOME/.gnu-emacs"
EMACS_CONFIG_DIR="$HOME/.emacs.d"
PYTHON=$(readlink /usr/bin/python3)
TODAY=$(date +%Y%m%d)

WAYLAND=
[ "${XDG_SESSION_TYPE:-}" = "wayland" ] && WAYLAND=1
NATIVE_COMP=
[ -f /usr/include/libgccjit.h ] && NATIVE_COMP=1

export PATH="$PATH:$PREFIX/bin"
export PYTHONPATH="$PREFIX/lib/$PYTHON/site-packages:$PREFIX/lib64/$PYTHON/site-packages"
export PKG_CONFIG_PATH="$PREFIX/lib64/pkgconfig:$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
# Required for x11-macros
ACLOCAL_PATH="$(aclocal --print-ac-dir):$PREFIX/share/aclocal"
export ACLOCAL_PATH
export CPPFLAGS="-I$PREFIX/include"
export CFLAGS="-O2 -pipe -march=native -mtune=native -fno-omit-frame-pointer -fno-plt -flto=auto"
export LDFLAGS="-L$PREFIX/lib64 -L$PREFIX/lib -Wl,-O2 -Wl,-z,now -Wl,-z,relro -Wl,--sort-common -Wl,--as-needed -Wl,-z,pack-relative-relocs -flto=auto"
# The binaries find the libraries of the prefix without
# LD_LIBRARY_PATH.  It is not used even when compiling, as the system
# tools would load the libraries of the prefix (and tar, confined by
# AppArmor, fails to load libacl from $HOME)
export LDFLAGS="$LDFLAGS -Wl,-rpath,$PREFIX/lib64 -Wl,-rpath,$PREFIX/lib"
unset LD_LIBRARY_PATH
# Disable keyring
export PYTHON_KEYRING_BACKEND=keyring.backends.null.Keyring

# Versions of the packages that only come as tarballs (`--update`
# changes them)
declare -A VERSION=(
    ["aspell6-en"]="2026.02.25-0"
    ["aspell6-es"]="1.11-2"
    ["nettle"]="4.0"
    ["gmp"]="6.3.0"
    ["libtasn1"]="4.21.0"
    ["gnutls"]="3.8.13"
    ["giflib"]="6.1.3"
)

# ----------------------------------------------------------------------
# Packages
# ----------------------------------------------------------------------

ORDER=()
declare -A METHOD=()
declare -A SOURCE=()
declare -A DEPENDS=()
declare -A SKIPPED=()

# Declare a package, in installation order:
#
#   package NAME METHOD SOURCE [DEPENDENCY...]
#
# METHOD is 'git' or 'tarball' (built and installed), or 'mirror' (a
# git repository only kept up to date).  The dependencies are packages
# declared before; when one is rebuilt, the packages that depend on it
# are rebuilt too.  The tarballs are verified with SHA256SUMS, and the
# patches in patches/NAME/*.patch are applied before the build.
function package {
    local name="$1" method="$2" source="$3"
    shift 3
    local dep deps=()
    for dep in "$@"; do
	if [[ -v METHOD[$dep] ]]; then
	    deps+=("$dep")
	elif [[ ! -v SKIPPED[$dep] ]]; then
	    die "$name depends on $dep, that needs to be declared before"
	fi
    done
    ORDER+=("$name")
    METHOD["$name"]="$method"
    SOURCE["$name"]="$source"
    DEPENDS["$name"]="${deps[*]}"
}

# A package only used when Emacs is built for X11
function x11_package {
    if [ -n "$WAYLAND" ]; then
	SKIPPED["$1"]=1
    else
	package "$@"
    fi
}

function declare_packages {
    package aspell git https://git.savannah.gnu.org/git/aspell.git
    package aspell6-en tarball "https://ftp.gnu.org/gnu/aspell/dict/en/aspell6-en-${VERSION[aspell6-en]}.tar.bz2" aspell
    package aspell6-es tarball "https://ftp.gnu.org/gnu/aspell/dict/es/aspell6-es-${VERSION[aspell6-es]}.tar.bz2" aspell

    # GnuTLS.  From tarballs: gmp uses Mercurial, and building the git
    # versions of the rest requires the gnulib and autogen tooling
    package nettle tarball "https://ftp.gnu.org/gnu/nettle/nettle-${VERSION[nettle]}.tar.gz"
    package gmp tarball "https://gmplib.org/download/gmp/gmp-${VERSION[gmp]}.tar.xz"
    package libtasn1 tarball "https://ftp.gnu.org/gnu/libtasn1/libtasn1-${VERSION[libtasn1]}.tar.gz"
    package gnutls tarball "https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-${VERSION[gnutls]}.tar.xz" nettle gmp libtasn1

    # ACL and extended attributes
    package attr git https://git.savannah.gnu.org/git/attr.git
    package acl git https://git.savannah.gnu.org/git/acl.git attr

    # From the tarball, that includes the documentation (git would
    # require xmlto)
    package giflib tarball "https://downloads.sourceforge.net/project/giflib/giflib-6.x/giflib-${VERSION[giflib]}.tar.gz"

    # Emacs with Cairo uses its own XPM support, but `configure`
    # requires libXpm to enable it.  PGTK always has it
    x11_package macros git https://gitlab.freedesktop.org/xorg/util/macros.git
    x11_package libxpm git https://gitlab.freedesktop.org/xorg/lib/libxpm.git macros

    # ImageMagick delegates: JPEG XL, HEIC, JPEG 2000 and RAW images
    package brotli git https://github.com/google/brotli.git
    package highway git https://github.com/google/highway.git
    package libjxl git https://github.com/libjxl/libjxl.git brotli highway
    package libde265 git https://github.com/strukturag/libde265.git
    package libheif git https://github.com/strukturag/libheif.git libde265
    package openjpeg git https://github.com/uclouvain/openjpeg.git
    package LibRaw git https://github.com/LibRaw/LibRaw.git
    package ImageMagick git https://github.com/ImageMagick/ImageMagick.git libjxl libheif openjpeg LibRaw

    package tree-sitter git https://github.com/tree-sitter/tree-sitter.git

    package emacs git https://git.savannah.gnu.org/git/emacs.git gnutls gmp attr acl giflib libxpm ImageMagick tree-sitter
    package elpa mirror https://git.savannah.gnu.org/git/emacs/elpa.git
    package nongnu mirror https://git.savannah.gnu.org/git/emacs/nongnu.git
    package org-mode mirror https://git.savannah.gnu.org/git/emacs/org-mode.git

    # Typst
    # Compile with
    #  gcc -fPIC -std=c99 -c parser.c
    #  gcc -fPIC -std=c99 -c scanner.c
    #  gcc -shared parser.o scanner.o  -o libtree-sitter-typst.so
    # package tree-sitter-typst git https://github.com/uben0/tree-sitter-typst.git
    # package tinymist git https://github.com/Myriad-Dreamin/tinymist.git
}

# Lisp files (not in MELPA) installed in ~/.emacs.d/lisp
LISP_FILES=(
    "https://raw.githubusercontent.com/nemethf/eglot-x/master/eglot-x.el"
)

# Python packages, always installed in their last version
PIP_PACKAGES=(
    "wheel"
    "python-lsp-server[all]"
    "pylsp-mypy"
    "pyls-isort"
    "python-lsp-black"
    # "pyls-memestra"
    "pylsp-rope"
    "python-lsp-ruff"
)

# Options for the build (configure or cmake)
declare -A OPTIONS=(
    ["gnutls"]="--with-included-unistring"
    ["libxpm"]="--disable-open-zfile"
    ["highway"]="-DHWY_ENABLE_TESTS=OFF -DHWY_ENABLE_EXAMPLES=OFF"
    ["libjxl"]="-DJPEGXL_FORCE_SYSTEM_BROTLI=ON -DJPEGXL_FORCE_SYSTEM_HWY=ON -DJPEGXL_FORCE_SYSTEM_LCMS2=ON -DJPEGXL_ENABLE_SKCMS=OFF -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_JPEGLI=OFF -DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_MANPAGES=OFF -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_OPENEXR=OFF -DJPEGXL_ENABLE_PLUGINS=OFF -DJPEGXL_ENABLE_JNI=OFF -DJPEGXL_ENABLE_FUZZERS=OFF -DJPEGXL_ENABLE_DEVTOOLS=OFF -DJPEGXL_BUNDLE_LIBPNG=OFF"
    ["libde265"]="-DENABLE_SDL=OFF -DENABLE_ENCODER=OFF -DENABLE_SHERLOCK265=OFF"
    ["libheif"]="-DWITH_LIBDE265=ON -DWITH_X265=OFF -DWITH_AOM_DECODER=OFF -DWITH_AOM_ENCODER=OFF -DWITH_DAV1D=OFF -DWITH_RAV1E=OFF -DWITH_SvtEnc=OFF -DWITH_FFMPEG_DECODER=OFF -DWITH_OpenJPEG_DECODER=OFF -DWITH_OpenJPEG_ENCODER=OFF -DWITH_OPENJPH_ENCODER=OFF -DWITH_KVAZAAR=OFF -DWITH_UVG266=OFF -DWITH_VVDEC=OFF -DWITH_VVENC=OFF -DWITH_GDK_PIXBUF=OFF -DWITH_GNOME=OFF -DWITH_EXAMPLES=OFF -DENABLE_PLUGIN_LOADING=OFF"
    ["openjpeg"]="-DBUILD_CODEC=OFF"
    ["LibRaw"]="--disable-examples"
    ["emacs"]="--with-cairo --without-xft --with-harfbuzz --without-libotf --with-gnutls --without-xdbe --without-xim --without-gpm --disable-gc-mark-trace --enable-link-time-optimization --with-gsettings --with-modules --with-threads --with-libgmp --with-xml2 --with-tree-sitter --with-zlib --without-included-regex --with-file-notification=inotify --without-compress-install --with-imagemagick"
)
# Everything that is not Wayland (like a build from a TTY or SSH) is
# built for X11
if [ -n "$WAYLAND" ]; then
    OPTIONS["emacs"]+=" --without-x --with-pgtk --with-toolkit-scroll-bars"
else
    OPTIONS["emacs"]+=" --with-x --with-x-toolkit=gtk3 --with-xpm"
fi
if [ -n "$NATIVE_COMP" ]; then
    OPTIONS["emacs"]+=" --with-native-compilation"
fi

# ----------------------------------------------------------------------
# Messages and errors
# ----------------------------------------------------------------------

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
RESET="\033[0m"

# Package being processed, for the error messages
CURRENT=
SUCCESS=
WARNINGS=()

function say {
    local color="$1" tag="$2"
    shift 2
    echo -e "${color}${tag}${RESET} $*"
}

function die {
    say "$RED" ERROR "$@"
    exit 1
}

# A problem that does not stop the build, repeated at the end
function warning {
    say "$YELLOW" WARNING "$@"
    WARNINGS+=("$*")
}

# Run a command with its output in the log
function run {
    echo "+ $*" >>"$LOG"
    "$@" >>"$LOG" 2>&1
}

function on_error {
    # Only once, and not from the subshells
    if [ "$BASH_SUBSHELL" -eq 0 ]; then
	say "$RED" ERROR "on line $1${CURRENT:+ ($CURRENT)}"
    fi
}

# If the build fails, show why, and restore the previous installation
function on_exit {
    local status=$?
    [ -n "$SUCCESS" ] && return
    trap - ERR

    if [ -s "$LOG" ]; then
	say "$RED" FAILED "${CURRENT:+processing $CURRENT, }last lines of $LOG:"
	tail -n 30 "$LOG"
    fi
    if [[ -n "$CURRENT" && -v METHOD[$CURRENT] ]]; then
	failure_hint "$CURRENT"
    fi
    if [ -d "$ROLLBACK" ]; then
	say "$YELLOW" RESTORING "previous installation"
	rm -fr "$PREFIX"
	mv "$ROLLBACK" "$PREFIX"
    fi
    exit "$status"
}

# ----------------------------------------------------------------------
# Package state
# ----------------------------------------------------------------------

# The git packages follow their default branch, unless they are pinned
# to a tag, branch or commit in the pins file (one "PACKAGE REF" per
# line).  Edited with --pin and --unpin
declare -A PINS=()
function read_pins {
    local name ref
    [ -f "$PINS_FILE" ] || return 0
    while read -r name ref _; do
	if [[ -n "$name" && "$name" != \#* && -n "${ref:-}" ]]; then
	    PINS["$name"]="$ref"
	fi
    done < "$PINS_FILE"
}

function tarball_file {
    echo "$ARTIFACTS/$(basename "${SOURCE[$1]}")"
}

# The version of the source: the commit for git, the file otherwise
function source_version {
    if [ "${METHOD[$1]}" = "git" ]; then
	git -C "$ARTIFACTS/$1" rev-parse HEAD
    else
	basename "${SOURCE[$1]}"
    fi
}

# Identify how a package is built: the source, the options, the
# patches, the build functions and the dependencies.  A change in any
# of them requires a rebuild
declare -A STAMP_OF=()
function package_stamp {
    local name="$1" dep
    {
	source_version "$name"
	echo "${OPTIONS[$name]:-}"
	echo "$PREFIX $CPPFLAGS $CFLAGS $LDFLAGS"
	cat "$PATCHES/$name"/*.patch 2>/dev/null || true
	declare -f "build_${name//-/_}" build_autotools build_cmake build_make || true
	for dep in ${DEPENDS[$name]}; do
	    echo "$dep ${STAMP_OF[$dep]}"
	done
    } | sha256sum | cut -d' ' -f1
}

# The last version of a package that was built.  With --clean the
# stamps are in the copy of the previous installation
function last_good {
    local file
    for file in "$STAMPS/$1.source" "$ROLLBACK/.build-stamps/$1.source"; do
	if [ -f "$file" ]; then
	    cat "$file"
	    return
	fi
    done
}

# Packages that depend on a package, directly or not
function dependents {
    local -A affected=(["$1"]=1)
    local name dep result=()
    for name in "${ORDER[@]}"; do
	for dep in ${DEPENDS[$name]}; do
	    if [[ -v affected[$dep] ]]; then
		affected["$name"]=1
		result+=("$name")
		break
	    fi
	done
    done
    echo "${result[*]}"
}

# Explain how to go back to the version of a package that worked
function failure_hint {
    local name="$1" good affected
    good=$(last_good "$name")
    if [ -z "$good" ]; then
	echo "There is no previous build of $name"
    elif [ "${METHOD[$name]}" = "git" ]; then
	echo "The last version of $name that built is $good"
	echo "To build it again: ./$(basename "$0") --pin $name   (and --unpin $name later)"
    else
	echo "The last version of $name that built is $good: set it back in VERSION"
    fi
    affected=$(dependents "$name")
    if [ -n "$affected" ]; then
	echo "Packages that depend on $name (rebuilt with it): $affected"
    fi
}

# ----------------------------------------------------------------------
# Sources
# ----------------------------------------------------------------------

# Run the automatic gc / maintenance in the foreground, so it does not
# modify the objects while the repository is cloned for the build
GIT=(git -c gc.autoDetach=false -c maintenance.autoDetach=false)

# Fetch the git repositories in parallel (it is slow, but not for the
# CPU), then update the working copies and download the rest
declare -A FETCHED=()
function fetch_sources {
    local name url tmp

    if [ -z "$OPT_OFFLINE" ]; then
	tmp=$(mktemp -d "$ARTIFACTS/.fetch.XXXXXX")
	for name in "${ORDER[@]}"; do
	    [[ "${METHOD[$name]}" != "tarball" && -d "$ARTIFACTS/$name" ]] || continue
	    say "$GREEN" UPDATING "$name repository"
	    # The tags are forced, as some projects move them (nightly)
	    ( "${GIT[@]}" -C "$ARTIFACTS/$name" fetch --all --tags -p --force >"$tmp/$name" 2>&1 \
		  && touch "$tmp/$name.ok" ) &
	    while [ "$(jobs -rp | wc -l)" -ge 8 ]; do
		wait -n || true
	    done
	done
	wait
	for name in "${ORDER[@]}"; do
	    [ -f "$tmp/$name" ] || continue
	    cat "$tmp/$name" >>"$LOG"
	    if [ -f "$tmp/$name.ok" ]; then
		FETCHED["$name"]=1
	    else
		# Build the local copy if the server is not available
		warning "fetching $name failed, using the local copy (check $LOG)"
	    fi
	done
	rm -fr "$tmp"
    fi

    for name in "${ORDER[@]}"; do
	CURRENT="$name"
	if [ "${METHOD[$name]}" = "tarball" ]; then
	    fetch_file "${SOURCE[$name]}"
	else
	    update_repository "$name"
	fi
    done
    for url in "${LISP_FILES[@]}"; do
	CURRENT="$(basename "$url")"
	fetch_file "$url"
    done
    CURRENT=
}

function update_repository {
    local name="$1" repo="$ARTIFACTS/$1" pin="${PINS[$1]:-}" branch

    if [ ! -d "$repo" ]; then
	[ -z "$OPT_OFFLINE" ] || die "$name repository not found (offline)"
	say "$YELLOW" CLONING "$name repository"
	run git clone "${SOURCE[$name]}" "$repo"
    fi

    if [ -n "$pin" ]; then
	say "$BLUE" PINNED "$name to $pin"
	run git -C "$repo" checkout -q --detach "$pin" || die "$name has no $pin, check $PINS_FILE"
	return
    fi

    # Return to the default branch if the package was pinned
    if ! git -C "$repo" symbolic-ref -q HEAD >/dev/null; then
	branch=$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD || true)
	if [ -z "$branch" ]; then
	    run git -C "$repo" remote set-head origin --auto
	    branch=$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD)
	fi
	run git -C "$repo" checkout -q "${branch#origin/}"
    fi
    if [[ -v FETCHED[$name] ]]; then
	run "${GIT[@]}" -C "$repo" rebase -q '@{upstream}' || die "updating $name repository, check $LOG"
    fi
}

# Download a file (if it is not there), and verify its checksum
function fetch_file {
    local url="$1" file
    file="$ARTIFACTS/$(basename "$url")"
    if [ ! -f "$file" ]; then
	[ -z "$OPT_OFFLINE" ] || die "$(basename "$file") not found (offline)"
	say "$YELLOW" DOWNLOADING "$(basename "$file")"
	# Into a temporary file, so an interrupted download is not taken
	# as a complete one
	run wget -O "$file.part" "$url"
	mv "$file.part" "$file"
    fi
    verify_checksum "$file"
}

function verify_checksum {
    local file="$1" name expected actual
    name=$(basename "$file")
    expected=$(awk -v f="$name" '$2 == f { print $1 }' "$CHECKSUMS")
    actual=$(sha256sum "$file" | cut -d' ' -f1)
    if [ -z "$expected" ]; then
	die "no checksum for $name in $CHECKSUMS.  If the file is legit, add this line:\n$actual  $name"
    elif [ "$expected" != "$actual" ]; then
	rm -f "$file"
	die "checksum mismatch for $name, the file was removed"
    fi
}

# ----------------------------------------------------------------------
# Build
# ----------------------------------------------------------------------

MAKE_JOBS=()

function build_autotools {
    local options="$1" status=0
    if [ ! -f configure ]; then
	if [ -f autogen.sh ]; then
	    run ./autogen.sh $options --prefix "$PREFIX"
	else
	    run autoreconf -i
	fi
    fi
    run ./configure $options --prefix "$PREFIX"
    run make "${MAKE_JOBS[@]}"
    # Strip the binaries if the Makefile can
    make -q install-strip &>/dev/null || status=$?
    if [ "$status" -lt 2 ]; then
	run make install-strip
    else
	run make install
    fi
}

function build_cmake {
    local options="$1"
    # gcc-ar and gcc-ranlib can handle the LTO objects
    run cmake -S . -B _build -G Ninja -DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX" \
	-DCMAKE_INSTALL_RPATH="$PREFIX/lib64;$PREFIX/lib" \
	-DCMAKE_AR="$(command -v gcc-ar)" -DCMAKE_RANLIB="$(command -v gcc-ranlib)" \
	-DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF $options
    run cmake --build _build -j "$JOBS"
    run cmake --install _build --strip
}

function build_make {
    run make "${MAKE_JOBS[@]}"
    run env PREFIX="$PREFIX" make install
}

# Build functions for specific packages: build_<name>, with the dashes
# replaced by underscores
function build_aspell_dictionary {
    run ./configure
    run make "${MAKE_JOBS[@]}"
    run make install
}

function build_aspell6_en {
    build_aspell_dictionary
}

function build_aspell6_es {
    build_aspell_dictionary
}

function build_giflib {
    run make "${MAKE_JOBS[@]}"
    run make PREFIX="$PREFIX" LIBDIR="$PREFIX/lib64" install
}

function build_emacs {
    local options="$1"
    run ./autogen.sh git
    run ./autogen.sh autoconf
    run ./configure $options --prefix "$PREFIX"
    run make "${MAKE_JOBS[@]}"
    # Remove the previous version, so no old file (like the Lisp files
    # removed upstream) is left.  Done after the compilation, so the
    # installed Emacs can be used meanwhile
    rm -fr "$PREFIX"/share/emacs "$PREFIX"/lib/emacs "$PREFIX"/lib64/emacs "$PREFIX"/libexec/emacs "$PREFIX"/bin/emacs-[0-9]*
    run make install-strip
}

# Copy the source of a package into $BUILD
function prepare_source {
    local name="$1" tmp top
    rm -fr "$BUILD"
    if [ "${METHOD[$name]}" = "git" ]; then
	# Share the objects with the repository: only the working tree
	# is copied
	run git clone -q --shared "$ARTIFACTS/$name" "$BUILD"
	run git -C "$BUILD" checkout -q --detach "$(source_version "$name")"
    else
	tmp="$ARTIFACTS/.extract"
	rm -fr "$tmp"
	mkdir "$tmp"
	run tar -xf "$(tarball_file "$name")" -C "$tmp"
	top=("$tmp"/*)
	[[ ${#top[@]} -eq 1 && -d "${top[0]}" ]] || die "the tarball of $name has not a single directory"
	mv "${top[0]}" "$BUILD"
	rmdir "$tmp"
    fi

    local patch
    for patch in "$PATCHES/$name"/*.patch; do
	[ -f "$patch" ] || continue
	say "$BLUE" PATCHING "$name with $(basename "$patch")"
	# Fail, instead of asking, if the patch does not apply
	run patch -d "$BUILD" -p1 --batch --forward -i "$patch"
    done
}

# Build and install a package from $BUILD
function build_in_place {
    local name="$1" options="${OPTIONS[$1]:-}" function="build_${1//-/_}"
    if declare -F "$function" >/dev/null; then
	say "$GREEN" COMPILING "$name"
	"$function" "$options"
    elif [ -f configure.ac ] || [ -f configure.sh ] || [ -f autogen.sh ]; then
	say "$GREEN" COMPILING "$name (autotools)"
	build_autotools "$options"
    elif [ -f Makefile ]; then
	say "$GREEN" COMPILING "$name (make)"
	build_make
    elif [ -f CMakeLists.txt ]; then
	say "$GREEN" COMPILING "$name (cmake)"
	build_cmake "$options"
    else
	die "unknown build system for $name"
    fi
}

function build_package {
    local name="$1"
    prepare_source "$name"
    ( cd "$BUILD" && build_in_place "$name" )
    rm -fr "$BUILD"
    mkdir -p "$STAMPS"
    echo "${STAMP_OF[$name]}" > "$STAMPS/$name"
    source_version "$name" > "$STAMPS/$name.source"
}

# Decide which packages to build: the new or changed ones, and the
# ones that depend on them
declare -A REBUILD=()
function plan_builds {
    local name dep old
    for name in "${ORDER[@]}"; do
	[ "${METHOD[$name]}" = "mirror" ] && continue
	STAMP_OF["$name"]=$(package_stamp "$name")
	old=
	[ -f "$STAMPS/$name" ] && old=$(<"$STAMPS/$name")
	if [[ -n "$OPT_CLEAN" || -v FORCE[$name] || "${STAMP_OF[$name]}" != "$old" ]]; then
	    REBUILD["$name"]=1
	fi
	for dep in ${DEPENDS[$name]}; do
	    if [[ -v REBUILD[$dep] ]]; then
		REBUILD["$name"]=1
	    fi
	done
    done
}

# ----------------------------------------------------------------------
# Installation
# ----------------------------------------------------------------------

# Keep a copy of the installation, to restore it if the build fails.
# With --clean the installation is moved, to build in an empty prefix
function snapshot_prefix {
    rm -fr "$ROLLBACK"
    [ -d "$PREFIX" ] || return 0
    if [ -n "$OPT_CLEAN" ]; then
	mv "$PREFIX" "$ROLLBACK"
    else
	say "$GREEN" SNAPSHOT "current installation"
	cp -a --reflink=auto "$PREFIX" "$ROLLBACK"
    fi
}

# After a successful build, the previous installation is the backup of
# the day
function release_snapshot {
    local backup="$BACKUP_DIR/emacs-git_$TODAY"
    [ -d "$ROLLBACK" ] || return 0
    if [ -d "$backup" ]; then
	rm -fr "$ROLLBACK"
    else
	say "$GREEN" BACKUP "previous installation to $backup"
	mkdir -p "$BACKUP_DIR"
	mv "$ROLLBACK" "$backup"
    fi
}

# Move a file to the backup of the day, if there is not one already
function backup_once {
    local file="$1" backup="$2"
    if [ -e "$file" ] && [ ! -e "$backup" ]; then
	say "$GREEN" BACKUP "$file to $backup"
	mv "$file" "$backup"
    fi
}

function install_config {
    local backup="$BACKUP_DIR/.emacs.d_$TODAY" url
    mkdir -p "$BACKUP_DIR"
    backup_once "$EMACS_CONFIG" "$BACKUP_DIR/.gnu-emacs_$TODAY"
    backup_once "$PREFIX_ROOT/emacs" "$BACKUP_DIR/emacs_shim_$TODAY"
    if [ -d "$EMACS_CONFIG_DIR" ] && [ ! -d "$backup" ]; then
	backup_once "$EMACS_CONFIG_DIR" "$backup"
	# Recover some files from the backup
	mkdir -p "$EMACS_CONFIG_DIR"
	cp -a "$backup/ido.last" "$backup/network-security.data" "$EMACS_CONFIG_DIR" 2>/dev/null || true
    fi
    mkdir -p "$EMACS_CONFIG_DIR/lisp"

    cp "$CONFIG/gnu-emacs.el" "$EMACS_CONFIG"
    if [ -n "$NATIVE_COMP" ]; then
	# Check https://www.jamescherti.com/compiling-emacs/
	cp "$CONFIG/early-init.el" "$EMACS_CONFIG_DIR/early-init.el"
	# The native code of a previous Emacs is not valid anymore
	if [[ -v REBUILD[emacs] ]]; then
	    find "$EMACS_CONFIG_DIR/" -name '*.eln' -delete
	fi
    fi
    for url in "${LISP_FILES[@]}"; do
	cp "$ARTIFACTS/$(basename "$url")" "$EMACS_CONFIG_DIR/lisp"
    done
}

# A script that runs a program from the prefix with its environment
function create_shim {
    local program="$1" shim="$2"
    rm -f "$shim"
    cat >"$shim" <<EOF
#! /bin/sh

if [ -z \$PYTHONPATH ]; then
    export PYTHONPATH=$PREFIX/lib64/$PYTHON/site-packages:$PREFIX/lib/$PYTHON/site-packages
else
    export PYTHONPATH=\$PYTHONPATH:$PREFIX/lib64/$PYTHON/site-packages:$PREFIX/lib/$PYTHON/site-packages
fi

export PATH=$PREFIX/bin:\$PATH

$program "\$@"
EOF
    chmod a+x "$shim"
}

function install_links {
    ln -srf "$PREFIX"/bin/* "$PREFIX_ROOT"
    # Remove the links to programs not installed anymore
    find "$PREFIX_ROOT" -maxdepth 1 -xtype l -lname "$(basename "$PREFIX")/*" -delete
    create_shim "$PREFIX/bin/emacs" "$PREFIX_ROOT/emacs"
    create_shim "$PREFIX/bin/pylsp" "$PREFIX_ROOT/pylsp-remote"
    # Ghostscript without the libraries of the prefix
    rm -f "$PREFIX_ROOT/gs"
    printf '#! /bin/sh\n\nLD_LIBRARY_PATH= /usr/bin/gs "$@"\n' >"$PREFIX_ROOT/gs"
    chmod a+x "$PREFIX_ROOT/gs"
}

# Warn about the binaries installed now that do not find their
# libraries without LD_LIBRARY_PATH
function check_libraries {
    local start="$1" file missing
    while IFS= read -r -d '' file; do
	cmp -s -n 4 "$file" <(printf '\177ELF') || continue
	missing=$(ldd "$file" 2>/dev/null | grep 'not found' || true)
	if [ -n "$missing" ]; then
	    warning "missing libraries for $file:\n$missing"
	fi
    done < <(find "$PREFIX"/bin "$PREFIX"/lib "$PREFIX"/lib64 "$PREFIX"/libexec -type f \
		  \( -perm -u+x -o -name '*.so*' \) -newer "$start" -print0 2>/dev/null)
}

# ----------------------------------------------------------------------
# New versions
# ----------------------------------------------------------------------

# Print the directory listing of an URL.  The downloads of SourceForge
# are listed in a different place
function list_url {
    local url="$1"
    if [[ "$url" =~ ^https?://downloads\.sourceforge\.net/project/([^/]+)/?(.*)$ ]]; then
	url="https://sourceforge.net/projects/${BASH_REMATCH[1]}/files/${BASH_REMATCH[2]}"
    fi
    wget -q -O- "${url%/}/" || true
}

# Print the newest version of the files named BASE-VERSION.EXT in the
# directory listing of an URL
function newest_version {
    local url="$1" base="${2//./\\.}"
    list_url "$url" \
	| grep -oE "${base}-[0-9][0-9.-]*[0-9]\.(tar\.(gz|bz2|xz)|tgz|tbz|txz)" \
	| sed -E "s/^${base}-//; s/\.(tar\.(gz|bz2|xz)|tgz|tbz|txz)\$//" \
	| sort -uV | tail -n 1 || true
}

function newest_tag {
    git ls-remote --tags --refs "$1" 2>/dev/null \
	| sed -E 's#.*refs/tags/v?##' | grep -E '^[0-9]+(\.[0-9]+)+$' | sort -V | tail -n 1 || true
}

function is_newer {
    local version="$1" newest="$2"
    [ -n "$newest" ] && [ "$newest" != "$version" ] \
	&& [ "$(printf '%s\n' "$version" "$newest" | sort -V | tail -n 1)" = "$newest" ]
}

# The newest version of a tarball package, in the same directory
function newest_tarball {
    local name="$1" file
    file=$(basename "${SOURCE[$name]}")
    newest_version "$(dirname "${SOURCE[$name]}")" "${file%%-"${VERSION[$name]}"*}"
}

# Some projects use a directory per series (like v3.8 or giflib-6.x):
# print a newer one, if any
function newest_series {
    local name="$1" dir series pattern parent newest file
    dir=$(dirname "${SOURCE[$name]}")
    series=$(basename "$dir")
    [[ "$series" =~ [0-9] ]] || return 0
    pattern=$(sed -E 's/\./\\./g; s/[0-9]+/[0-9]+/g' <<< "$series")
    parent=$(dirname "$dir")
    newest=$(list_url "$parent" | grep -oE "(^|[\"/>])${pattern}([\"/<]|\$)" \
		 | grep -oE "$pattern" | sort -uV | tail -n 1 || true)
    if is_newer "$series" "$newest"; then
	file=$(basename "${SOURCE[$name]}")
	echo "$newest (version $(newest_version "$parent/$newest" "${file%%-"${VERSION[$name]}"*}")), in $parent/$newest"
    fi
}

# ----------------------------------------------------------------------
# Commands
# ----------------------------------------------------------------------

function usage {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Build GNU/Emacs and its dependencies from source.  Only the packages
that changed since the last build (and the ones that depend on them)
are rebuilt.  If the build fails, the previous installation is restored.

Options:
  --clean          Rebuild all the packages into an empty prefix
  --rebuild PKG    Force the rebuild of PKG (can be used several times)
  --offline        Do not update the sources, nor install pip packages
  --update         Update the tarball packages to their last version
                   (and their checksums), and build
  --check-updates  Report new versions of the packages, and exit
  --list           Show the packages, their versions and dependencies, and exit
  --pin PKG [REF]  Build the git package PKG from REF (a tag, branch or
                   commit; by default the last one that built), and exit
  --unpin PKG      Build PKG again from its default branch, and exit
  --restore [DATE] Restore the installation from the backup of DATE
                   (YYYYMMDD, by default the last one), and exit
  -j, --jobs N     Number of parallel jobs (default: $(nproc))
  -h, --help       Show this help
EOF
}

function cmd_list {
    local name version built
    for name in "${ORDER[@]}"; do
	case "${METHOD[$name]}" in
	    tarball) version=$(basename "${SOURCE[$name]}") ;;
	    *) version=$(git -C "$ARTIFACTS/$name" describe --tags --always 2>/dev/null || echo "not cloned") ;;
	esac
	[[ -v PINS[$name] ]] && version+=" (pinned to ${PINS[$name]})"
	echo -e "${GREEN}$name${RESET} [${METHOD[$name]}] $version"
	built=$(last_good "$name")
	if [ -n "$built" ]; then
	    if [ "${METHOD[$name]}" = "git" ]; then
		built=$(git -C "$ARTIFACTS/$name" describe --tags --always "$built" 2>/dev/null || echo "$built")
	    fi
	    echo "    last built: $built"
	fi
	[ -z "${DEPENDS[$name]}" ] || echo "    depends on: ${DEPENDS[$name]}"
	[ -z "$(dependents "$name")" ] || echo "    needed by:  $(dependents "$name")"
    done
    echo -e "${GREEN}Python packages${RESET} [pip] ${PIP_PACKAGES[*]}"
}

function cmd_check_updates {
    local name newest series
    for name in "${ORDER[@]}"; do
	if [[ -v PINS[$name] ]]; then
	    say "$YELLOW" PINNED "$name: ${PINS[$name]} (last tag: $(newest_tag "${SOURCE[$name]}"))"
	fi
	[ "${METHOD[$name]}" = "tarball" ] || continue
	newest=$(newest_tarball "$name")
	if [ -z "$newest" ]; then
	    say "$YELLOW" UNKNOWN "$name: no versions found in $(dirname "${SOURCE[$name]}")"
	elif is_newer "${VERSION[$name]}" "$newest"; then
	    say "$BLUE" "NEW VERSION" "$name: ${VERSION[$name]} -> $newest"
	else
	    say "$GREEN" "UP TO DATE" "$name: ${VERSION[$name]}"
	fi
	series=$(newest_series "$name")
	[ -z "$series" ] || say "$BLUE" "NEW SERIES" "$name: $series"
    done
    echo "To update the tarballs to the last version in the same series: ./$(basename "$0") --update"
    echo "The git packages follow their default branch, unless they are pinned (--pin)"
}

# Change the versions of the tarball packages in this script, and add
# the checksums of the new files (trusted, downloaded with HTTPS)
function update_versions {
    local name newest url file old
    mkdir -p "$ARTIFACTS"
    for name in "${ORDER[@]}"; do
	[ "${METHOD[$name]}" = "tarball" ] || continue
	newest=$(newest_tarball "$name")
	if ! is_newer "${VERSION[$name]}" "$newest"; then
	    say "$GREEN" "UP TO DATE" "$name: ${VERSION[$name]}"
	    continue
	fi
	say "$BLUE" UPDATING "$name: ${VERSION[$name]} -> $newest"
	url="${SOURCE[$name]//${VERSION[$name]}/$newest}"
	file="$ARTIFACTS/$(basename "$url")"
	if ! wget -q -O "$file.part" "$url"; then
	    rm -f "$file.part"
	    warning "download of $url failed, $name not updated"
	    continue
	fi
	mv "$file.part" "$file"
	old=$(basename "${SOURCE[$name]}")
	awk -v old="$old" -v new="$(basename "$file")" '$2 != old && $2 != new' "$CHECKSUMS" >"$CHECKSUMS.new"
	echo "$(sha256sum "$file" | cut -d' ' -f1)  $(basename "$file")" >>"$CHECKSUMS.new"
	mv "$CHECKSUMS.new" "$CHECKSUMS"
	sed -i "s|^\([[:space:]]*\[\"$name\"\]=\)\"${VERSION[$name]//./\\.}\"|\1\"$newest\"|" "$SCRIPT"
    done
}

# Pin a git package to a ref, or unpin it if the ref is empty
function cmd_pin {
    local name="$1" ref="$2"
    [ "${METHOD[$name]:-}" = "git" ] || die "$name is not a git package"
    [ -f "$PINS_FILE" ] || echo "# PACKAGE TAG, BRANCH OR COMMIT" >"$PINS_FILE"
    awk -v n="$name" '$1 != n' "$PINS_FILE" >"$PINS_FILE.new"
    if [ -n "$ref" ]; then
	echo "$name $ref" >>"$PINS_FILE.new"
	say "$BLUE" PINNED "$name to $ref, used in the next build"
    else
	say "$BLUE" UNPINNED "$name, the next build uses its default branch"
    fi
    mv "$PINS_FILE.new" "$PINS_FILE"
}

# The backups were installed in the same prefix, so they can be copied
# back.  The current installation is restored if this fails
function cmd_restore {
    local backup="$BACKUP_DIR/emacs-git_$1"
    if [ "$1" = "last" ]; then
	backup=$(find "$BACKUP_DIR" -maxdepth 1 -type d -name 'emacs-git_*' 2>/dev/null | sort | tail -n 1)
    fi
    [[ -n "$backup" && -d "$backup" ]] || die "backup ${backup:-of the installation} not found in $BACKUP_DIR"

    say "$YELLOW" RESTORING "installation from $backup"
    rm -fr "$ROLLBACK"
    if [ -d "$PREFIX" ]; then
	mv "$PREFIX" "$ROLLBACK"
    fi
    cp -a --reflink=auto "$backup" "$PREFIX"
    install_links
    rm -fr "$ROLLBACK"
    echo "The configuration backups ($(basename "$EMACS_CONFIG"), $(basename "$EMACS_CONFIG_DIR")) are also in $BACKUP_DIR"
}

function cmd_build {
    local name tool start="$ARTIFACTS/.build-start"

    for tool in git wget tar patch make cmake ninja gcc g++ autoreconf pip ldd; do
	command -v "$tool" >/dev/null || die "$tool is required"
    done
    for name in "${OPT_REBUILD[@]}"; do
	[[ -v METHOD[$name] && "${METHOD[$name]}" != "mirror" ]] || die "unknown package $name"
	FORCE["$name"]=1
    done
    # Installations from older versions of this script do not have
    # stamps: build everything from scratch
    [ -d "$STAMPS" ] || OPT_CLEAN=1

    mkdir -p "$ARTIFACTS"
    touch "$start"
    fetch_sources
    plan_builds

    if [[ ${#REBUILD[@]} -gt 0 || -z "$OPT_OFFLINE" ]]; then
	snapshot_prefix
    fi
    for name in "${ORDER[@]}"; do
	[ "${METHOD[$name]}" = "mirror" ] && continue
	if [[ -v REBUILD[$name] ]]; then
	    CURRENT="$name"
	    build_package "$name"
	else
	    say "$GREEN" "UP TO DATE" "$name"
	fi
    done
    if [ -n "$OPT_OFFLINE" ]; then
	say "$YELLOW" SKIPPING "Python packages (offline)"
    else
	CURRENT="Python packages"
	say "$GREEN" INSTALLING "Python packages"
	run pip install -I --prefix="$PREFIX" "${PIP_PACKAGES[@]}"
    fi

    CURRENT="configuration"
    install_config
    install_links
    check_libraries "$start"
    release_snapshot
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

COMMAND=build
OPT_CLEAN=
OPT_OFFLINE=
OPT_REBUILD=()
declare -A FORCE=()
PIN_NAME=
PIN_REF=
RESTORE_DATE=
JOBS="$(nproc)"
ARGS=("$@")
while [ $# -gt 0 ]; do
    case "$1" in
	--clean) OPT_CLEAN=1 ;;
	--offline) OPT_OFFLINE=1 ;;
	--rebuild) [ $# -ge 2 ] || { usage; exit 1; }; OPT_REBUILD+=("$2"); shift ;;
	--update) COMMAND=update ;;
	--check-updates) COMMAND=check-updates ;;
	--list) COMMAND=list ;;
	--pin|--unpin)
	    [ $# -ge 2 ] || { usage; exit 1; }
	    COMMAND="${1#--}"
	    PIN_NAME="$2"
	    shift
	    if [[ "$COMMAND" = "pin" && $# -ge 2 && "$2" != -* ]]; then
		PIN_REF="$2"
		shift
	    fi
	    ;;
	--restore)
	    COMMAND=restore
	    RESTORE_DATE=last
	    if [[ "${2:-}" =~ ^[0-9]{8}$ ]]; then
		RESTORE_DATE="$2"
		shift
	    fi
	    ;;
	-j|--jobs) [ $# -ge 2 ] || { usage; exit 1; }; JOBS="$2"; shift ;;
	-h|--help) usage; exit 0 ;;
	*) usage; exit 1 ;;
    esac
    shift
done
MAKE_JOBS=(-j "$JOBS" -l "$(nproc --ignore=1)")

declare_packages
read_pins

case "$COMMAND" in
    list) cmd_list; exit 0 ;;
    check-updates) cmd_check_updates; exit 0 ;;
esac

# The rest of the commands change files: one at a time
exec 9>"$DIR/.build.lock"
flock -n 9 || die "another build is running"

case "$COMMAND" in
    pin)
	if [ -z "$PIN_REF" ]; then
	    PIN_REF=$(last_good "$PIN_NAME")
	    [ -n "$PIN_REF" ] || die "there is no build of $PIN_NAME, give the tag, branch or commit"
	fi
	cmd_pin "$PIN_NAME" "$PIN_REF"
	exit 0
	;;
    unpin)
	cmd_pin "$PIN_NAME" ""
	exit 0
	;;
    update)
	# Change the versions, and run again without --update to build
	update_versions
	args=()
	for arg in "${ARGS[@]}"; do
	    [ "$arg" = "--update" ] || args+=("$arg")
	done
	exec "$SCRIPT" "${args[@]}"
	;;
esac

: >"$LOG"
trap 'on_error $LINENO' ERR
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# A previous build was killed before restoring the installation
if [ -d "$ROLLBACK" ]; then
    say "$YELLOW" RESTORING "installation from an interrupted build"
    rm -fr "$PREFIX"
    mv "$ROLLBACK" "$PREFIX"
fi

if [ "$COMMAND" = "restore" ]; then
    cmd_restore "$RESTORE_DATE"
else
    cmd_build
fi
SUCCESS=1

for message in "${WARNINGS[@]}"; do
    say "$YELLOW" WARNING "$message"
done
say "$BLUE" DONE ""
