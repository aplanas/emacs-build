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
