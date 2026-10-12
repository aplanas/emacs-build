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
