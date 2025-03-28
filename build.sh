#! /bin/bash

set -eu

DIR="$(cd "$(dirname "$0")"; pwd -P)"

# Configuration section
PREFIX_ROOT="$HOME/bin"
PREFIX="$PREFIX_ROOT/emacs-git"
LOG="$DIR/build.log"
EMACS_CONFIG="$HOME/.gnu-emacs"
EMACS_CONFIG_DIR="$HOME/.emacs.d"
PYTHON=$(readlink /usr/bin/python3)

# Set the environment variables
export PATH="$PATH":"$PREFIX/bin"
export PYTHONPATH="$PREFIX/lib/$PYTHON/site-packages:$PREFIX/lib64/$PYTHON/site-packages"

# Required for x11-macros
export ACLOCAL_PATH=$(aclocal --print-ac-dir):"$PREFIX/share/aclocal"

# Needed because giflib and libXpm
export LDFLAGS="-L$PREFIX/lib64 -L$PREFIX/lib"
export CPPFLAGS="-I$PREFIX/include"
export LD_LIBRARY_PATH="$PREFIX/lib64:$PREFIX/lib"
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

ASPELL_VER="0.60.8.1"
ASPELL_EN_VER="2020.12.07-0"
ASPELL_ES_VER="1.11-2"
NETTLE_VER="3.10.1"
GMP_VER="6.3.0"
LIBTASN1_VER="4.20.0"
GNUTLS_VER="3.8.9"
GIFLIB_VER="5.2.2"
LIBOTF_VER="0.9.16"
EMACS_VER="30.1"

# Packages list, in installation order.  If the package is from 'wget',
# the name will be deduced from the URL.  If the package is a 'git',
# the name of the repo needs to be like the first field of the tuple.
PACKAGES=(
    # Aspell
    "aspell","wget","ftp://ftp.gnu.org/gnu/aspell/aspell-$ASPELL_VER.tar.gz"
    "aspell6-en","wget","ftp://ftp.gnu.org/gnu/aspell/dict/en/aspell6-en-$ASPELL_EN_VER.tar.bz2"
    "aspell6-es","wget","ftp://ftp.gnu.org/gnu/aspell/dict/es/aspell6-es-$ASPELL_ES_VER.tar.bz2"

    # GNUTLS
    "nettle","wget","https://ftp.gnu.org/gnu/nettle/nettle-$NETTLE_VER.tar.gz"
    "gmp","wget","https://gmplib.org/download/gmp/gmp-$GMP_VER.tar.xz"
    "libtasn1","wget","https://ftp.gnu.org/gnu/libtasn1/libtasn1-$LIBTASN1_VER.tar.gz"
    "gnutls","wget","https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-$GNUTLS_VER.tar.xz"

    # ACL
    "attr","git","https://git.savannah.gnu.org/git/attr.git"
    "acl","git","https://git.savannah.gnu.org/git/acl.git"

    # Giflib/Libungif
    "xmlto","git","https://pagure.io/xmlto.git"
    "giflib","wget","https://downloads.sourceforge.net/project/giflib/giflib-$GIFLIB_VER.tar.gz"

    # LibXpm
    "macros","git","https://gitlab.freedesktop.org/xorg/util/macros.git"
    "libxpm","git","https://gitlab.freedesktop.org/xorg/lib/libxpm.git"

    # ImageMagick
    # "ImageMagick","wget","https://download.imagemagick.org/ImageMagick/download/ImageMagick.tar.gz"
    "ImageMagick","git","https://github.com/ImageMagick/ImageMagick.git"

    # Libotf
    "libotf","wget","http://download.savannah.gnu.org/releases/m17n/libotf-$LIBOTF_VER.tar.gz"

    # gpm
    "gpm","git","https://github.com/telmich/gpm.git"

    # tree-sitter
    "tree-sitter","git","https://github.com/tree-sitter/tree-sitter.git"

    # Emacs
    # "emacs","wget","http://mirrors.kernel.org/gnu/emacs/emacs-$EMACS_VER.tar.xz"
    "emacs","git","https://git.savannah.gnu.org/git/emacs.git"
    "elpa","git","https://git.savannah.gnu.org/git/emacs/elpa.git"
    "nongnu","git","https://git.savannah.gnu.org/git/emacs/nongnu.git"

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
)

# Extra parameters for packages.  Used for autotools and python
# packages.
declare -A COMPILE_OPTIONS=(
    ["gnutls"]="--with-included-unistring"
    ["libxpm"]="--disable-open-zfile"
    ["emacs"]="--with-imagemagick"
)
[ -f /usr/include/libgccjit.h ] && COMPILE_OPTIONS["emacs"]+=" --with-native-compilation"

# Used to return values from `git_clone_or_update`,
# `wget_get_or_update`, `pip_get_or_update` and `untar`, as those
# functions generate data to stdout
LOCATION=


function error_report  {
    echo -e "${RED}ERROR${RESET} on line $1"
}

trap 'error_report $LINENO' ERR

function exists {
    eval '[ ${'$2'[$1]+default_key} ]'
}

function normalize {
    local name=$1
    echo $name | tr '-' '_'
}

function create_backup {
    mkdir -p backup

    local backup="backup/emacs-git_$(date +"%Y%m%d")"
    if [ -d "$PREFIX" ]; then
	if [ ! -d "$backup" ]; then
	    echo -e "${GREEN}BACKUP${RESET} current installation to $backup"
	    mv "$PREFIX" "$backup"
	fi
    fi

    backup="backup/$(basename $EMACS_CONFIG)_$(date +"%Y%m%d")"
    if [ -f "$EMACS_CONFIG" ]; then
	if [ ! -f "$backup" ]; then
	    echo -e "${GREEN}BACKUP${RESET} current configuration to $backup"
	    mv "$EMACS_CONFIG" "$backup"
	fi
    fi

    backup="backup/$(basename $EMACS_CONFIG_DIR)_$(date +"%Y%m%d")"
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

    backup="backup/emacs_shim_$(date +"%Y%m%d")"
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

    if [ -d "$name" ]; then
	echo -e "${GREEN}UPDATING${RESET} $name repository"
	git -C "$name" fetch --all -p >>"$LOG" 2>&1 || echo -e "${RED}FAILED${RESET} $name repository"
	git -C "$name" pull --rebase >>"$LOG" 2>&1 || echo -e "${RED}FAILED${RESET} $name repository"
    else
	echo -e "${YELLOW}CLONING${RESET} $name repository"
	git clone "$url" >>"$LOG" 2>&1
    fi

    LOCATION="$name"
}

function wget_get_or_update {
    local name="$1"
    local url="$2"

    # Recover the name of the file
    local file_name=$(basename "$url")

    if [ -f "$file_name" ]; then
	echo -e "${GREEN}UPDATED${RESET} file $name"
    else
	echo -e "${YELLOW}DOWNLOADING${RESET} file $name"
	wget "$url" >>"$LOG" 2>&1
    fi

    LOCATION="$file_name"
}

function pip_get_or_update {
    local name="$1"
    local url="$2"

    echo -e "${YELLOW}DOWNLOADING${RESET} pip $name"

    LOCATION="$url"
}

function untar {
    local name="$1"

    case "$name" in
	*.tar.gz|*.tgz)
	    LOCATION=${name%.tar.gz}
	    LOCATION=${LOCATION%.tgz}
	    tar -xzvf "$name" >>"$LOG" 2>&1
	    ;;
	*.tar.bz2|*.tbz)
	    LOCATION=${name%.tar.bz2}
	    LOCATION=${LOCATION%.tbz}
	    tar -xjvf "$name" >>"$LOG" 2>&1
	    ;;
	*.tar.xz|*.txz)
	    LOCATION=${name%.tar.xz}
	    LOCATION=${LOCATION%.txz}
	    tar -xJvf "$name" >>"$LOG" 2>&1
	    ;;
	*.zip)
	    LOCATION=${name%.zip}
	    unzip "$name" >>"$LOG" 2>&1
	    ;;
	*)
	    echo -e "${RED}ERROR${RESET} file format not recognized $name"
	    exit 1
	    ;;
    esac

    # LOCATION can be a bit different (maybe with a version attached)
    LOCATION=$(find . -maxdepth 1 -type d -name "$LOCATION*" -print -quit)
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
    make -j 4 bootstrap >>"$LOG" 2>&1 || true
    make -j 4 >>"$LOG" 2>&1
    make install >>"$LOG" 2>&1
}

function compile_make {
    local prefix="$1"
    local options="$2"

    make -j 4 >>"$LOG" 2>&1
    PREFIX="$1" make install >>"$LOG" 2>&1
}

function compile_python {
    local prefix="$1"
    local package="$2"

    $PYTHON setup.py install --prefix="$prefix" "$package" >>"$LOG" 2>&1
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

    cargo build --release setup.py >>"$LOG" 2>&1
    mv target/release/"$package" "$prefix"/bin/"$package"  >>"$LOG" 2>&1
}

function _compile_aspell_dict {
    ./configure >>"$LOG" 2>&1
    make -j 4 >>"$LOG" 2>&1
    make install >>"$LOG" 2>&1
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

    make -j 4 >>"$LOG" 2>&1
    make PREFIX="$prefix" LIBDIR="$prefix/lib64" install >>"$LOG" 2>&1
}

function compile_emacs {
    local prefix="$1"
    local options="$2"

    [ -e .git ] && ./autogen.sh git >>"$LOG" 2>&1
    [ -e .git ] && ./autogen.sh autoconf >>"$LOG" 2>&1
    compile_autotools "$prefix" "$options"
}

function compile_elpa {
    :
}

function compile_nongnu {
    :
}

function compile_eglot_x {
    local prefix="$1"
    local options="$2"

    mv eglot-x.el "$EMACS_CONFIG_DIR/lisp"
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
	    cp -a "$location" build
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
    if exists $name COMPILE_OPTIONS; then
	extra="${COMPILE_OPTIONS[$name]}"
    fi

    local normalized_name=$(normalize $name)

    pushd build >>"$LOG" 2>&1
    # Check if there is a specific compilation function
    if [ "$(type -t "compile_${normalized_name}")" = "function" ]; then
	echo -e "${GREEN}COMPILING${RESET} $name with special function"
	compile_${normalized_name} "$PREFIX" "$extra"
    elif [ -f configure.* ] || [ -f autogen.sh ]; then
	echo -e "${GREEN}COMPILING${RESET} $name with general autotools function"
	compile_autotools "$PREFIX" "$extra"
    elif [ -f Makefile ]; then
	echo -e "${GREEN}COMPILING${RESET} $name with general make function"
	compile_make "$PREFIX" "$extra"
    elif [ -f setup.py ]; then
	echo -e "${GREEN}COMPILING${RESET} $name with general Python function"
	compile_python "$PREFIX" "$extra"
    elif [ "$method" = "pip" ]; then
	echo -e "${GREEN}COMPILING${RESET} $name with general pip function"
	compile_pip "$PREFIX" "$location" "$extra"
    elif [ -f Cargo.toml ]; then
	echo -e "${GREEN}COMPILING${RESET} $name with general Rust function"
	compile_rust "$PREFIX" "$extra"
    else
	echo -e "${RED}ERROR${RESET} compilation method for $name not found"
	exit 1
    fi
    popd >>"$LOG" 2>&1

    rm -fr build
}

function configure {
    cat >"$EMACS_CONFIG" <<'EOF'
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
(setq package-list '(use-package yaml-mode dockerfile-mode rust-mode go-mode web-mode markdown-mode company))

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

;; Golang mode
(add-to-list 'load-path "~/.emacs.d/lisp/go-mode.el/")
(autoload 'go-mode "go-mode" nil t)
(add-to-list 'auto-mode-alist '("\\.go\\'" . go-mode))

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
    ln -srf $PREFIX/bin/* "$PREFIX_ROOT"
}

function create_shim {
    local from=$1
    local to=$2

    rm "${to}" >>"$LOG" 2>&1 || true
    cat > "${to}" <<EOF
#! /bin/sh

if [ -z \$LD_LIBRARY_PATH ]; then
  export LD_LIBRARY_PATH=$PREFIX/lib64:$PREFIX/lib
else
  export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:$PREFIX/lib64:$PREFIX/lib
fi

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

create_backup

mkdir -p "$DIR/artifacts" >"$LOG" 2>&1
pushd "$DIR/artifacts" >>"$LOG" 2>&1

for package in "${PACKAGES[@]}"; do
    IFS=',' read name method url <<< "${package}"
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
    compile_and_install "$LOCATION" "$name" "$method"
done

configure
create_links
create_shim "$PREFIX/bin/emacs" "$PREFIX_ROOT/emacs"
create_shim "$PREFIX/bin/pylsp" "$PREFIX_ROOT/pylsp-remote"
create_ld_shim "/usr/bin/gs" "$PREFIX_ROOT/gs"

echo -e "${BLUE}DONE${RESET}"

popd >>"$LOG" 2>&1
