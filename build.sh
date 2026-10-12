#! /bin/bash

set -Eeuo pipefail

DIR="$(cd "$(dirname "$0")"; pwd -P)"

function usage {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Build GNU/Emacs and its dependencies from source.  Only the packages
that changed since the last build (and the ones installed after them)
are rebuilt.  If the build fails, the previous installation is restored.

Options:
  --clean          Rebuild all the packages into an empty prefix
  --rebuild PKG    Force the rebuild of PKG (can be used several times)
  --offline        Do not update the sources, nor install pip packages
  --update         Update the tarball packages to their last version
                   (and their checksums), and build
  --check-updates  Report new versions of the downloaded packages, and exit
  --list           Show the packages, their versions and dependencies, and exit
  --pin PKG [REF]  Build the git package PKG from REF (a tag, branch or
                   commit; by default the last one that built), and exit
  --unpin PKG      Build PKG again from its default branch, and exit
  --restore [DATE] Restore the installation from the backup of DATE
                   (YYYYMMDD, by default the last one), and exit
  -j, --jobs N     Number of parallel make jobs (default: $(nproc))
  -h, --help       Show this help
EOF
}

# Kept to run the script again after --update
ORIG_ARGS=("$@")
OPT_CLEAN=
OPT_UPDATE=
OPT_LIST=
OPT_PIN=
OPT_PIN_REF=
OPT_UNPIN=
OPT_OFFLINE=
OPT_CHECK_UPDATES=
OPT_RESTORE=
OPT_REBUILD=()
JOBS="$(nproc)"
while [ $# -gt 0 ]; do
    case "$1" in
	--clean) OPT_CLEAN=1 ;;
	--offline) OPT_OFFLINE=1 ;;
	--check-updates) OPT_CHECK_UPDATES=1 ;;
	--update) OPT_UPDATE=1 ;;
	--list) OPT_LIST=1 ;;
	--pin)
	    [ $# -ge 2 ] || { usage; exit 1; }
	    OPT_PIN="$2"
	    shift
	    if [ $# -ge 2 ] && [[ "$2" != -* ]]; then
		OPT_PIN_REF="$2"
		shift
	    fi
	    ;;
	--unpin) [ $# -ge 2 ] || { usage; exit 1; }; OPT_UNPIN="$2"; shift ;;
	--restore)
	    OPT_RESTORE=last
	    if [[ "${2:-}" =~ ^[0-9]{8}$ ]]; then
		OPT_RESTORE="$2"
		shift
	    fi
	    ;;
	--rebuild) [ $# -ge 2 ] || { usage; exit 1; }; OPT_REBUILD+=("$2"); shift ;;
	-j|--jobs) [ $# -ge 2 ] || { usage; exit 1; }; JOBS="$2"; shift ;;
	-h|--help) usage; exit 0 ;;
	*) usage; exit 1 ;;
    esac
    shift
done
MAKE_JOBS=(-j "$JOBS" -l "$(nproc --ignore=1)")

# Configuration section
if [ -e "$HOME/.local/bin" ]; then
    PREFIX_ROOT="$HOME/.local/bin"
else
    PREFIX_ROOT="$HOME/bin"
fi
PREFIX="$PREFIX_ROOT/emacs-git"
SCRIPT="$DIR/$(basename "$0")"
LOG="$DIR/build.log"
BACKUP_DIR="$DIR/backup"
# Copy of the installation used to restore it if the build fails.  In
# the same file system than the prefix, so it can be moved quickly
ROLLBACK="$PREFIX_ROOT/.$(basename "$PREFIX").rollback"
# Records how each package was built, to detect what needs a rebuild
STAMPS="$PREFIX/.build-stamps"
CHECKSUMS="$DIR/SHA256SUMS"
EMACS_CONFIG="$HOME/.gnu-emacs"
EMACS_CONFIG_DIR="$HOME/.emacs.d"
PYTHON=$(readlink /usr/bin/python3)

# Set the environment variables
export PATH="$PATH":"$PREFIX/bin"
export PYTHONPATH="$PREFIX/lib/$PYTHON/site-packages:$PREFIX/lib64/$PYTHON/site-packages"

# Required for x11-macros
ACLOCAL_PATH=$(aclocal --print-ac-dir):"$PREFIX/share/aclocal"
export ACLOCAL_PATH

# Needed because giflib and libXpm
export CPPFLAGS="-I$PREFIX/include"
export CFLAGS="-O2 -pipe -march=native -mtune=native -fno-omit-frame-pointer -fno-plt -flto=auto"
export LDFLAGS="-L$PREFIX/lib64 -L$PREFIX/lib"
export LDFLAGS="$LDFLAGS -Wl,-O2 -Wl,-z,now -Wl,-z,relro -Wl,--sort-common -Wl,--as-needed -Wl,-z,pack-relative-relocs -flto=auto"
# The binaries find the libraries from the prefix without
# LD_LIBRARY_PATH.  It is not used even when compiling, as the system
# tools would load the libraries from the prefix (and tar, confined by
# AppArmor, fails to load libacl from $HOME)
export LDFLAGS="$LDFLAGS -Wl,-rpath,$PREFIX/lib64 -Wl,-rpath,$PREFIX/lib"
unset LD_LIBRARY_PATH
export PKG_CONFIG_PATH="$PREFIX/lib64/pkgconfig:$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"

# Disable keyring
export PYTHON_KEYRING_BACKEND=keyring.backends.null.Keyring

BLACK="\033[0;30m"
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
MAGENTA="\033[0;35m"
CYAN="\033[0;36m"
WHITE="\033[0;37m"
BRIGHT_BLACK="\033[1;30m"
BRIGHT_RED="\033[1;31m"
BRIGHT_GREEN="\033[1;32m"
BRIGHT_YELLOW="\033[0;33m"
BRIGHT_BLUE="\033[0;34m"
BRIGHT_MAGENTA="\033[0;35m"
BRIGHT_CYAN="\033[0;36m"
BRIGHT_WHITE="\033[0;37m"
RESET="\033[0m"

ASPELL_EN_VER="2026.02.25-0"
ASPELL_ES_VER="1.11-2"
NETTLE_VER="4.0"
GMP_VER="6.3.0"
LIBTASN1_VER="4.21.0"
GNUTLS_VER="3.8.13"
GIFLIB_VER="6.1.3"
TREE_SITTER_VER="0.26.11"
EMACS_VER="30.2"

# Packages list, in installation order.  The packages are taken from
# git when possible, so they are updated with each build (see --pin).
# If the package is from 'wget',
# the name will be deduced from the URL (GitHub archives named only
# with the version are stored as <name>-<version>).  If the package is
# a 'git', the name of the repo needs to be like the first field of the
# tuple.  An optional fourth field 'x11' marks the packages only used
# when Emacs is built for X11 (and not for Wayland).
# The files downloaded with 'wget' are verified with SHA256SUMS.
# Patches in patches/<name>/*.patch are applied before the compilation.
PACKAGES=(
    # Aspell
    "aspell","git","https://git.savannah.gnu.org/git/aspell.git"
    "aspell6-en","wget","https://ftp.gnu.org/gnu/aspell/dict/en/aspell6-en-$ASPELL_EN_VER.tar.bz2"
    "aspell6-es","wget","https://ftp.gnu.org/gnu/aspell/dict/es/aspell6-es-$ASPELL_ES_VER.tar.bz2"

    # GNUTLS.  From tarballs: gmp uses Mercurial, and building the git
    # versions of the rest requires the gnulib and autogen tooling
    "nettle","wget","https://ftp.gnu.org/gnu/nettle/nettle-$NETTLE_VER.tar.gz"
    "gmp","wget","https://gmplib.org/download/gmp/gmp-$GMP_VER.tar.xz"
    "libtasn1","wget","https://ftp.gnu.org/gnu/libtasn1/libtasn1-$LIBTASN1_VER.tar.gz"
    "gnutls","wget","https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-$GNUTLS_VER.tar.xz"

    # ACL and extended attributes
    "attr","git","https://git.savannah.gnu.org/git/attr.git"
    "acl","git","https://git.savannah.gnu.org/git/acl.git"

    # Giflib/Libungif.  From the tarball, that includes the
    # documentation (git would require xmlto)
    "giflib","wget","https://downloads.sourceforge.net/project/giflib/giflib-6.x/giflib-$GIFLIB_VER.tar.gz"

    # LibXpm (only used by X11, PGTK has its own XPM support)
    "macros","git","https://gitlab.freedesktop.org/xorg/util/macros.git","x11"
    "libxpm","git","https://gitlab.freedesktop.org/xorg/lib/libxpm.git","x11"

    # ImageMagick delegates: JPEG XL, HEIC, JPEG 2000 and RAW images
    "brotli","git","https://github.com/google/brotli.git"
    "highway","git","https://github.com/google/highway.git"
    "libjxl","git","https://github.com/libjxl/libjxl.git"
    "libde265","git","https://github.com/strukturag/libde265.git"
    "libheif","git","https://github.com/strukturag/libheif.git"
    "openjpeg","git","https://github.com/uclouvain/openjpeg.git"
    "LibRaw","git","https://github.com/LibRaw/LibRaw.git"

    # ImageMagick
    # "ImageMagick","wget","https://download.imagemagick.org/ImageMagick/download/ImageMagick.tar.gz"
    "ImageMagick","git","https://github.com/ImageMagick/ImageMagick.git"

    # tree-sitter
    # "tree-sitter","wget","https://github.com/tree-sitter/tree-sitter/archive/refs/tags/v$TREE_SITTER_VER.tar.gz"
    "tree-sitter","git","https://github.com/tree-sitter/tree-sitter.git"

    # Emacs
    # "emacs","wget","http://mirrors.kernel.org/gnu/emacs/emacs-$EMACS_VER.tar.xz"
    "emacs","git","https://git.savannah.gnu.org/git/emacs.git"
    "elpa","git","https://git.savannah.gnu.org/git/emacs/elpa.git"
    "nongnu","git","https://git.savannah.gnu.org/git/emacs/nongnu.git"
    "org-mode","git","https://git.savannah.gnu.org/git/emacs/org-mode.git"

    # Emacs (not in MELPA)
    "eglot-x","wget-raw","https://raw.githubusercontent.com/nemethf/eglot-x/master/eglot-x.el"

    # Python
    "wheel","pip","wheel"
    "python-lsp-server","pip","python-lsp-server[all]"
    "pylsp-mypy","pip","pylsp-mypy"
    "pyls-isort","pip","pyls-isort"
    "python-lsp-black","pip","python-lsp-black"
    # "pyls-memestra","pip","pyls-memestra"
    "pylsp-rope","pip","pylsp-rope"
    "python-lsp-ruff","pip","python-lsp-ruff"

    # Typst
    # Compile with
    #  gcc -fPIC -std=c99 -c parser.c
    #  gcc -fPIC -std=c99 -c scanner.c
    #  gcc -shared parser.o scanner.o  -o libtree-sitter-typst.so
    # "tree-sitter-typst","git","https://github.com/uben0/tree-sitter-typst.git"
    # "tinymist","git","https://github.com/Myriad-Dreamin/tinymist.git"
)

# The git packages are built from the default branch, unless they are
# pinned to a tag, branch or commit in the file `pins` (one "<package>
# <ref>" per line), for example when the last version does not build.
# Edit it with --pin and --unpin.  `--check-updates` shows the last tags
PINS_FILE="$DIR/pins"
declare -A PINS=()
if [ -f "$PINS_FILE" ]; then
    while read -r _name _ref _; do
	[[ -z "$_name" || "$_name" == \#* || -z "${_ref:-}" ]] && continue
	PINS["$_name"]="$_ref"
    done < "$PINS_FILE"
fi

# Drop the packages only used by X11 when building for Wayland
WAYLAND=
[ "${XDG_SESSION_TYPE:-}" = "wayland" ] && WAYLAND=1
declare -A ALL_NAMES=()
_packages=()
for package in "${PACKAGES[@]}"; do
    ALL_NAMES["${package%%,*}"]=1
    if [[ "$package" == *,x11 ]]; then
	[ -n "$WAYLAND" ] && continue
	package="${package%,x11}"
    fi
    _packages+=("$package")
done
PACKAGES=("${_packages[@]}")
unset _packages

# Extra parameters for packages.  Used for autotools, cmake and python
# packages.
declare -A COMPILE_OPTIONS=(
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
# Packages needed to build each package.  When a package is rebuilt,
# the packages that depend on it (directly or not) are rebuilt too
declare -A DEPENDS=(
    ["aspell6-en"]="aspell"
    ["aspell6-es"]="aspell"
    ["gnutls"]="nettle gmp libtasn1"
    ["acl"]="attr"
    ["libxpm"]="macros"
    ["libjxl"]="brotli highway"
    ["libheif"]="libde265"
    ["ImageMagick"]="libjxl libheif openjpeg LibRaw"
    ["emacs"]="gnutls gmp attr acl giflib libxpm ImageMagick tree-sitter"
)

# The dependencies must be installed before the packages that need
# them.  The ones not built (like libxpm for Wayland) are ignored
declare -A KNOWN=()
declare -A METHOD_OF=()
for package in "${PACKAGES[@]}"; do
    IFS=',' read -r name method url <<< "${package}"
    for dep in ${DEPENDS[$name]:-}; do
	if [[ ! -v ALL_NAMES[$dep] ]]; then
	    echo -e "${RED}ERROR${RESET} unknown package $dep in DEPENDS of $name"
	    exit 1
	elif [[ -v ALL_NAMES[$dep] && ! -v KNOWN[$dep] ]] && printf '%s\n' "${PACKAGES[@]}" | grep -q "^$dep,"; then
	    echo -e "${RED}ERROR${RESET} $dep needs to be before $name in PACKAGES"
	    exit 1
	fi
    done
    KNOWN["$name"]=1
    METHOD_OF["$name"]="$method"
done

# Everything that is not Wayland (like a build from a TTY or SSH) is
# built for X11, that requires libXpm
if [ -n "$WAYLAND" ]; then
    COMPILE_OPTIONS["emacs"]+=" --without-x --with-pgtk --with-toolkit-scroll-bars"
else
    COMPILE_OPTIONS["emacs"]+=" --with-x --with-x-toolkit=gtk3 --with-xpm"
fi
[ -f /usr/include/libgccjit.h ] && COMPILE_OPTIONS["emacs"]+=" --with-native-compilation"

# Used to return values from `git_clone_or_update`,
# `wget_get_or_update`, `pip_get_or_update` and `untar`, as those
# functions generate data to stdout
LOCATION=

# Package being processed, and if the build finished, used to report
# errors and restore the installation
CURRENT=
SUCCESS=
WARNINGS=()

# Report a problem that does not stop the build, and repeat it at the
# end
function warning {
    echo -e "${YELLOW}WARNING${RESET} $1"
    WARNINGS+=("$1")
}

function error_report  {
    # Report only once, and not from the subshells
    if [ "$BASH_SUBSHELL" -eq 0 ]; then
	echo -e "${RED}ERROR${RESET} on line $1${CURRENT:+ ($CURRENT)}"
    fi
}

function on_exit {
    local exit_code=$?
    [ -n "$SUCCESS" ] && return
    trap - ERR

    if [ -s "$LOG" ]; then
	echo -e "${RED}FAILED${RESET}${CURRENT:+ processing $CURRENT}, last lines of $LOG:"
	tail -n 30 "$LOG"
    fi
    if [ -n "$CURRENT" ] && [[ -v KNOWN[$CURRENT] ]]; then
	failure_hint "$CURRENT"
    fi

    if [ -d "$ROLLBACK" ]; then
	echo -e "${YELLOW}RESTORING${RESET} previous installation"
	rm -fr "$PREFIX"
	mv "$ROLLBACK" "$PREFIX"
    fi
    exit "$exit_code"
}

function normalize {
    local name=$1
    echo "$name" | tr '-' '_'
}

# Identify how a package is built: the source version, the options,
# the patches and the compilation functions.  A change in any of them
# requires a rebuild
function package_stamp {
    local name="$1"
    local method="$2"
    local location="$3"

    local source
    case "$method" in
	"git")
	    source=$(git -C "$location" rev-parse HEAD)
	    ;;
	*)
	    source=$(sha256sum "$location" | cut -d' ' -f1)
	    ;;
    esac

    {
	echo "$source"
	echo "${COMPILE_OPTIONS[$name]:-}"
	echo "$PREFIX $CPPFLAGS $CFLAGS $LDFLAGS"
	cat "$DIR/patches/$name"/*.patch 2>/dev/null || true
	declare -f "compile_$(normalize "$name")" compile_autotools compile_cmake compile_make compile_python compile_rust || true
	# A change in a dependency also requires a rebuild
	local dep
	for dep in ${DEPENDS[$name]:-}; do
	    echo "$dep ${STAMP_OF[$dep]:-}"
	done
    } | sha256sum | cut -d' ' -f1
}

# The version of the source: the commit for git, the file otherwise
function package_source {
    local method="$1"
    local location="$2"

    if [ "$method" = "git" ]; then
	git -C "$location" rev-parse HEAD
    else
	basename "$location"
    fi
}

# Packages that depend on a package, directly or not, in installation
# order
function dependents {
    local name="$1"
    local package other dep
    local -A affected=(["$name"]=1)
    local result=()

    for package in "${PACKAGES[@]}"; do
	other="${package%%,*}"
	for dep in ${DEPENDS[$other]:-}; do
	    if [[ -v affected[$dep] ]]; then
		affected["$other"]=1
		result+=("$other")
		break
	    fi
	done
    done
    echo "${result[*]}"
}

# The last version of a package that was built successfully.  With
# --clean the stamps are in the copy of the previous installation
function last_good {
    local name="$1"
    local file
    for file in "$STAMPS/$name.source" "$ROLLBACK/$(basename "$STAMPS")/$name.source"; do
	if [ -f "$file" ]; then
	    cat "$file"
	    return
	fi
    done
}

# Explain how to go back to the version of a package that worked
function failure_hint {
    local name="$1"
    local good affected

    good=$(last_good "$name")
    if [ -z "$good" ]; then
	echo "There is no previous successful build of $name"
    elif [ "${METHOD_OF[$name]:-}" = "git" ]; then
	echo "The last version of $name that built is $good"
	echo "To build it again: ./$(basename "$0") --pin $name   (and --unpin $name later)"
    else
	echo "The last version of $name that built is $good: set its version back in $(basename "$0")"
    fi
    affected=$(dependents "$name")
    if [ -n "$affected" ]; then
	echo "Packages that depend on $name (rebuilt with it): $affected"
    fi
}

# Keep a copy of the current installation, to restore it if the build
# fails.  With --clean the installation is moved, so the packages are
# installed into an empty prefix
function snapshot_prefix {
    rm -fr "$ROLLBACK"
    [ -d "$PREFIX" ] || return 0

    if [ -n "$OPT_CLEAN" ]; then
	mv "$PREFIX" "$ROLLBACK"
    else
	echo -e "${GREEN}SNAPSHOT${RESET} current installation"
	cp -a "$PREFIX" "$ROLLBACK"
    fi
}

# After a successful build, keep the previous installation as the
# backup of the day
function release_snapshot {
    local backup
    backup="$BACKUP_DIR/emacs-git_$(date +"%Y%m%d")"
    [ -d "$ROLLBACK" ] || return 0

    if [ ! -d "$backup" ]; then
	echo -e "${GREEN}BACKUP${RESET} previous installation to $backup"
	mkdir -p "$BACKUP_DIR"
	mv "$ROLLBACK" "$backup"
    else
	rm -fr "$ROLLBACK"
    fi
}

function create_backup {
    mkdir -p "$BACKUP_DIR"

    local backup
    backup="$BACKUP_DIR/$(basename "$EMACS_CONFIG")_$(date +"%Y%m%d")"
    if [ -f "$EMACS_CONFIG" ]; then
	if [ ! -f "$backup" ]; then
	    echo -e "${GREEN}BACKUP${RESET} current configuration to $backup"
	    mv "$EMACS_CONFIG" "$backup"
	fi
    fi

    backup="$BACKUP_DIR/$(basename "$EMACS_CONFIG_DIR")_$(date +"%Y%m%d")"
    if [ -d "$EMACS_CONFIG_DIR" ]; then
	if [ ! -d "$backup" ]; then
	    echo -e "${GREEN}BACKUP${RESET} current .emacs.d to $backup"
	    mv "$EMACS_CONFIG_DIR" "$backup"
	    # Recover some files from the last backup
	    mkdir -p "$EMACS_CONFIG_DIR"
	    cp -a "$backup/ido.last" "$EMACS_CONFIG_DIR" >>"$LOG" 2>&1 || true
	    cp -a "$backup/network-security.data" "$EMACS_CONFIG_DIR" >>"$LOG" 2>&1 || true
	fi
    fi
    mkdir -p "$EMACS_CONFIG_DIR/lisp"

    backup="$BACKUP_DIR/emacs_shim_$(date +"%Y%m%d")"
    if [ -f "$PREFIX_ROOT/emacs" ]; then
	if [ ! -f "$backup" ]; then
	    echo -e "${GREEN}BACKUP${RESET} current emacs shim to $backup"
	    mv "$PREFIX_ROOT/emacs" "$backup"
	fi
    fi
}

function git_clone_or_update {
    local name="$1"
    local url="$2"

    # Run the automatic gc / maintenance in the foreground, so it does
    # not modify .git/objects while the repository is copied later
    local git_opts=(-c gc.autoDetach=false -c maintenance.autoDetach=false)

    local pin="${PINS[$name]:-}"
    local fetched=

    if [ -n "$OPT_OFFLINE" ]; then
	if [ ! -d "$name" ]; then
	    echo -e "${RED}ERROR${RESET} $name repository not found (offline)"
	    exit 1
	fi
    elif [ -d "$name" ]; then
	echo -e "${GREEN}UPDATING${RESET} $name repository"
	# If the server is not available, build the local copy.  The
	# tags are forced, as some projects move them (like nightly)
	if git "${git_opts[@]}" -C "$name" fetch --all --tags -p --force >>"$LOG" 2>&1; then
	    fetched=1
	else
	    warning "fetching $name repository failed, using the local copy (check $LOG)"
	fi
    else
	echo -e "${YELLOW}CLONING${RESET} $name repository"
	git clone "$url" >>"$LOG" 2>&1
    fi

    if [ -n "$pin" ]; then
	echo -e "${BLUE}PINNED${RESET} $name to $pin"
	if ! git -C "$name" checkout -q --detach "$pin" >>"$LOG" 2>&1; then
	    echo -e "${RED}ERROR${RESET} $name has no $pin, check PINS"
	    exit 1
	fi
    else
	# Return to the default branch if the package was pinned
	if ! git -C "$name" symbolic-ref -q HEAD >/dev/null; then
	    local branch
	    branch=$(git -C "$name" symbolic-ref -q --short refs/remotes/origin/HEAD || true)
	    if [ -z "$branch" ]; then
		git -C "$name" remote set-head origin --auto >>"$LOG" 2>&1
		branch=$(git -C "$name" symbolic-ref --short refs/remotes/origin/HEAD)
	    fi
	    git -C "$name" checkout -q "${branch#origin/}" >>"$LOG" 2>&1
	fi
	if [ -n "$fetched" ] && ! git "${git_opts[@]}" -C "$name" pull --rebase >>"$LOG" 2>&1; then
	    echo -e "${RED}ERROR${RESET} updating $name repository, check $LOG"
	    exit 1
	fi
    fi

    LOCATION="$name"
}

function wget_get_or_update {
    local name="$1"
    local url="$2"

    # Recover the name of the file.  The GitHub archives are named
    # only with the version (v1.2.0.tar.gz)
    local file_name
    file_name=$(basename "$url")
    if [[ "$file_name" =~ ^v?[0-9] ]]; then
	file_name="$name-${file_name#v}"
    fi

    if [ -f "$file_name" ]; then
	echo -e "${GREEN}UPDATED${RESET} file $name"
    elif [ -n "$OPT_OFFLINE" ]; then
	echo -e "${RED}ERROR${RESET} file $file_name not found (offline)"
	exit 1
    else
	echo -e "${YELLOW}DOWNLOADING${RESET} file $name"
	# Download into a temporary file, so an interrupted download
	# is not taken as a complete one in the next run
	wget -O "$file_name.part" "$url" >>"$LOG" 2>&1
	mv "$file_name.part" "$file_name"
    fi
    verify_checksum "$file_name"

    LOCATION="$file_name"
}

function verify_checksum {
    local file_name="$1"
    local expected actual

    expected=$(awk -v f="$file_name" '$2 == f { print $1 }' "$CHECKSUMS")
    actual=$(sha256sum "$file_name" | cut -d' ' -f1)
    if [ -z "$expected" ]; then
	echo -e "${RED}ERROR${RESET} no checksum for $file_name in $CHECKSUMS"
	echo "If the file is legit, add this line to $CHECKSUMS:"
	echo "$actual  $file_name"
	exit 1
    fi
    if [ "$expected" != "$actual" ]; then
	echo -e "${RED}ERROR${RESET} checksum mismatch for $file_name, removing it"
	rm -f "$file_name"
	exit 1
    fi
}

function pip_get_or_update {
    local name="$1"
    local url="$2"

    echo -e "${YELLOW}DOWNLOADING${RESET} pip $name"

    LOCATION="$url"
}

function untar {
    local name="$1"
    local loc

    # The directory is the top level entry of the archive, that can
    # be different from the file name (maybe with a version attached,
    # or a github tag)
    case "$name" in
	*.tar.gz|*.tgz|*.tar.bz2|*.tbz|*.tar.xz|*.txz)
	    # sed reads the full list: `head` would kill tar with SIGPIPE,
	    # failing the pipeline
	    loc=$(tar -tf "$name" | sed -n '1p')
	    tar -xvf "$name" >>"$LOG" 2>&1
	    ;;
	*.zip)
	    loc=$(unzip -Z1 "$name" | sed -n '1p')
	    unzip "$name" >>"$LOG" 2>&1
	    ;;
	*)
	    echo -e "${RED}ERROR${RESET} file format not recognized $name"
	    exit 1
	    ;;
    esac

    loc="${loc#./}"
    loc="${loc%%/*}"
    if [ -z "$loc" ] || [ ! -d "$loc" ]; then
	    echo -e "${RED}ERROR${RESET} directory not found for $name"
	    exit 1
    fi
    LOCATION="$loc"
}

function compile_autotools {
    local prefix="$1"
    local options="$2"

    if [ ! -f configure ] && [ -f autogen.sh ]; then
	./autogen.sh $options --prefix "$prefix" >>"$LOG" 2>&1
    elif [ ! -f configure ] && [ ! -f autogen.sh ]; then
	autoreconf -i >>"$LOG" 2>&1
    fi

    ./configure $options --prefix "$prefix" >>"$LOG" 2>&1
    make "${MAKE_JOBS[@]}" >>"$LOG" 2>&1

    local exit_code=0
    make -q install-strip &>/dev/null || exit_code="$?"
    if [ "$exit_code" -lt 2 ]; then
	make install-strip >>"$LOG" 2>&1
    else
	make install >>"$LOG" 2>&1
    fi
}

function compile_cmake {
    local prefix="$1"
    local options="$2"

    # gcc-ar and gcc-ranlib can handle the LTO objects
    cmake -S . -B _build -G Ninja -DCMAKE_BUILD_TYPE=Release \
	  -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_PREFIX_PATH="$prefix" \
	  -DCMAKE_INSTALL_RPATH="$prefix/lib64;$prefix/lib" \
	  -DCMAKE_AR="$(command -v gcc-ar)" -DCMAKE_RANLIB="$(command -v gcc-ranlib)" \
	  -DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF $options >>"$LOG" 2>&1
    cmake --build _build -j "$JOBS" >>"$LOG" 2>&1
    cmake --install _build --strip >>"$LOG" 2>&1
}

function compile_make {
    local prefix="$1"
    local options="$2"

    make "${MAKE_JOBS[@]}" >>"$LOG" 2>&1
    PREFIX="$1" make install >>"$LOG" 2>&1
}

function compile_python {
    local prefix="$1"
    local options="$2"

    $PYTHON setup.py install --prefix="$prefix" $options >>"$LOG" 2>&1
}

function compile_pip {
    local prefix="$1"
    local package="$2"
    local options="$3"

    pip install -I --prefix="$prefix" "$package" >>"$LOG" 2>&1
}

function compile_rust {
    local prefix="$1"
    local package="$2"

    cargo build --release >>"$LOG" 2>&1
    mkdir -p "$prefix/bin"
    mv target/release/"$package" "$prefix/bin/$package" >>"$LOG" 2>&1
}

function _compile_aspell_dict {
    { ./configure; make "${MAKE_JOBS[@]}"; make install; } >>"$LOG" 2>&1
}

function compile_aspell6_en {
    _compile_aspell_dict
}

function compile_aspell6_es {
    _compile_aspell_dict
}

function compile_giflib {
    local prefix="$1"
    local options="$2"

    make "${MAKE_JOBS[@]}" >>"$LOG" 2>&1
    make PREFIX="$prefix" LIBDIR="$prefix/lib64" install >>"$LOG" 2>&1
}

function compile_emacs {
    local prefix="$1"
    local options="$2"

    [ -e .git ] && ./autogen.sh git >>"$LOG" 2>&1
    [ -e .git ] && ./autogen.sh autoconf >>"$LOG" 2>&1
    ./configure $options --prefix "$prefix" >>"$LOG" 2>&1
    make "${MAKE_JOBS[@]}" >>"$LOG" 2>&1

    # Remove the previous version, so no old file (like the Lisp
    # files removed upstream) is left in the prefix.  Done after the
    # compilation, so the installed Emacs can be used meanwhile
    rm -fr "$prefix"/share/emacs "$prefix"/lib/emacs "$prefix"/lib64/emacs "$prefix"/libexec/emacs "$prefix"/bin/emacs-[0-9]*
    make install-strip >>"$LOG" 2>&1
}

function write_early_init {
    # Check https://www.jamescherti.com/compiling-emacs/
    if [ -f /usr/include/libgccjit.h ]; then
	cat >"$EMACS_CONFIG_DIR/early-init.el" <<'EOF'
;;; ...  -*- lexical-binding: t -*-

;; Display the architecture using:
;;   gcc -march=native -Q --help=target | grep march
;;
;; The above command asks the compiler to resolve native for your current CPU
;; and display the resulting target. For example, if the output shows
;; -march=skylake, you know that skylake is the identifier you should pass to
;; -mtune and -march.
(setq my-cpu-architecture "skylake")

;; `native-comp-compiler-options' specifies flags passed directly to the C
;; compiler (for example, GCC) when compiling the Lisp-to-C output
;; produced by the native compilation process. These flags affect code
;; generation, optimization, and debugging information.
(setq native-comp-compiler-options `(;; The most meaningful optimizations:
                                     "-O2"
                                     ,(format "-mtune=%s" my-cpu-architecture)
                                     ,(format "-march=%s" my-cpu-architecture)
                                     ;; Reduce .eln size and compilation
                                     ;; overhead.
                                     "-g0"
                                     ;; Good defensive choice for Emacs
                                     ;; stability.
                                     "-fno-omit-frame-pointer"
                                     "-fno-finite-math-only"))

(setq native-comp-driver-options '(;; -Wl,-z,pack-relative-relocs compresses
                                   ;; relocation tables to reduce file size and
                                   ;; slightly improve load times.
                                   "-Wl,-z,pack-relative-relocs"
                                   ;; -Wl,-O2 applies standard linker-level
                                   ;; optimizations (like string merging) to the
                                   ;; generated shared object.
                                   "-Wl,-O2"
                                   ;; -Wl,--as-needed prevents the linker from
                                   ;; recording dependencies on libraries that
                                   ;; are not actually used by the code.
                                   "-Wl,--as-needed"))
EOF
    fi
}

function compile_elpa {
    :
}

function compile_nongnu {
    :
}

function compile_org_mode {
    :
}

# Installed into $EMACS_CONFIG_DIR by `install_config`
function compile_eglot_x {
    :
}

function compile_and_install {
    local location="$1"
    local name="$2"
    local method="$3"

    if [ -d build ]; then
	rm -fr build
    fi

    case "$method" in
	"git")
	    # Share the objects with the repository: only the working
	    # tree is copied
	    git clone --shared "$location" build >>"$LOG" 2>&1
	    git -C build checkout -q --detach "$(git -C "$location" rev-parse HEAD)" >>"$LOG" 2>&1
	    ;;
	"wget")
	    untar "$location"
	    if [ ! -d "$LOCATION" ]; then
		echo -e "${RED}ERROR${RESET} directory $LOCATION not found"
		exit 1
	    fi
	    mv "$LOCATION" build
	    ;;
	"wget-raw")
	    mkdir build
	    cp -a "$location" build
	    ;;
	"pip")
	    mkdir build
	    ;;
	*)
	    echo -e "${RED}ERROR${RESET} method $method not found"
	    exit 1
	    ;;
    esac

    local extra=
    if [[ -v COMPILE_OPTIONS[$name] ]]; then
	extra="${COMPILE_OPTIONS[$name]}"
    fi

    local patch_file
    for patch_file in "$DIR/patches/$name"/*.patch; do
	[ -f "$patch_file" ] || continue
	echo -e "${BLUE}PATCHING${RESET} $name with $(basename "$patch_file")"
	patch -d build -p1 < "$patch_file" >>"$LOG" 2>&1
    done

    local normalized_name
    normalized_name="$(normalize "$name")"

    pushd build >>"$LOG" 2>&1
    # Check if there is a specific compilation function
    if [ "$(type -t "compile_${normalized_name}")" = "function" ]; then
	echo -e "${GREEN}COMPILING${RESET} $name with special function"
	compile_"${normalized_name}" "$PREFIX" "$extra"
    elif [ -f configure.sh ] || [ -f configure.ac ] || [ -f autogen.sh ]; then
	echo -e "${GREEN}COMPILING${RESET} $name with general autotools function"
	compile_autotools "$PREFIX" "$extra"
    elif [ -f Makefile ]; then
	echo -e "${GREEN}COMPILING${RESET} $name with general make function"
	compile_make "$PREFIX" "$extra"
    elif [ -f CMakeLists.txt ]; then
	echo -e "${GREEN}COMPILING${RESET} $name with general cmake function"
	compile_cmake "$PREFIX" "$extra"
    elif [ -f setup.py ]; then
	echo -e "${GREEN}COMPILING${RESET} $name with general Python function"
	compile_python "$PREFIX" "$extra"
    elif [ "$method" = "pip" ]; then
	echo -e "${GREEN}COMPILING${RESET} $name with general pip function"
	compile_pip "$PREFIX" "$location" "$extra"
    elif [ -f Cargo.toml ]; then
	echo -e "${GREEN}COMPILING${RESET} $name with general Rust function"
	compile_rust "$PREFIX" "$name"
    else
	echo -e "${RED}ERROR${RESET} compilation method for $name not found"
	exit 1
    fi
    popd >>"$LOG" 2>&1

    rm -fr build
}

function configure {
    cat >"$EMACS_CONFIG" <<'EOF'
;;; ...  -*- lexical-binding: t -*-

(custom-set-variables
 ;; custom-set-variables was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 '(cua-mode t nil (cua-base))
 '(package-selected-packages nil)
 '(tool-bar-mode nil nil (tool-bar)))
(custom-set-faces
 ;; custom-set-faces was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 '(default ((t (:family "Source Code Pro" :foundry "ADBO" :slant normal :weight regular :height 98 :width normal)))))

;; Tramp uses the default remote path
(require 'tramp)
(add-to-list 'tramp-remote-path 'tramp-own-remote-path)

;; Enable ido-mode
(require 'ido)
(ido-mode t)

;; Enable EasyPG as an interface to gnupg.
(require 'epa-file)
(epa-file-enable)

;; Add MELPA to the Emacs package manager
(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
;; Comment/uncomment this line to enable MELPA Stable if desired.  See `package-archive-priorities`
;; and `package-pinned-packages`. Most users will not need or want to do this.
;;(add-to-list 'package-archives '("melpa-stable" . "https://stable.melpa.org/packages/") t)
(unless package--initialized
  (package-initialize))
(unless package-archive-contents
  (package-refresh-contents))

;; Replace "rust-mode" with "rustic"
(setq package-list '(use-package yaml-mode dockerfile-mode rust-mode web-mode markdown-mode company))

(dolist (package package-list)
  (unless (package-installed-p package)
    (package-install package)))

(setq load-path (cons "~/.emacs.d/lisp" load-path))

;; use-package
(require 'use-package)

;; SLIME
;; (setq inferior-lisp-program "~/bin/sbcl") ; your Lisp system
;; (add-to-list 'load-path "~/bin/emacs-cvs/slime/")  ; your SLIME directory
;; (require 'slime)
;; (slime-setup)

;; YAML mode
(require 'yaml-mode)
(add-to-list 'auto-mode-alist '("\\.yml\\'" . yaml-mode))
(add-to-list 'auto-mode-alist '("\\.yaml\\'" . yaml-mode))

;; Dockerfile mode
(require 'dockerfile-mode)
(setq dockerfile-mode-command "podman")

;; Rust mode
(require 'rust-mode)

;; Web mode
(require 'web-mode)
(add-to-list 'auto-mode-alist '("\\.phtml\\'" . web-mode))
(add-to-list 'auto-mode-alist '("\\.tpl\\.php\\'" . web-mode))
(add-to-list 'auto-mode-alist '("\\.[agj]sp\\'" . web-mode))
(add-to-list 'auto-mode-alist '("\\.as[cp]x\\'" . web-mode))
(add-to-list 'auto-mode-alist '("\\.erb\\'" . web-mode))
(add-to-list 'auto-mode-alist '("\\.mustache\\'" . web-mode))
(add-to-list 'auto-mode-alist '("\\.djhtml\\'" . web-mode))

;; Company mode
(add-hook 'after-init-hook 'global-company-mode)

;; Automatic eglot for certain modes
(add-hook 'rust-mode-hook 'eglot-ensure)
(add-hook 'python-mode-hook 'eglot-ensure)

;; Configure eglot for Python to use flake8
(setq-default eglot-workspace-configuration
              '((:pylsp
		 . (:configurationSources ["flake8"] :plugins (:pycodestyle (:enabled nil) :mccabe (:enabled nil) :pyflakes (:enable nil) :flake8 (:enabled t))))))

;; Enable eglot-x
(with-eval-after-load 'eglot
  (require 'eglot-x)
  (eglot-x-setup))

;; SSL connection for IRC (M-x erc-suse)
(defun erc-suse ()
  (interactive)
  (erc-tls :server "irc.suse.de" :port 6697
	   :nick "aplanas" :full-name "Alberto Planas"))
EOF
}

function create_links {
    ln -srf "$PREFIX"/bin/* "$PREFIX_ROOT"
}

function create_shim {
    local from=$1
    local to=$2

    rm "${to}" >>"$LOG" 2>&1 || true
    cat > "${to}" <<EOF
#! /bin/sh

if [ -z \$PYTHONPATH ]; then
    export PYTHONPATH=$PREFIX/lib64/$PYTHON/site-packages:$PREFIX/lib/$PYTHON/site-packages
else
    export PYTHONPATH=\$PYTHONPATH:$PREFIX/lib64/$PYTHON/site-packages:$PREFIX/lib/$PYTHON/site-packages
fi

export PATH=$PREFIX/bin:\$PATH

${from} "\$@"
EOF
    chmod a+x "${to}"
}

function create_ld_shim {
    local from=$1
    local to=$2

    rm "${to}" >>"$LOG" 2>&1 || true
    cat > "${to}" <<EOF
#! /bin/sh

LD_LIBRARY_PATH= ${from} "\$@"
EOF
    chmod a+x "${to}"
}

# Warn about binaries that do not find their libraries without
# LD_LIBRARY_PATH
function check_libraries {
    local file missing
    while IFS= read -r -d '' file; do
	cmp -s -n 4 "$file" <(printf '\177ELF') || continue
	missing=$(env -u LD_LIBRARY_PATH ldd "$file" 2>/dev/null | grep 'not found' || true)
	if [ -n "$missing" ]; then
	    echo -e "${YELLOW}WARNING${RESET} missing libraries for $file:"
	    echo "$missing"
	fi
    done < <(find "$PREFIX"/bin "$PREFIX"/lib "$PREFIX"/lib64 "$PREFIX"/libexec -type f \( -perm -u+x -o -name '*.so*' \) -print0 2>/dev/null)
}

function remove_dangling_links {
    find "$PREFIX_ROOT" -maxdepth 1 -xtype l -lname "$(basename "$PREFIX")/*" -delete
}

# Print the content of the directory listing of an URL.  The
# downloads from SourceForge are listed in a different place
function list_url {
    local url="$1"
    if [[ "$url" =~ ^https?://downloads\.sourceforge\.net/project/([^/]+)/?(.*)$ ]]; then
	url="https://sourceforge.net/projects/${BASH_REMATCH[1]}/files/${BASH_REMATCH[2]}"
    fi
    wget -q -O- "${url%/}/" || true
}

# Print the newest version of a file named `<base>-<version>.<ext>`
# in the listing of an URL
function newest_version {
    local url="$1"
    local base="$2"
    local re_base="${base//./\\.}"
    list_url "$url" \
	| grep -oE "${re_base}-[0-9][0-9.-]*[0-9]\.(tar\.(gz|bz2|xz)|tgz|tbz|txz|zip)" \
	| sed -E "s/^${re_base}-//; s/\.(tar\.(gz|bz2|xz)|tgz|tbz|txz|zip)\$//" \
	| sort -uV | tail -n 1 || true
}

function report_version {
    local name="$1"
    local version="$2"
    local newest="$3"
    local location="$4"

    if [ -z "$newest" ]; then
	echo -e "${YELLOW}UNKNOWN${RESET} $name: no versions found in $location"
    elif [ "$newest" != "$version" ] && [ "$(printf '%s\n' "$version" "$newest" | sort -V | tail -n 1)" = "$newest" ]; then
	echo -e "${BLUE}NEW VERSION${RESET} $name: $version -> $newest"
    else
	echo -e "${GREEN}UP TO DATE${RESET} $name: $version"
    fi
}

# Find the version of a tarball package and the newest one in the same
# location (TV_VERSION, TV_NEWEST and TV_LOCATION).  Fails if the
# version is not in the file name
function tarball_versions {
    local url="$1"
    local file dir base
    TV_VERSION=
    TV_NEWEST=
    TV_LOCATION=

    # The tags of GitHub projects are the versions
    if [[ "$url" =~ ^https://github\.com/([^/]+/[^/]+)/(releases/download|archive/refs/tags)/v?([0-9][0-9.]*[0-9]) ]]; then
	TV_VERSION="${BASH_REMATCH[3]}"
	TV_LOCATION="https://github.com/${BASH_REMATCH[1]}"
	TV_NEWEST=$(git ls-remote --tags --refs "$TV_LOCATION" 2>/dev/null \
			| sed -E 's#.*refs/tags/v?##' | grep -E '^[0-9]+(\.[0-9]+)+$' | sort -V | tail -n 1 || true)
	return 0
    fi

    file=$(basename "$url")
    dir=$(dirname "$url")
    # The version starts in the first component that begins with a
    # digit, and can contain dashes (like 2026.02.25-0)
    if [[ ! "$file" =~ ^([^-]+(-[A-Za-z][^-]*)*)-([0-9][0-9A-Za-z.-]*)\.(tar\.(gz|bz2|xz)|tgz|tbz|txz|zip)$ ]]; then
	return 1
    fi
    base="${BASH_REMATCH[1]}"
    TV_VERSION="${BASH_REMATCH[3]}"
    TV_LOCATION="$dir"
    TV_NEWEST=$(newest_version "$dir" "$base")
}

function is_newer {
    local version="$1"
    local newest="$2"
    [ -n "$newest" ] && [ "$newest" != "$version" ] \
	&& [ "$(printf '%s\n' "$version" "$newest" | sort -V | tail -n 1)" = "$newest" ]
}

# Update the version variables of the tarball packages, and their
# checksums, to the last version in the same series
function update_versions {
    local package name method url line var new_url file old_file
    mkdir -p "$DIR/artifacts"

    for package in "${PACKAGES[@]}"; do
	IFS=',' read -r name method url <<< "${package}"
	[ "$method" = "wget" ] || continue
	line=$(grep -E "^[[:space:]]*\"$name\",\"wget\"," "$SCRIPT" || true)
	var=$(grep -oE '\$[A-Z0-9_]+' <<< "$line" | sed -n '1s/^\$//p')
	if [ -z "$var" ] || ! tarball_versions "$url"; then
	    echo -e "${YELLOW}SKIPPING${RESET} $name: no version found"
	    continue
	fi
	if ! is_newer "$TV_VERSION" "$TV_NEWEST"; then
	    echo -e "${GREEN}UP TO DATE${RESET} $name: $TV_VERSION"
	    continue
	fi

	echo -e "${BLUE}UPDATING${RESET} $name: $TV_VERSION -> $TV_NEWEST"
	new_url="${url//$TV_VERSION/$TV_NEWEST}"
	file=$(basename "$new_url")
	if [[ "$file" =~ ^v?[0-9] ]]; then
	    file="$name-${file#v}"
	fi
	if ! wget -q -O "$DIR/artifacts/$file.part" "$new_url"; then
	    rm -f "$DIR/artifacts/$file.part"
	    warning "download of $new_url failed, $name not updated"
	    continue
	fi
	mv "$DIR/artifacts/$file.part" "$DIR/artifacts/$file"
	# Trust the new file, downloaded with HTTPS, and forget the old one
	old_file=$(basename "$url")
	if [[ "$old_file" =~ ^v?[0-9] ]]; then
	    old_file="$name-${old_file#v}"
	fi
	awk -v old="$old_file" -v new="$file" '$2 != old && $2 != new' "$CHECKSUMS" > "$CHECKSUMS.new"
	echo "$(sha256sum "$DIR/artifacts/$file" | cut -d' ' -f1)  $file" >> "$CHECKSUMS.new"
	mv "$CHECKSUMS.new" "$CHECKSUMS"
	sed -i "s/^$var=\"$TV_VERSION\"/$var=\"$TV_NEWEST\"/" "$SCRIPT"
    done
}

function list_packages {
    local package name method url version pinned built
    for package in "${PACKAGES[@]}"; do
	IFS=',' read -r name method url <<< "${package}"
	pinned=
	case "$method" in
	    "git")
		version=$(git -C "$DIR/artifacts/$name" describe --tags --always 2>/dev/null || echo "not cloned")
		[[ -v PINS[$name] ]] && pinned=" (pinned to ${PINS[$name]})"
		;;
	    "pip")
		version="$url (last version)"
		;;
	    *)
		version=$(basename "$url")
		;;
	esac
	built=$(last_good "$name")
	[ "$method" = "git" ] && [ -n "$built" ] && built=$(git -C "$DIR/artifacts/$name" describe --tags --always "$built" 2>/dev/null || echo "$built")
	echo -e "${GREEN}$name${RESET} [$method] $version$pinned"
	[ -n "$built" ] && echo "    last built: $built"
	[ -n "${DEPENDS[$name]:-}" ] && echo "    depends on: ${DEPENDS[$name]}"
	[ -n "$(dependents "$name")" ] && echo "    needed by:  $(dependents "$name")"
    done
}

# Pin or unpin a git package in the pins file
function set_pin {
    local name="$1"
    local ref="$2"

    if [ "${METHOD_OF[$name]:-}" != "git" ]; then
	echo -e "${RED}ERROR${RESET} $name is not a git package"
	exit 1
    fi
    [ -f "$PINS_FILE" ] || printf '# <package> <tag, branch or commit>\n' > "$PINS_FILE"
    awk -v n="$name" '$1 != n' "$PINS_FILE" > "$PINS_FILE.new"
    if [ -n "$ref" ]; then
	echo "$name $ref" >> "$PINS_FILE.new"
	echo -e "${BLUE}PINNED${RESET} $name to $ref, it will be used in the next build"
    else
	echo -e "${BLUE}UNPINNED${RESET} $name, the next build will use its default branch"
    fi
    mv "$PINS_FILE.new" "$PINS_FILE"
}

function check_updates {
    local package name method url file dir series base version newest
    local re_series parent newest_series

    for package in "${PACKAGES[@]}"; do
	IFS=',' read -r name method url <<< "${package}"
	if [ "$method" = "git" ] && [[ -v PINS[$name] ]]; then
	    newest=$(git ls-remote --tags --refs "$url" 2>/dev/null \
			 | sed -E 's#.*refs/tags/v?##' | grep -E '^[0-9]+(\.[0-9]+)+$' | sort -V | tail -n 1 || true)
	    echo -e "${YELLOW}PINNED${RESET} $name: ${PINS[$name]} (last tag: ${newest:-unknown})"
	    continue
	fi
	[ "$method" = "wget" ] || continue

	if ! tarball_versions "$url"; then
	    echo -e "${YELLOW}UNKNOWN${RESET} $name: cannot find the version in $(basename "$url")"
	    continue
	fi
	report_version "$name" "$TV_VERSION" "$TV_NEWEST" "$TV_LOCATION"
	[[ "$TV_LOCATION" == https://github.com/* ]] && continue

	file=$(basename "$url")
	dir=$(dirname "$url")
	base="${file%%-"$TV_VERSION"*}"

	# Some projects use a directory per series (like v3.8 or
	# giflib-6.x), look for a newer one in the parent directory
	series=$(basename "$dir")
	if [[ "$series" =~ [0-9] ]]; then
	    re_series=$(sed -E 's/\./\\./g; s/[0-9]+/[0-9]+/g' <<< "$series")
	    parent=$(dirname "$dir")
	    newest_series=$(list_url "$parent" | grep -oE "(^|[\"/>])${re_series}([\"/<]|\$)" \
				| grep -oE "${re_series}" | sort -uV | tail -n 1 || true)
	    if [ -n "$newest_series" ] && [ "$newest_series" != "$series" ] \
		   && [ "$(printf '%s\n' "$series" "$newest_series" | sort -V | tail -n 1)" = "$newest_series" ]; then
		newest=$(newest_version "$parent/$newest_series" "$base")
		echo -e "${BLUE}NEW SERIES${RESET} $name: $newest_series${newest:+ (version $newest)}, in $parent/$newest_series"
	    fi
	fi
    done
    echo "To update the packages to the last version in the same series: ./$(basename "$0") --update"
    echo "The git packages follow their default branch, unless they are pinned (--pin)"
}

if [ -n "$OPT_CHECK_UPDATES" ]; then
    check_updates
    exit 0
fi

if [ -n "$OPT_LIST" ]; then
    list_packages
    exit 0
fi

if [ -n "$OPT_PIN" ]; then
    if [ -z "$OPT_PIN_REF" ]; then
	OPT_PIN_REF=$(last_good "$OPT_PIN")
	if [ -z "$OPT_PIN_REF" ]; then
	    echo -e "${RED}ERROR${RESET} there is no successful build of $OPT_PIN, give the tag, branch or commit"
	    exit 1
	fi
    fi
    set_pin "$OPT_PIN" "$OPT_PIN_REF"
    exit 0
fi

if [ -n "$OPT_UNPIN" ]; then
    set_pin "$OPT_UNPIN" ""
    exit 0
fi

# Update the versions in this script, and run it again to build them
if [ -n "$OPT_UPDATE" ]; then
    update_versions
    args=()
    for arg in "${ORIG_ARGS[@]}"; do
	[ "$arg" = "--update" ] || args+=("$arg")
    done
    exec "$SCRIPT" "${args[@]}"
fi

# Avoid two builds at the same time
exec 9>"$DIR/.build.lock"
if ! flock -n 9; then
    echo -e "${RED}ERROR${RESET} another build is running"
    exit 1
fi
: >"$LOG"

trap 'error_report $LINENO' ERR
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# A previous build was killed before restoring the installation
if [ -d "$ROLLBACK" ]; then
    echo -e "${YELLOW}RESTORING${RESET} installation from an interrupted build"
    rm -fr "$PREFIX"
    mv "$ROLLBACK" "$PREFIX"
fi

# The backups were installed with the same prefix, so they can be
# copied back.  The current installation is restored if this fails
if [ -n "$OPT_RESTORE" ]; then
    if [ "$OPT_RESTORE" = "last" ]; then
	backup=$(find "$BACKUP_DIR" -maxdepth 1 -type d -name 'emacs-git_*' 2>/dev/null | sort | tail -n 1)
    else
	backup="$BACKUP_DIR/emacs-git_$OPT_RESTORE"
    fi
    if [ -z "$backup" ] || [ ! -d "$backup" ]; then
	echo -e "${RED}ERROR${RESET} backup ${backup:-of the installation} not found in $BACKUP_DIR"
	exit 1
    fi

    echo -e "${YELLOW}RESTORING${RESET} installation from $backup"
    [ -d "$PREFIX" ] && mv "$PREFIX" "$ROLLBACK"
    cp -a "$backup" "$PREFIX"
    create_links
    remove_dangling_links
    create_shim "$PREFIX/bin/emacs" "$PREFIX_ROOT/emacs"
    create_shim "$PREFIX/bin/pylsp" "$PREFIX_ROOT/pylsp-remote"
    rm -fr "$ROLLBACK"
    SUCCESS=1
    echo "The configuration backups ($(basename "$EMACS_CONFIG"), $(basename "$EMACS_CONFIG_DIR")) are also in $BACKUP_DIR"
    echo -e "${BLUE}DONE${RESET}"
    exit 0
fi

# Installations from older versions of this script do not have
# stamps: build everything from scratch
[ -d "$STAMPS" ] || OPT_CLEAN=1

declare -A FORCE=()
for name in "${OPT_REBUILD[@]}"; do
    if [[ ! -v KNOWN[$name] ]]; then
	echo -e "${RED}ERROR${RESET} unknown package $name"
	exit 1
    fi
    FORCE["$name"]=1
done

mkdir -p "$DIR/artifacts" >>"$LOG" 2>&1
pushd "$DIR/artifacts" >>"$LOG" 2>&1

# Get or update all the sources before building anything
NAMES=()
METHODS=()
LOCATIONS=()
for package in "${PACKAGES[@]}"; do
    IFS=',' read -r name method url <<< "${package}"
    CURRENT="$name"
    case $method in
	"git")
	    git_clone_or_update "$name" "$url"
	    ;;
	"wget"*)
	    wget_get_or_update "$name" "$url"
	    ;;
	"pip")
	    pip_get_or_update "$name" "$url"
	    ;;
	*)
	    echo -e "${RED}ERROR${RESET} method $method not found"
	    exit 1
	    ;;
    esac
    NAMES+=("$name")
    METHODS+=("$method")
    LOCATIONS+=("$LOCATION")
done
CURRENT=

# Decide what to build.  The packages that depend on a rebuilt one are
# also rebuilt.  The pip packages are always installed, to get the
# last version
declare -A STAMP_OF=()
declare -A TODO_OF=()
STAMP_VALUES=()
SOURCE_VALUES=()
TODO=()
for i in "${!NAMES[@]}"; do
    name="${NAMES[$i]}"
    STAMP_VALUES[i]=
    SOURCE_VALUES[i]=
    TODO[i]=
    if [ "${METHODS[$i]}" = "pip" ]; then
	[ -n "$OPT_OFFLINE" ] || TODO[i]=1
	continue
    fi
    STAMP_VALUES[i]=$(package_stamp "$name" "${METHODS[$i]}" "${LOCATIONS[$i]}")
    SOURCE_VALUES[i]=$(package_source "${METHODS[$i]}" "${LOCATIONS[$i]}")
    STAMP_OF["$name"]="${STAMP_VALUES[$i]}"
    rebuild="$OPT_CLEAN"
    [[ -v FORCE[$name] ]] && rebuild=1
    [ "${STAMP_VALUES[$i]}" != "$(cat "$STAMPS/$name" 2>/dev/null)" ] && rebuild=1
    for dep in ${DEPENDS[$name]:-}; do
	[[ -v TODO_OF[$dep] ]] && rebuild=1
    done
    if [ -n "$rebuild" ]; then
	TODO[i]=1
	TODO_OF["$name"]=1
    fi
done

if [ -n "$(printf '%s' "${TODO[@]}")" ]; then
    snapshot_prefix
fi

EMACS_REBUILT=
for i in "${!NAMES[@]}"; do
    name="${NAMES[$i]}"
    if [ -z "${TODO[$i]}" ]; then
	if [ "${METHODS[$i]}" = "pip" ]; then
	    echo -e "${YELLOW}SKIPPING${RESET} pip $name (offline)"
	else
	    echo -e "${GREEN}UP TO DATE${RESET} $name"
	fi
	continue
    fi
    CURRENT="$name"
    compile_and_install "${LOCATIONS[$i]}" "$name" "${METHODS[$i]}"
    if [ -n "${STAMP_VALUES[$i]}" ]; then
	mkdir -p "$STAMPS"
	echo "${STAMP_VALUES[$i]}" > "$STAMPS/$name"
	echo "${SOURCE_VALUES[$i]}" > "$STAMPS/$name.source"
    fi
    if [ "$name" = "emacs" ]; then
	EMACS_REBUILT=1
    fi
done
CURRENT="configuration"

create_backup
configure
write_early_init
cp -a eglot-x.el "$EMACS_CONFIG_DIR/lisp"
if [ -n "$EMACS_REBUILT" ] && [ -f /usr/include/libgccjit.h ]; then
    find "$EMACS_CONFIG_DIR/" -name '*.eln' -delete
fi
create_links
remove_dangling_links
create_shim "$PREFIX/bin/emacs" "$PREFIX_ROOT/emacs"
create_shim "$PREFIX/bin/pylsp" "$PREFIX_ROOT/pylsp-remote"
create_ld_shim "/usr/bin/gs" "$PREFIX_ROOT/gs"
check_libraries

release_snapshot
SUCCESS=1

for message in "${WARNINGS[@]}"; do
    echo -e "${YELLOW}WARNING${RESET} $message"
done
echo -e "${BLUE}DONE${RESET}"

popd >>"$LOG" 2>&1
