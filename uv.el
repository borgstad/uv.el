;;; uv.el --- Interface to uv -*- lexical-binding: t -*-

;; Copyright (C) 2025-  Andreas Borgstad

;; Author: Andreas Borgstad <aborgstad@gmail.com>
;; URL: https://github.com/borgstad/uv.el
;; Keywords: Python, Tools
;; Package-Version: 0.3.0
;; Package-Requires: ((transient "0.2.0") (emacs "26.1"))

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation; either version 3
;; of the License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program. If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;; This package offers an interface to uv (https://github.com/astral-sh/uv),
;; a Python dependency management and packaging command line tool.

;; uv.el uses transient to provide a magit-like interface. The
;; entry point is simply: `uv'

;; this package is based on https://github.com/cybniv/poetry.el, the
;; functionality was cloned 2025-05-03. Thanks for the effort.

;;; Code:

(require 'ansi-color)
(require 'compile)
(require 'transient)
(require 'subr-x)

(defgroup uv nil
  "Uv in Emacs."
  :prefix "uv-"
  :group 'tools)

(defcustom uv-executable "uv"
  "Name of, or path to, the uv executable."
  :type 'string
  :group 'uv)

(defmacro uv-with-current-file (file &rest body)
  "Execute the forms in BODY while temporary visiting FILE."
  (declare (indent 1) (debug t))
  (let ((keep (make-symbol "keep"))
        (buffer (make-symbol "buffer")))
    `(let* ((,keep (find-buffer-visiting ,file))
            (,buffer (find-file-noselect ,file)))
       (save-current-buffer
         (set-buffer ,buffer)
         (prog1
             (progn ,@body)
           (unless ,keep
             (kill-buffer ,buffer)))))))

;;;###autoload (autoload 'uv "uv" nil t)
(transient-define-prefix uv ()
  "Uv menu."
  [:if uv-find-project-root
   :description "Dependencies"
   ("a" "Add" uv-add)
   ("r" "Remove" uv-remove)
   ("l" "Lock" uv-lock)]
  [:if uv-find-project-root
   :description "Project"
   ("e" "Edit 'pyproject.toml'" uv-edit-pyproject-toml)
   ("b" "Build" uv-build)
   ("x" "Run" uv-run)]
  [:if-not uv-find-project-root
   :description "Project"
   ("i" "Init" uv-init)]
  [("o" "Show last output" uv-show-output)])

(transient-define-prefix uv-add ()
  "Uv add dependency menu."
  ["Arguments"
   (uv:--python)
   (uv:--editable)
   (uv:--branch)
   (uv:--tag)
   (uv:--rev)]
  ["Add"
   ("a" "Add a dependency" uv-add-dep)
   ("d" "Add a development dependency" uv-add-dev-dep)
   ("o" "Add an optional dependency" uv-add-opt-dep)])

(transient-define-argument uv:--python ()
  :description "Python interpreter"
  :class 'transient-option
  :key "-p"
  :argument "--python=")

(transient-define-argument uv:--editable ()
  :description "Add as editable"
  :class 'transient-switch
  :key "-e"
  :argument "--editable")

(transient-define-argument uv:--branch ()
  :description "Git branch"
  :class 'transient-option
  :key "-b"
  :argument "--branch=")

(transient-define-argument uv:--tag ()
  :description "Git tag"
  :class 'transient-option
  :key "-t"
  :argument "--tag=")

(transient-define-argument uv:--rev ()
  :description "Git commit"
  :class 'transient-option
  :key "-r"
  :argument "--rev=")

(defun uv-call-add (package-string &optional args)
  "Add packages from PACKAGE-STRING (space-separated) as dependencies.
ARGS are additional arguments passed to ``uv add''."
  (uv-call 'add (append (split-string package-string " " t)
                        args
                        (uv--transient-args 'uv-add))))

;;;###autoload
(defun uv-add-dep (package-string)
  "Add PACKAGE-STRING (space-separated) as new dependencies.
Uses ``uv add''."
  (interactive "sPackage name(s): ")
  (uv-call-add package-string))

;;;###autoload
(defun uv-add-dev-dep (package-string)
  "Add PACKAGE-STRING (space-separated) as new development dependencies.
Uses ``uv add --dev''."
  (interactive "sPackage name(s): ")
  (uv-call-add package-string '("--dev")))

;;;###autoload
(defun uv-add-opt-dep (package-string extra)
  "Add PACKAGE-STRING (space-separated) to the optional dependency EXTRA.
Uses ``uv add --optional''."
  (interactive "sPackage name(s): \nsOptional extra: ")
  (uv-call-add package-string (list "--optional" extra)))

;;;###autoload
(defun uv-remove (args)
  "Remove a dependency from the project.
ARGS are the ``uv remove'' arguments naming the package and its group."
  (interactive
   (progn
     (uv-ensure-in-project)
     (let ((candidates (uv--dependency-candidates)))
       (unless candidates
         (uv--error "No dependencies to remove"))
       (list (cdr (assoc (completing-read "Remove package: " candidates nil t)
                         candidates))))))
  (uv-call 'remove args))

;;;###autoload
(defun uv-lock ()
  "Locks the project dependencies."
  (interactive)
  (uv-call 'lock))

;;;###autoload
(defun uv-build ()
  "Build a package, as a tarball and a wheel by default."
  (interactive)
  (uv-call 'build))

;;;###autoload
(defun uv-init ()
  "Initialize a new Uv project."
  (interactive)
  (uv-call 'init))

;;;###autoload
(defun uv-edit-pyproject-toml ()
  "Open the current project `pyproject.toml' file for edition."
  (interactive)
  (uv-ensure-in-project)
  (find-file (uv-find-pyproject-file)))

;;;###autoload
(defun uv-run (command)
  "Run COMMAND in the project environment."
  (interactive
   (progn
     (uv-ensure-in-project)
     (list (completing-read "Command: " (uv--project-scripts)))))
  (uv-ensure-in-project)
  (uv-call 'run (split-string command "[[:space:]]+" t)))

(defun uv-call (command &optional args)
  "Run uv COMMAND with ARGS asynchronously, reporting in the minibuffer.
The full output is kept in the `uv-buffer-name' buffer, which is not
displayed.  Use `uv-show-output' to visit it."
  (let* ((default-directory (or (uv-find-project-root) default-directory))
         (command-line (mapconcat #'shell-quote-argument
                                  (cons uv-executable
                                        (cons (symbol-name command) args))
                                  " "))
         ;; keep the compilation buffer off-screen; the outcome is echoed instead
         (display-buffer-alist
          (cons (list (regexp-quote (uv-buffer-name))
                      #'display-buffer-no-window
                      '(allow-no-window . t))
                display-buffer-alist))
         ;; a pipe rather than a pty: uv then skips the progress spinner and its
         ;; erase-line escapes, and no CR is appended to every line
         (process-connection-type nil))
    (message "%s..." command-line)
    (compilation-start command-line #'uv-mode (lambda (_mode) (uv-buffer-name)))))

;;;###autoload
(defun uv-show-output ()
  "Display the output of the last uv command."
  (interactive)
  (if-let* ((buffer (get-buffer (uv-buffer-name))))
      (pop-to-buffer buffer)
    (uv--error "No uv command has been run yet")))

(define-derived-mode uv-mode compilation-mode "uv"
  "Major mode for uv command output."
  ;; uv is handed a pty by `compilation-start', so it emits colour
  (when (fboundp 'ansi-color-compilation-filter)
    (add-hook 'compilation-filter-hook #'ansi-color-compilation-filter nil t))
  (add-hook 'compilation-finish-functions #'uv--echo-result nil t))

;; Helpers
;;;;;;;;;;

(defun uv--error (format &rest args)
  "Signal a uv error using FORMAT and ARGS."
  (apply #'user-error (concat "uv: " format) args))

(defconst uv--noise-regexp
  (concat "\\`[[:space:]]*\\'"
          ;; per-package detail lines such as " + requests==2.34.2"
          "\\|\\`[[:space:]]"
          ;; the footer `compilation-handle-exit' appends
          "\\|\\`uv \\(?:finished\\|exited\\|interrupt\\|killed\\|terminated\\)")
  "Matches uv output lines not worth echoing in the minibuffer.")

(defun uv--result-line ()
  "Return the last informative line of uv output in the current buffer."
  (save-excursion
    (goto-char (point-max))
    (let (line)
      (while (and (not line) (not (bobp)))
        (forward-line -1)
        (let ((candidate (string-trim-right
                          (buffer-substring-no-properties
                           (line-beginning-position) (line-end-position)))))
          (unless (string-match-p uv--noise-regexp candidate)
            (setq line candidate))))
      line)))

(defun uv--echo-result (buffer status)
  "Echo how the uv run in BUFFER ended.  STATUS is its compilation status."
  (with-current-buffer buffer
    (let* ((failed (not (string-prefix-p "finished" status)))
           ;; truncate only the message, so the pointer to the buffer survives
           (suffix (if failed (format "  [%s]" (buffer-name)) ""))
           (line (or (uv--result-line) (string-trim status)))
           (text (concat (truncate-string-to-width
                          line
                          (max 20 (- (frame-width) 1 (string-width suffix)))
                          nil nil t)
                         suffix)))
      (message "%s" (if failed (propertize text 'face 'error) text)))))

(defun uv--transient-args (prefix)
  "Return the arguments of transient PREFIX, or nil when it is not active."
  (and (eq transient-current-command prefix)
       (transient-args prefix)))

(defun uv-buffer-name (&optional suffix)
  "Return the uv buffer name, using SUFFIX is specified."
  (if suffix
      (format "*uv-%s*" suffix)
    "*uv*"))

(defun uv--toml-table (name)
  "Move point past the header of TOML table NAME and return where it ends.
Return nil when the table is absent."
  (goto-char (point-min))
  (when (re-search-forward
         (concat "^[[:space:]]*\\[" (regexp-quote name) "\\][[:space:]]*$")
         nil t)
    (save-excursion
      ;; A failed search leaves point where it was, so fall back to point-max
      ;; explicitly rather than reading point back.
      (if (re-search-forward "^[[:space:]]*\\[" nil t)
          (match-beginning 0)
        (point-max)))))

(defun uv--toml-string-array (key limit)
  "Return the strings of the TOML array bound to KEY, searching up to LIMIT.
Search starts at point.  Bracket characters inside a quoted element, as in
\"uvicorn[standard]\", are skipped over with the element."
  (save-excursion
    (when (re-search-forward
           (concat "^[[:space:]]*" (regexp-quote key)
                   "[[:space:]]*=[[:space:]]*\\[")
           limit t)
      (let (values done)
        (while (not done)
          (skip-chars-forward "^]\"" limit)
          (cond
           ((>= (point) limit) (setq done t))
           ((eq (char-after) ?\]) (setq done t))
           (t
            (forward-char 1)
            (let ((start (point)))
              (skip-chars-forward "^\"" limit)
              (push (buffer-substring-no-properties start (point)) values)
              (unless (eobp) (forward-char 1))))))
        (nreverse values)))))

(defun uv--toml-array-keys (limit)
  "Return the array-valued keys of the TOML table ending at LIMIT.
Search starts at point."
  (save-excursion
    (let (keys)
      (while (re-search-forward
              "^[[:space:]]*\\([A-Za-z0-9_.-]+\\)[[:space:]]*=[[:space:]]*\\["
              limit t)
        (push (match-string-no-properties 1) keys))
      (nreverse keys))))

(defun uv--requirement-name (requirement)
  "Return the bare package name of the PEP 508 REQUIREMENT string."
  (if (string-match "\\`[[:space:]]*\\([A-Za-z0-9._-]+\\)" requirement)
      (match-string 1 requirement)
    requirement))

(defun uv--dependency-candidates ()
  "Return an alist of (DISPLAY . REMOVE-ARGS) for every declared dependency."
  (uv-with-current-file (uv-find-pyproject-file)
    (save-excursion
      (let (candidates)
        (let ((end (uv--toml-table "project")))
          (when end
            (dolist (req (uv--toml-string-array "dependencies" end))
              (push (cons (format "[dep]  %s" req)
                          (list (uv--requirement-name req)))
                    candidates))))
        (let ((end (uv--toml-table "project.optional-dependencies")))
          (when end
            (let ((start (point)))
              (dolist (extra (uv--toml-array-keys end))
                (goto-char start)
                (dolist (req (uv--toml-string-array extra end))
                  (push (cons (format "[opt:%s]  %s" extra req)
                              (list (uv--requirement-name req) "--optional" extra))
                        candidates))))))
        (let ((end (uv--toml-table "dependency-groups")))
          (when end
            (let ((start (point)))
              (dolist (group (uv--toml-array-keys end))
                (goto-char start)
                (dolist (req (uv--toml-string-array group end))
                  (push (cons (format "[%s]  %s" group req)
                              (list (uv--requirement-name req) "--group" group))
                        candidates))))))
        ;; uv wrote dev dependencies here before PEP 735 groups
        (let ((end (uv--toml-table "tool.uv")))
          (when end
            (dolist (req (uv--toml-string-array "dev-dependencies" end))
              (push (cons (format "[dev]  %s" req)
                          (list (uv--requirement-name req) "--dev"))
                    candidates))))
        (nreverse candidates)))))

(defun uv--project-scripts ()
  "Return the console scripts declared in the `[project.scripts]' table."
  (uv-with-current-file (uv-find-pyproject-file)
    (save-excursion
      (let ((end (uv--toml-table "project.scripts"))
            scripts)
        (when end
          (while (re-search-forward
                  "^[[:space:]]*\\([A-Za-z0-9_.-]+\\)[[:space:]]*=[[:space:]]*\""
                  end t)
            (push (match-string-no-properties 1) scripts)))
        (nreverse scripts)))))

;;;###autoload
(defun uv-find-project-root ()
  "Return the uv project root if any."
  (when-let* ((root (locate-dominating-file default-directory "pyproject.toml"))
              (pyproject-contents
               (with-temp-buffer
                 (insert-file-contents-literally (concat (file-name-as-directory root) "pyproject.toml"))
                 (buffer-string)))
              (_ (string-match "^\\[project\\]" pyproject-contents)))
    ;; If locate-dominating-file finds root, file is read, and pattern matches,
    ;; execute this body and return its value, which is the 'root'.
    root))

(defun uv-find-pyproject-file ()
  "Return the path to the current project `pyproject.toml', or nil."
  (when-let* ((root (uv-find-project-root)))
    (expand-file-name "pyproject.toml" root)))

(defun uv-ensure-in-project ()
  "Return an error if not in a uv project."
  (unless (uv-find-project-root)
    (uv--error "Not in a uv project")))

(provide 'uv)
;;; uv.el ends here
