;;; projection-commands.el --- Run project-specific shell commands. -*- lexical-binding: t; -*-

;; Copyright (C) 2023  Mohsin Kaleem

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This module exposes a collection of functions to allow you to run distinct
;; shell commands (or elisp function) for different purposes in a project
;; specific way. This could involve separate commands to configure, build,
;; and test a project.

;;; Code:

(require 'subr-x)
(require 'projection-core)
(require 'projection-core-log)

(define-error 'projection-command-error "Project error" 'error)

(defun projection-commands--read-shell-command (project type default)
  "Interactively read a shell command for the command TYPE in PROJECT.
DEFAULT is the optional initial command that the user will be presented with."
  (read-shell-command
   (projection--prompt "%s project: " project
                       (capitalize (symbol-name type)))
   default
   'compile-history))

(defmacro projection-commands--ignore-no-command (&rest body)
  "Helper to run BODY and ignore any projection-command-errors."
  `(condition-case err
       (progn ,@body)
     (projection-command-error
      (projection--log :debug "%s" (cadr err))
      nil)))

(cl-defun projection-commands--get-command
    (project project-config cmd-type cmd-var &optional &key prompt (use-cache t))
  "Determine the command to do CMD-TYPE in PROJECT using PROJECT-CONFIG.
PROJECT-CONFIG should be the configuration for the current project type in
`projection-project-types'. CMD-VAR is the value of a directory local variable
to set the command. When PROMPT interactively ask the user for which command to
run. When When USE-CACHE read or write the command cache for the project (set
to \\='read or \\='write respectively to enable either of these operations)."
  (or
   ;; Interactively set the compilation command.
   (when prompt
     (let ((command
            (projection-commands--read-shell-command
             project cmd-type
             (projection-commands--ignore-no-command
              (when-let ((default-command
                           (projection-commands--get-command
                            project project-config cmd-type cmd-var)))
                (when (stringp default-command)
                  default-command))))))
       (pcase use-cache
         ((or 'write (guard use-cache)) (projection--cache-put project cmd-type command)))
       command))

   ;; Access the last cached compilation command for the current project.
   (pcase use-cache
     ((or 'read (guard use-cache)) (projection--cache-get project cmd-type)))

   ;; Command for cmd-type has been set using a directory-local variable.
   cmd-var

   ;; Read command from the current project-type.
   (let* ((type-command
           (when project-config
             (eieio-oref project-config cmd-type))))
     ;; Throw an error if no command could be resolved for CMD-TYPE.
     (unless type-command
       (if (projection--default-type-p project-config)
           (signal 'projection-command-error
                   (list (format-message "No project type matching project %s found and the default \
project-type does not support the command: %s"
                                         (project-root project) cmd-type)))
         (signal 'projection-command-error
                 (list (format-message "Project of type %s does not support the command: %s"
                                       (symbol-name (oref project-config name))
                                       cmd-type)))))

     ;; Sanitise compilation command and then cache it.
     (pcase type-command
       ((or (pred stringp) (pred commandp)))
       ((pred functionp)
        ;; When the command is a function, but not a command, the function should
        ;; return a shell command or interactive function to run instead.
        (setq type-command (funcall type-command))))
     type-command)))

(defvar projection-commands--registered-cmd-types nil
  "Cache of values registered by `projection-commands--register'.")

(defun projection-commands--run-command (project command cmd-type)
  "Run COMMAND for PROJECT as CMD-TYPE."
  (let ((default-directory (project-root project)))
    (cond
     ((stringp command)
      (compile command))
     ((commandp command)
      (call-interactively command))
     (t
      (user-error "Do not know how to run %s command %s" cmd-type command)))))

(defmacro projection-commands--register (type)
  "Define an interactive function to run a TYPE command on the current project."
  (let ((var-symbol (intern (concat "projection-project-" (symbol-name type) "-cmd")))
        (cmd-symbol (intern (concat "projection-" (symbol-name type) "-project")))
        (save-cmd-symbol (intern (concat "projection-set-" (symbol-name type) "-command"))))
    `(progn
       (projection--log :debug "Defining project command of type=%s" ',type)

       (defvar ,var-symbol nil
         ,(format "The command to use with `%s'.
It takes precedence over the default command for the project type when set.
Should be set via .dir-locals.el."
                  cmd-symbol))

       ;; Save the just registered command to an alist so we can later reference it.
       (add-to-list 'projection-commands--registered-cmd-types
                    (list ',type ',var-symbol #',cmd-symbol) t)

       (defun ,var-symbol (project &rest rest)
         ,(format "Get the %s command for PROJECT
When PROMPT interactively ask the user to set the %s command." (symbol-name type) (symbol-name type))
         (let* ((default-directory (project-root project))
                (project-type (projection-project-type (project-root project))))
           (apply #'projection-commands--get-command
            project project-type ',type ,var-symbol rest)))

       (defun ,cmd-symbol (project command)
         ,(format "Run COMMAND as the %s command for PROJECT." (symbol-name type))
         (interactive
          (let* ((project (projection--current-project))
                 (command (,var-symbol project :prompt current-prefix-arg)))
            (list project command)))
         (projection-commands--run-command project command ',type))

       (defun ,save-cmd-symbol (command project)
         ,(concat "Save COMMAND as the %s command for PROJECT." (symbol-name type))
         (interactive
          (list (read-shell-command "Compile command: ")
                (projection--current-project)))
         (projection--cache-put project ',type command)))))

;;;###autoload (autoload 'projection-configure-project "projection-commands" nil t)
;;;###autoload (autoload 'projection-set-configure-command "projection-commands" nil t)
(projection-commands--register configure)
;;;###autoload (autoload 'projection-build-project "projection-commands" nil t)
;;;###autoload (autoload 'projection-set-build-command "projection-commands" nil t)
(projection-commands--register build)
;;;###autoload (autoload 'projection-test-project "projection-commands" nil t)
;;;###autoload (autoload 'projection-set-test-command "projection-commands" nil t)
(projection-commands--register test)
;;;###autoload (autoload 'projection-run-project "projection-commands" nil t)
;;;###autoload (autoload 'projection-set-run-command "projection-commands" nil t)
(projection-commands--register run)
;;;###autoload (autoload 'projection-package-project "projection-commands" nil t)
;;;###autoload (autoload 'projection-set-package-command "projection-commands" nil t)
(projection-commands--register package)
;;;###autoload (autoload 'projection-install-project "projection-commands" nil t)
;;;###autoload (autoload 'projection-set-install-command "projection-commands" nil t)
(projection-commands--register install)



(defun projection-commands--read-command-type (prompt)
  "Read one of the defined command-types for projection projects.
PROMPT is the prompt shown in the minibuffer while reading the command type."
  (intern (completing-read
           prompt
           projection-commands--registered-cmd-types
           nil 'require-match)))

;;;###autoload
(defun projection-set-command-for-type (command project cmd-type)
  "Save COMMAND as the compilation command CMD-TYPE for PROJECT."
  (interactive
   (list (read-shell-command "Compile command: ")
         (projection--current-project)
         (projection-commands--read-command-type
          (format "Save command as type: "))))
  (projection--cache-put project cmd-type command))



(make-obsolete 'projection-project-command nil "0.1")
(make-obsolete-variable 'projection-cache-dynamic-commands nil "0.1")

(provide 'projection-commands)
;;; projection-commands.el ends here
