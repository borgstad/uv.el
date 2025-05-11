;;; uv.el --- Interface to uv -*- lexical-binding: t -*-

;; Copyright (C) 2025-  Andreas Borgstad

;; Author: Gaby Launay <aborgstad@gmail.com>
;; URL: https://github.com/borgstad/uv.el
;; Keywords: Python, Tools
;; Package-Version: 0.2.0
;; Package-Requires: ((transient "0.2.0") (emacs "25.1"))

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

(require 'cl-lib)
(require 'transient)
(require 'subr-x)

(defgroup uv nil
  "Uv in Emacs."
  :prefix "uv-"
  :group 'tools)

(defmacro uv-with-current-file (file &rest body)
  "Execute the forms in BODY while temporary visiting FILE."
  `(save-current-buffer
     (let* ((file ,file)
            (keep (find-buffer-visiting file))
            (buffer (find-file-noselect file)))
       (set-buffer buffer)
       (prog1
           (progn
             ,@body)
         (unless keep
           (kill-buffer buffer))))))

;;;###autoload (autoload 'uv "uv" nil t)
(transient-define-prefix uv ()
  "Uv menu."
  [:description ("Uv")]
  [:if uv-find-project-root
       :description "Dependencies    "
       ("a" "Add" uv-add)
       ("r" "Remove" uv-remove)
       ("l" "Lock" uv-lock)
       ]
  [:if uv-find-project-root
    :description "Project"
	("e" "Edit 'pyproject.toml'" uv-edit-pyproject-toml)
	("b" "Build" uv-build)
	("p" "Publish" uv-publish)]
  [:if-not uv-find-project-root
    :description "Project"
    ("i" "Init" uv-init)]
  )

(transient-define-prefix uv-add ()
  "Uv add dependency menu."
  ["Arguments"
   (uv:--git)
   (uv:--path)
   (uv:--python)
   (uv:--platform)
   ]
  ["Add"
   ("a" "Add a dependency" uv-add-dep)
   ("d" "Add a development dependency" uv-add-dev-dep)
   ("o" "Add an optional dependency" uv-add-opt-dep)
   ])

(transient-define-argument uv:--git ()
  :description "Git repository"
  :class 'transient-option
  :key "-g"
  :argument "--git=")

(transient-define-argument uv:--path ()
  :description "Dependency path"
  :class 'transient-option
  :key "-P"
  :argument "--path=")

(transient-define-argument uv:--python ()
  :description "Python version"
  :class 'transient-option
  :key "-p"
  :argument "--python=")

(transient-define-argument uv:--platform ()
  :description "Platforms"
  :class 'transient-option
  :key "-t"
  :argument "--platform=")

(transient-define-argument uv:--extras ()
  :description "Extra sets of dependencies to install"
  :class 'transient-option
  :key "-E"
  :argument "--extras=")

(defun uv-call-add (package-string &optional args)
  "Add packages from PACKAGE-STRING (space-separated) as dependencies.
ARGS are additional arguments passed to ``uv add''."
  (let* ((transient (transient-args 'uv-add))
         ;; Split the package string into a list of individual package names
         (package-list (split-string package-string " " t)) ; =t= discards empty strings
         ;; Combine the list of package names, the explicit args, and the transient args
         (full-uv-args (append package-list (or args '()) transient)))

    ;; Call the base uv-call function with 'add and the combined arguments
    (uv-call 'add full-uv-args)))

;;;###autoload
(defun uv-add-dep (package-string)
  "Add PACKAGE-STRING (space-separated) as new dependencies.
Uses ``uv add''."
  (interactive "sPackage name(s): ")
  (message "Adding dependency: %s" package-string)
  ;; Call uv-call-add with the package string and no extra args list
  (uv-call-add package-string))

;;;###autoload
(defun uv-add-dev-dep (package-string)
  "Add PACKAGE-STRING (space-separated) as new development dependencies.
Uses ``uv add -D''."
  (interactive "sPackage name(s): ")
  (message "Adding dev dependency: %s" package-string)
  ;; Call uv-call-add with the package string and the '-D' argument
  (uv-call-add package-string '("-D")))

;;;###autoload
(defun uv-add-opt-dep (package)
  "Add PACKAGE as a new optional dependency to the project.

PACKAGE can be a list of packages, separated by spaces."
  (interactive "sPackage name(s): ")
  (message "Adding optional dependency: %s" package)
  (uv-call-add package '("--optional")))

;;;###autoload
(defun uv-remove (package type)
  "Remove PACKAGE from the project dependencies.
TYPE is the type of dependency (dep, dev or opt)."
  (interactive (let* ((packages (cl-concatenate 'list
				 (cl-map 'list
				      (lambda (dep)
					(format "[dep]  %s" dep))
				      (uv-get-dependencies))
				 (cl-map 'list
				      (lambda (dep)
					(format "[dev]  %s" dep))
				      (uv-get-dependencies t))
				 (cl-map 'list
				      (lambda (dep)
					(format "[opt]  %s" dep))
				      (uv-get-dependencies nil t))))
		      (package (when packages
				 (completing-read "Package: "
						  packages
						  nil t))))
		 (if (not package)
		     (list nil nil)
		   (string-match "^\\[\\(.*\\)\\]  \\([^[:space:]]*\\)[[:space:]]*(\\(.*\\))$" package)
		   (list (match-string 2 package)
			 (match-string 1 package)))))
  (if (not package)
      (uv-error "No packages to remove")
    (pcase type
      ("dep"
       (uv-message (format "Removing package %s"
			       package))
       (uv-remove-dep package))
      ("opt"
       (uv-message (format "Removing optional package %s"
			       package))
       (uv-remove-dep package))
      ("dev"
       (uv-message (format "Removing development package %s"
			       package))
       (uv-remove-dev-dep package)))))

(defun uv-remove-dep (package)
  "Remove PACKAGE from the project dependencies."
  (uv-call 'remove (list package)))

(defun uv-remove-dev-dep (package)
  "Remove PACKAGE from the project development dependencies."
  (uv-call 'remove (list package "-D")))

;;;###autoload
(defun uv-install-install ()
  "Install the project dependencies."
  (interactive)
  (let ((args (transient-args 'uv-install)))
    (uv-call 'install args)))

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
(defun uv-publish (repo username password)
  "Publish the package to a remote repository.

REPO is the repository and USERNAME and PASSWORD the
credential to use."
  (interactive (list
		(completing-read "Repository: "
				 (or (uv-publish-get-repositories)
				     (uv-error "No repository configured, please use `uv config` to add repositories")
				     )
				 nil t)
		(read-string "Username: ")
		(read-passwd "Password: ")))
  (uv-call 'publish
	       (list "-r" repo "-u" username "-p" password)))

(defun uv-publish-get-repositories ()
  "Return the list of configured repostitories."
  (let ((repos (uv-get-configuration "repositories")))
    (mapcar #'car repos)))

;;;###autoload
(defun uv-new (path)
  "Create a new Python project at PATH."
  (interactive "GProject path: ")
  (let* ((path (expand-file-name path))
	 (project-name (file-name-base path))
	 (default-directory path))
    (message "Creating new project: %s" path)
    (unless (file-directory-p path)
      (make-directory path))
    (uv-call 'new (list path) path nil t)
    ;; Open __init__.py
    (find-file (concat (file-name-as-directory
			(concat (file-name-as-directory path)
				(uv-normalize-project-name project-name)))
		       "__init__.py"))
    (save-buffer)
    ;; make sure the virtualenv is created
    (message "Creating the virtual environment...")
    (uv-call 'env '("use" "python") nil nil t)
    (message "Done")))

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
  "Run COMMAND in the appropriate environment."
  (interactive (list (completing-read "Command: "
	   (let* ((file (uv-find-pyproject-file))
		  (scripts '()))
	     (when file
	       (uv-with-current-file file
		(goto-char (point-min))
		(when (re-search-forward
		       "^\\[tool\\.uv\\.scripts\\]" nil t)
		  (forward-line 1)
		  (beginning-of-line)
		  (while (re-search-forward
			  "^\\([^=]+\\)[[:space:]]*=[[:space:]]*\".*\"$"
			  (line-end-position) t)
		    (push (substring-no-properties (match-string 1)) scripts)
		    (forward-line)
		    (beginning-of-line)))))
	     scripts))))
  (uv-ensure-in-project)
  (uv-call 'run (split-string command "[[:space:]]+" t) nil t t))


(defun uv-call (command &optional args) ;; Removed output and blocking parameters
  "Call uv COMMAND with the given ARGS synchronously.
Signals an error if the uv process returns a non-zero exit code."

  (let* ((process-command "uv")
         (full-args (append (list (symbol-name command)) (or args '()))) ;; Ensure args is a list
         (output-buffer (get-buffer-create (uv-buffer-name)))
         exit-code)

    ;; Clear the output buffer and add command header
    (with-current-buffer output-buffer
      (setq buffer-read-only nil)
      (erase-buffer)
      (insert (format "uv %s\n" (string-join full-args " "))
              (make-string (window-width) ?-) "\n")) ;; Setting mode for colored output etc.

    ;; Call the process synchronously
    (setq exit-code (apply #'call-process
                           process-command
                           nil                 ; no input
                           output-buffer       ; stdout goes here
                           output-buffer       ; stderr goes here
                           full-args))         ; Pass the list of string arguments

    ;; Make the buffer read-only after the process finishes
    (with-current-buffer output-buffer (setq buffer-read-only t))

    ;; Check exit code and signal error if non-zero
    (unless (= exit-code 0)
      ;; Signal error
      (message "Command 'uv %s' failed with exit code %s. See buffer %s for details."
                (string-join full-args " ") exit-code (buffer-name output-buffer))
      ;; =uv-error= signals the error and stops execution here.
      )
    t))

;; Helpers
;;;;;;;;;;

(defun uv-get-configuration (key)
  "Return Uv configuration for KEY.

\(type `uv config --list' to get a list of usable configuration keys.)"
  (let ((bufname (uv-call 'config (list key) nil nil t)))
    (with-current-buffer bufname
      (when (progn
	      (goto-char (point-min))
	      (re-search-forward "ValueError" nil t))
	(uv-error "Unrecognized key configuration: %s" key))
      (goto-char (point-min))
      ;; Parse as JSON if possible, otherwise return trimmed string
      (let* ((json-key-type 'string)
	     (json-false nil)
	     (data (buffer-substring-no-properties
		    (point-min) (point-max)))
	     (rawconfig (replace-regexp-in-string
			 "'" "\"" data)))
	(condition-case nil
	    (json-read-from-string rawconfig)
	  (error (string-trim rawconfig)))))))

(defun uv-buffer-name (&optional suffix)
  "Return the uv buffer name, using SUFFIX is specified."
  (if suffix
      (format "*uv-%s*" suffix)
    "*uv*"))

(defun uv-normalize-project-name (project-name)
  "Return a normalized version of the PROJECT-NAME."
  (replace-regexp-in-string "-+" "_" (downcase project-name)))

(defun uv-display-buffer (&optional buffer-name)
  "Display the uv buffer or the BUFFER-NAME buffer."
  (with-current-buffer (or buffer-name (uv-buffer-name))
    (let ((buffer-read-only nil))
      (display-buffer (or buffer-name (uv-buffer-name))))))

(defun uv-get-dependencies (&optional dev opt)
  "Return the list of project dependencies.

If DEV is non-nil, install a developement dep.
If OPT is non-nil, set an optional dep."
  (uv-with-current-file (uv-find-pyproject-file)
     (goto-char (point-min))
     (if dev
	 (unless
	     (re-search-forward "^\\[tool\\.uv\\.dev-dependencies\\]"
				nil t)
	   (uv-error "No dependencies to remove"))
       (unless
	      (re-search-forward "^\\[tool\\.uv\\.dependencies\\]"
				 nil t)
	 (uv-error "No dependencies to remove")))
     (let ((beg (point))
	   (end (progn (re-search-forward "^\\[" nil t)
		       (point)))
	   (regex
	    "^\\(?1:[^= ]*\\)[[:space:]]*=[[:space:]]*\\({\\|\"\\)\\(?2:.*\\)\\(}\\|\"\\)")
	   deps
	   filtered-deps)
       (goto-char beg)
       (while (re-search-forward regex end t)
	 (push (format "%s (%s)"
		       (substring-no-properties (match-string 1))
		       (substring-no-properties (match-string 2)))
	       deps))
       ;; clean from opt/not opt deps
       (dolist (dep deps)
	 (if opt
	     (when (string-match "optional = true" dep)
	       (push (replace-regexp-in-string ",?[[:space:]]*optional = true" "" dep)
		     filtered-deps))
	   (when (not (string-match "optional = true" dep))
	       (push dep filtered-deps))))
       filtered-deps)))


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
(defun uv-ensure-in-project ()
  "Return an error if not in a uv project."
  (unless (find-project-root)
    (uv-error "Not in a uv project")))

(provide 'uv)
;;; uv.el ends here
