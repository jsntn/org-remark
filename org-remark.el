;;; org-remark.el --- Highlight & annotate any text files -*- lexical-binding: t; -*-

;; Copyright (C) 2020-2023 Free Software Foundation, Inc.

;; Author: Noboru Ota <me@nobiot.com>
;; URL: https://github.com/nobiot/org-remark
;; Version: 1.0.5
;; Created: 22 December 2020
;; Last modified: 14 January 2023
;; Package-Requires: ((emacs "27.1") (org "9.4"))
;; Keywords: org-mode, annotation, note-taking, marginal-notes, wp,

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This package lets you highlight and annotate any text file with using
;; Org mode.  For usage, refer to the user manual available as an Info
;; node by evaluating (info "org remark")

;;; Code:

;;;; Requirements

(require 'org)
(require 'org-id)
(require 'org-remark-global-tracking)
(declare-function org-remark-convert-legacy-data "org-remark-convert-legacy")


;;;; Customization

(defgroup org-remark nil
  "Highlight and annotate any text files with using Org mode."
  :group 'org
  :prefix "org-remark-"
  :link '(url-link :tag "GitHub" "https://github.com/nobiot/org-remark"))

(defface org-remark-highlighter
  '((((class color) (min-colors 88) (background light))
     :underline "#aecf90" :background "#ecf7ed")
    (((class color) (min-colors 88) (background dark))
     :underline "#00422a" :background "#001904")
    (t
     :inherit highlight))
  "Face for the default highlighter pen.")

(defcustom org-remark-create-default-pen-set t
  "When non-nil, Org-remark creates default pen set.
Set to nil if you prefer for it not to."
  :type 'boolean)

(defcustom org-remark-notes-display-buffer-action
  `((display-buffer-in-side-window)
    (side . left)
    (slot . 1))
  "Buffer display action that Org-remark uses to open marginal notes buffer.

The default is to use a side-window on the left.

Org-remark uses `pop-to-buffer', which passes this display action
list to `display-buffer'.  Refer to its documentation for more
detail and expected elements of the list."
  :type display-buffer--action-custom-type)

(defcustom org-remark-notes-buffer-name "*marginal notes*"
  "Buffer name of the marginal notes buffer.
`org-remark-open' and `org-remark-visit' create an indirect clone
buffer with this name."
  :type 'string)

(defvaralias
  'org-remark-source-path-function 'org-remark-source-file-name)

(make-obsolete-variable
 'org-remark-source-path-function 'org-remark-source-file-name "0.2.0")

(defcustom org-remark-source-file-name #'file-relative-name
  "Function that returns the file name to point back at the source file.

The function is called with a single argument: the absolute file
name of source file.  The `default-directory' is temporarily set
to the directory where the marginal notes file resides.

This means that when the \"Relative file name\" option is
selected, the source file name recorded in the marginal notes
file will be relative to it."
  :type '(choice
          (const :tag "Relative file name" file-relative-name)
          (const :tag "Abbreviated absolute file name" abbreviate-file-name)
          (function :tag "Other function")))

(defcustom org-remark-use-org-id nil
  "When non-nil, Org-remark adds an Org-ID link to marginal notes.
The link points at the relevant Org-ID in the source file.
Org-remark does not create this ID, which needs to be added
manually or some other function to either the headline or file."
  :type 'boolean)

(defcustom  org-remark-open-hook nil
  "Hook run when a note buffer is opened/visited.
The current buffer is the note buffer."
  :type 'hook)


;;;; Variables

(defvar-local org-remark-highlights '()
  "All the highlights in current source buffer.
It is a local variable and is a list of overlays.  Each overlay
represents a highlighted text region.

On `save-buffer' each highlight will be saved in the notes file
returned by `org-remark-notes-get-file-name'.")

(defvar-local org-remark-highlights-hidden nil
  "Hidden/shown state of the highlights in current source buffer.")

(defvar-local org-remark-notes-source-buffers '()
  "List of source buffers that have loaded current notes buffer.
Each notes buffer locally keeps track of the source buffers that
have loaded notes from itself.  This list is used when automatic
sync is triggered in `after-save-buffer' of the notes buffer, as
not all the sources may be open.  Buffers in this list may be
killed so that this needs to be checked with `buffer-live-p'.")

(defvar-local org-remark-source-setup-done nil
  "Local indicator that sync with notes buffer is set up.")

(defvar org-remark-last-notes-buffer nil
  "The cloned indirect buffer visiting the notes file.
It is meant to exist only one of these in each Emacs session.")

(defvar org-remark-available-pens nil)

;; Const for the names of properties in Org Mode
(defconst org-remark-prop-id "org-remark-id")
(defconst org-remark-prop-source-file "org-remark-file")
(defconst org-remark-prop-source-beg "org-remark-beg")
(defconst org-remark-prop-source-end "org-remark-end")


;;;; Macros to create user-defined highlighter pen functions

(defmacro org-remark-create (label &optional face properties)
  "Create and register new highlighter pen functions.

The newly created pen function will be registered to variable
`org-remark-available-pens'.  It is used by `org-remark-change'
as a selection list.

LABEL is the name of the highlighter and mandatory.  The function
will be named `org-remark-mark-LABEL'.

The highlighter pen function will apply FACE to the selected region.
FACE can be an anonymous face.  When FACE is nil, this macro uses
the default face `org-remark-highlighter'.

PROPERTIES is a plist of pairs of a symbol and value.  Each
highlighted text region will have a corresponding Org headline in
the notes file, and it can have additional properties in the
property drawer from the highlighter pen.  To do this, prefix
property names with \"org-remark-\" or use \"CATEGORY\"."
  (if (or (not label) (stringp label)
          (user-error "org-remark-create: Label is missing or not string"))
    `(progn
       ;; Define custom pen function
       (defun ,(intern (format "org-remark-mark-%s" label))
           (beg end &optional id mode)
         ,(format "Apply the following face to the region selected by BEG and END.

%s

Following overlay properties will be added to the highlighted
text region:

%S

Return the overlay.

When this function is used interactively, it will generate a new
ID, always assuming it is working on a new highlighted text
region, and Org-remark will start tracking the highlight's
location in the current buffer.

When this function is called from Elisp, ID can be optionally
passed, indicating to Org-remark that it is an existing
highlight.  In this case, no new ID gets generated.

When the pen itself defines the help-echo property, it will have
the priority over the excerpt of the marginal notes."
                  (or face "`org-remark-highlighter'") properties)
         (interactive (org-remark-region-or-word))
         (org-remark-highlight-mark beg end id mode ,label ,face ,properties))

       ;; Register to `org-remark-available-pens'
       (add-to-list 'org-remark-available-pens
                    (intern (format "org-remark-mark-%s" ,label)))

       ;; Add the custom pen function to the minor-mode menu
       (define-key-after org-remark-pen-map
         [,(intern (format "org-remark-mark-%s" label))]
         '(menu-item ,(format "%s pen" label) ,(intern (format "org-remark-mark-%s" label))))

       ;; Add the custom pen change function to the minor-mode menu
       (define-key-after org-remark-change-pen-map
         [,(intern (format "org-remark-change-to-%s" label))]
         '(menu-item ,(format "%s pen" label)
                     (lambda ()
                       (interactive)
                       (org-remark-change
                        #',(intern (format "org-remark-mark-%s" label)))))))))


;;;; Minor mode

;;;###autoload
(define-minor-mode org-remark-mode
    "Highlight and annotate any text file with using Org mode.
This is a local minor-mode.

On activation, it loads your saved highlights from the notes file
and enables automatic saving of highlights thereafter.

The automatic saving is achieved via function
`org-remark-save' added to `after-save-hook'.

On deactivation, it removes all the overlays and stops tracking
the highlights in this buffer by setting variable
`org-remark-highlights' to nil.  Be careful of behavior, if
you still wish to retain the locations of highlights.

It is recommended to use `org-remark-toggle' if you wish to
temporarily hide highlights in the current buffer.  It keeps
`org-remark-highlights' unchanged.

While the tracking of highlights is stopped,
editing the buffer will likely result in mismatch between the
saved highlights' locations and the current buffer's text
content.

Highlights tracked by variable `org-remark-highlights' cannot
persist when you kill the buffer or quit Emacs.  When you
re-launch Emacs and visit the same file, ensure to turn on
`org-remark-mode' to load the highlights from the marginalia
file.  `org-remark-global-tracking-mode' automates this.  It is
recommended to turn it on as part of Emacs initialization.

\\{org-remark-mode-map}"
    :init-value nil
    :lighter " ormk"
    :global nil
    :keymap (let ((map (make-sparse-keymap)))
              map)
    (cond
     (org-remark-mode
      ;; Activate
      (org-remark-highlights-load)
      (add-hook 'after-save-hook #'org-remark-save nil t))
     (t
      ;; Deactivate
      (when org-remark-highlights
        (dolist (highlight org-remark-highlights)
          (delete-overlay highlight)))
      (setq org-remark-highlights nil)
      (remove-hook 'after-save-hook #'org-remark-save t))))


;;;; Org-remark Menu
(defvar org-remark-menu-map
  (make-sparse-keymap "Org-remark"))

(define-key-after org-remark-menu-map
  [org-remark-open]
  '(menu-item "Open" org-remark-open
              :help "Display and move to marginal notes for highlight at point"))

(define-key-after org-remark-menu-map
  [org-remark-view]
  '(menu-item "View" org-remark-view
              :help "Display marginal notes for highlight at point; stay in current buffer"))

(define-key-after org-remark-menu-map
  [org-remark-view-next]
  '(menu-item "View next" org-remark-view-next))

(define-key-after org-remark-menu-map
  [org-remark-view-prev]
  '(menu-item "View previous" org-remark-view-prev))

(define-key-after org-remark-menu-map
  [org-remark-toggle]
  '(menu-item "Toggle" org-remark-toggle
              :help "Toggle showing/hiding of highlights in current buffer"))

(define-key-after org-remark-menu-map
  [org-remark-remove]
  '(menu-item "Remove" org-remark-remove
              :help "Remove highlight at point, keeping the marginal notes entry"))

(define-key-after org-remark-menu-map
  [org-remark-delete]
  '(menu-item "Delete" org-remark-delete
              :help "Delete highlight at point and the marginal notes entry"))

;; Make pen functions menu
(defvar org-remark-pen-map
  (make-sparse-keymap "Org-remark-mark"))

(define-key-after org-remark-pen-map
  [org-remark-mark]
  '(menu-item "default pen" org-remark-mark))

;; Make change pen menu
(defvar org-remark-change-pen-map
  (make-sparse-keymap "Org-remark-change"))

(define-key-after org-remark-change-pen-map
  [org-remark-change]
  '(menu-item "default pen" (lambda ()
                              (interactive)
                              (org-remark-change #'org-remark-mark))))

;; Add change menu to the parent menu
(define-key-after org-remark-menu-map
  [org-remark-change-pens]
  (list 'menu-item "Change to..." org-remark-change-pen-map)
  'org-remark-toggle)

;; Add pen menu to the parent menu
(define-key org-remark-menu-map
            [org-remark-pens]
            (list 'menu-item "Highlight with..." org-remark-pen-map))

;; Add all to the main menu
(define-key org-remark-mode-map
            [menu-bar org-remark]
            (list 'menu-item "Org-remark" org-remark-menu-map))


;;;; Commands

(add-to-list 'org-remark-available-pens #'org-remark-mark)

;;;###autoload
(defun org-remark-mark (beg end &optional id mode)
  "Apply face `org-remark-highlighter' to the region between BEG and END.

When this function is used interactively, it will generate a new
ID, always assuming it is working on a new highlighted text
region.

Return the highlight overlay.

A Org headline entry for the highlight will be created in the
marginal notes file specified by
`org-remark-notes-get-file-name'.  If the file does not exist
yet, it will be created.

When this function is called from Elisp, ID can be
optionally passed, indicating to Org-remark that it is to load an
existing highlight.  In this case, no new ID gets generated and
the highlight saved again, avoiding the unnecessary round-trip
back to the database.

MODE is also an argument which can be passed from Elisp.  It
determines whether or not highlight is to be saved in the
marginal notes file.  The expected values are nil, :load and
:change."
  (interactive (org-remark-region-or-word))
  ;; FIXME
  ;; Adding "nil" is different to removing a prop
  ;; This will do for now
  (org-remark-highlight-mark beg end id mode
                             nil nil
                             (list 'org-remark-label "nil")))

(when org-remark-create-default-pen-set
  ;; Create default pen set.
  (org-remark-create "red-line"
                     '(:underline (:color "dark red" :style wave))
                     '(CATEGORY "review" help-echo "Review this"))
  (org-remark-create "yellow"
                     '(:inherit default :underline "gold2")
                     '(CATEGORY "important")))

(defun org-remark-save ()
  "Save all the highlights tracked in current buffer to notes buffer.

This function is automatically called when you save the current
buffer via `after-save-hook'.

`org-remark-highlights' is the local variable that tracks every highlight
in the current buffer.  Each highlight is an overlay."
  (interactive)
  (org-remark-highlights-housekeep)
  (org-remark-highlights-sort)
  (let ((notes-buf (find-file-noselect (org-remark-notes-get-file-name)))
        (source-buf (or (buffer-base-buffer) (current-buffer)))
        (filename (org-remark-source-find-file-name)))
    (dolist (h org-remark-highlights)
      (let* ((beg (overlay-start h))
             (end (overlay-end h))
             (props (overlay-properties h)))
        (org-remark-highlight-save filename beg end props)))
    ;;; Avoid saving the notes buffer if it is the same as the source buffer
    (if (eq source-buf notes-buf)
        (set-buffer-modified-p nil)
      (with-current-buffer notes-buf
        (save-buffer)))))

(defun org-remark-open (point &optional view-only)
  "Open marginal notes file for highlight at POINT.
The marginal notes will be narrowed to the relevant headline to
show only the highlight at point.

This function creates a cloned indirect buffer for the marginal
notes file.  You can edit it as a normal Org buffer.  Once you
have done editing, you can simply save and kill the buffer or
keep it around.

The marginal notes file gets displayed by the action defined by
`org-remark-notes-display-buffer-action' (by default in a left
side window of the current frame), narrowed to the relevant
headline.

You can customize the name of the marginal notes buffer with
`org-remark-notes-buffer-name'.

By default, the cursor will go to the marginal notes buffer for
further editing.  When VIEW-ONLY is non-nil \(e.g. by passing a
universal argument with \\[universal-argument]\), you can display
the marginal notes buffer with the cursor remaining in the
current buffer.

This function ensures that there is only one cloned buffer for
notes file by tracking it."
  (interactive "d\nP")
  (when-let ((id (get-char-property point 'org-remark-id))
             (ibuf (org-remark-notes-buffer-get-or-create))
             (cbuf (current-buffer)))
    (pop-to-buffer ibuf org-remark-notes-display-buffer-action)
    (widen)
    (when-let (p (org-find-property org-remark-prop-id id))
      ;; Somehow recenter is needed when a highlight is deleted and move to a
      ;; previous highlight.  Otherwise, the cursor is too low to show the
      ;; entire entry.  It looks like there is no entry.
      (goto-char p)(org-narrow-to-subtree)(org-end-of-meta-data t)(recenter))
    ;; Run hook with the current-buffer being the note's buffer
    (run-hooks 'org-remark-open-hook)
    ;; Avoid error when buffer-action is set to display a new frame
    (when-let ((view-only view-only)
               (window (get-buffer-window cbuf)))
      (select-window window))))

(defun org-remark-view (point)
  "View marginal notes for highlight at POINT.
The marginal notes file gets displayed by the action defined by
`org-remark-notes-display-buffer-action' (by default in a side
window in the left of the current frame), narrowed to the
relevant headline.  The cursor remains in the current buffer.

Also see the documentation of `org-remark-open'."
  (interactive "d")
  (org-remark-open point :view-only))

(defun org-remark-next ()
  "Move to the next highlight, if any.
If there is none below the point but there is a highlight in the
buffer, cycle back to the first one.

After the point has moved to the next highlight, this command
lets you move further by re-entering only the last letter like
this example:

   C-n \] \] \] \] \] \(assuming this command is bound to C-n \]\)

This is achieved by transient map with `set-transient-map'.

If you have the same prefix for `org-remark-prev', you can combine it in
the sequence like so:

   C-n \] \] \] \[ \["
  (interactive)
  (org-remark-next-or-prev :next))

(defun org-remark-prev ()
  "Move to the previous highlight, if any.
If there is none above the point, but there is a highlight in the
buffer, cycle back to the last one.

After the point has moved to the previous highlight, this command
lets you move further by re-entering only the last letter like
this example:

   C-n \[ \[ \[ \[ \[ \(assuming this command is bound to C-n \[\)

This is achieved by transient map with `set-transient-map'.

If you have the same prefix for `org-remark-next', you can combine it in
the sequence like so:

   C-n \] \] \] \[ \["
  (interactive)
  (org-remark-next-or-prev))

(defun org-remark-view-next ()
  "Move the cursor to the next highlight and view its marginal notes."
  (interactive)
  (org-remark-next)(org-remark-view (point)))

(defun org-remark-view-prev ()
  "Move the cursor to the previous highlight and view its marginal notes."
  (interactive)
  (org-remark-prev)(org-remark-view (point)))

(defun org-remark-toggle ()
  "Toggle showing/hiding of highlights in current buffer.
If you would like to hide/show the highlights in the current
buffer, it is recommended to use this command instead of
`org-remark-mode'.  This command only affects the display of the
highlights and their locations are still kept tracked.  Toggling
off `org-remark-mode' stops this tracking completely, which will
likely result in inconsistency between the marginal notes file
and the current source buffer."
  (interactive)
  (if org-remark-highlights-hidden
      (org-remark-highlights-show)
    (org-remark-highlights-hide))
  t)

(defun org-remark-change (&optional pen)
  "Change the highlight at point to PEN.
This function will show you a list of available pens to choose
from."
  (interactive)
  (when-let* ((ov (org-remark-find-overlay-at-point))
              (id (overlay-get ov 'org-remark-id))
              (beg (overlay-start ov))
              (end (overlay-end ov)))
    (let ((new-pen (if pen pen
                     (intern
                      (completing-read "Which pen?:" org-remark-available-pens)))))
      (org-remark-highlight-clear ov)
      (funcall new-pen beg end id :change))))

(defun org-remark-remove (point &optional delete)
  "Remove the highlight at POINT.
It will remove the highlight and the properties from the
marginalia, but will keep the headline and annotations.  This is
to ensure to keep any notes you might have written intact.

You can let this command DELETE the entire heading subtree for
the highlight, along with the annotations you have written, by
passing a universal argument with \\[universal-argument].
If you have done so by error, you could still `undo' it in the
marginal notes buffer, but not in the current buffer as adding
and removing overlays are not part of the undo tree."
  (interactive "d\nP")
  (when-let ((ov (org-remark-find-overlay-at-point point))
             (id (overlay-get ov 'org-remark-id)))
    ;; Remove the highlight overlay and id Where there is more than one,
    ;; remove only one.  It should be last-in-first-out in general but
    ;; overlays functions don't guarantee it (when delete
    ;; (org-remark-open point :view-only))
    (org-remark-highlight-clear ov)
    ;; Update the notes file accordingly
    (org-remark-notes-remove id delete)
    (org-remark-highlights-housekeep)
    (org-remark-highlights-sort)
    t))

(defun org-remark-delete (point)
  "Delete the highlight at POINT and marginal notes for it.

This function will prompt for confirmation if there is any notes
present in the marginal notes buffer.  When the marginal notes
buffer is not displayed in the current frame, it will be
temporarily displayed together with the prompt for the user to
see the notes.

If there is no notes, this function will not prompt for
confirmation and will remove the highlight and deletes the entry
in the marginal notes buffer.

This command is identical with passing a universal argument to
`org-remark-remove'."
  (interactive "d")
  (org-remark-remove point :delete))


;;;; Private Functions

;;;;; org-remark-find
;;    Find a highlight (e.g. next/prev or overlay)

(defun org-remark-next-or-prev (&optional next)
  "Move cursor to the next or previous highlight if any.
When NEXT is non-nil, move to the next; for nil, to the previous.

This function is internal only and meant to be used by interactive
commands such as `org-remark-next' and `org-remark-prev'.

Return t if the cursor has moved to next/prev.
Return nil if not and outputs a message in the echo."
  (if (not org-remark-highlights)
      (progn (message "No highlights present in the buffer") nil)
    (let ((p (if next (org-remark-find-next-highlight)
               (org-remark-find-prev-highlight))))
      (if p (progn
              (goto-char p)
              ;; Setup the overriding keymap.
              (unless overriding-terminal-local-map
                (let ((prefix-keys (substring (this-single-command-keys) 0 -1))
                      (map (cdr org-remark-mode-map)))
                  (when (< 0 (length prefix-keys))
                    (mapc (lambda (k) (setq map (assq k map))) prefix-keys)
                    (setq map (cdr-safe map))
                    (when (keymapp map) (set-transient-map map t)))))
              t)
        (message "No visible highlights present in the buffer")
        nil))))

(defun org-remark-find-next-highlight ()
  "Return the beg point of the next highlight.
Look through `org-remark-highlights' list."
  (when-let ((points (org-remark-highlights-get-positions)))
      ;; Find the first occurrence of p > (point). If none, this means all the
      ;; points occur before the current point. Take the first one. Assume
      ;; `org-remark-highlights' is sorted in the ascending order (it is).
    (seq-find (lambda (p) (> p (point))) points (nth 0 points))))

(defun org-remark-find-prev-highlight ()
  "Return the beg point of the previous highlight.
Look through `org-remark-highlights' list (in descending order)."
  (when-let ((points (org-remark-highlights-get-positions 'reverse)))
      ;; Find the first occurrence of p < (point). If none, this means all the
      ;; points occur before the current point. Take the first one. Assume
      ;; `org-remark-highlights' is sorted in the descending order .
    (seq-find (lambda (p) (< p (point))) points (nth 0 points))))

(defun org-remark-find-overlay-at-point (&optional point)
  "Return one org-remark overlay at POINT.
When point is nil, use the current point.
If there are more than one, return CAR of the list."
  (let* ((pt (or point (point)))
         (overlays (overlays-at pt))
         found)
    (while overlays
      (let ((overlay (car overlays)))
        (if (overlay-get overlay 'org-remark-id)
            (setq found (cons overlay found))))
      (setq overlays (cdr overlays)))
    (car found)))

(defun org-remark-find-overlay-in (beg end &optional id)
  "Return one org-remark overlay between BEG and END.
If there are more than one, return CAR of the list.
Optionally ID can be passed to find the exact ID match."
  (let* ((overlays (overlays-in beg end))
         found)
    (while overlays
      (let ((overlay (car overlays)))
        (if (overlay-get overlay 'org-remark-id)
            (setq found (cons overlay found))))
      (setq overlays (cdr overlays)))
    (when id (setq found
                   (seq-filter
                    (lambda (ov)
                      (equal (overlay-get ov 'org-remark-id) id))
                    found)))
    (car found)))


;;;;; org-remark-highlight
;;   Private functions that work on a single highlight.  A highlight is an
;;   overlay placed on a a part of text.  With using an analogy of pens
;;   and books, a highlight is the mark you make over a part of a book
;;   with a highlighter pen or marker.
;;
;;   As highlights are overlays placed on the source buffer, the
;;   functions here mostly assume the current buffer is the source
;;   buffer.

(defun org-remark-highlight-mark
    (beg end &optional id mode label face properties)
  "Apply the FACE to the region selected by BEG and END.

This function will apply FACE to the selected region.  When it is
nil, this function will use the default face `org-remark-highlighter'

This function will add LABEL and PROPERTIES as overlay
properties.  PROPERTIES is a plist of pairs of a symbol and value.

Return the highlight overlay.

When this function is used interactively, it will generate a new
ID, always assuming it is working on a new highlighted text
region, and Org-remark will start tracking the highlight's
location in the current buffer.

MODE determines whether or not highlight is to be saved in the
marginal notes file.  The expected values are nil, :load and
:change.

An Org headline entry for the highlight will be created in the
marginal notes file specified by `org-remark-notes-get-file-name'.
If the file does not exist yet, it will be created.

When this function is called from Elisp, ID can be optionally
passed, indicating to Org-remark that it is to load an existing
highlight.  In this case, no new ID gets generated and the
highlight will not be saved again, avoiding the unnecessary
round-trip back to the notes file."
  ;; Ensure to turn on the local minor mode
  (unless org-remark-mode (org-remark-mode +1))
  ;; When highlights are toggled hidden, only the new one gets highlighted in
  ;; the wrong toggle state.
  (when org-remark-highlights-hidden (org-remark-highlights-show))
  (let ((ov (make-overlay beg end nil :front-advance))
        ;; UUID is too long; does not have to be the full length
        (id (if id id (substring (org-id-uuid) 0 8)))
        (filename (org-remark-source-find-file-name))
        (notes-props))
    (if (not filename)
        (message "org-remark: Highlights not saved; buffer is not supported")
      (org-with-wide-buffer
       (overlay-put ov 'face (if face face 'org-remark-highlighter))
       (while properties
         (let ((prop (pop properties))
               (val (pop properties)))
           (overlay-put ov prop val)))
       (when label (overlay-put ov 'org-remark-label label))
       (overlay-put ov 'org-remark-id id)
       ;; Keep track of the overlay in a local variable. It's a list that is
       ;; guaranteed to contain only org-remark overlays as opposed to the one
       ;; returned by `overlay-lists' that lists all overlays.
       (push ov org-remark-highlights)
       ;; for mode, nil and :change result in saving the highlight.  :load
       ;; bypasses save.
       (unless (eq mode :load)
         ;; Get props for create and change
         (setq notes-props
               (org-remark-highlight-save filename
                                          beg end
                                          (overlay-properties ov)
                                          (org-remark-highlight-get-title)))
         (when notes-props
           (unless (overlay-get ov 'help-echo)
             (overlay-put ov 'help-echo (plist-get notes-props :body)))
           (overlay-put ov '*org-remark-note-body
                        (plist-get notes-props :body)))
         ;; Save the notes buffer when not loading
         (let ((notes-buf (find-file-noselect (org-remark-notes-get-file-name))))
           (unless (eq notes-buf (current-buffer))
             (with-current-buffer notes-buf (save-buffer))))))
      (deactivate-mark)
      (org-remark-highlights-housekeep)
      (org-remark-highlights-sort)
      (setq org-remark-source-setup-done t)
      ;; Return overlay
      ov)))

(defun org-remark-highlight-get-title ()
  "Return the title of the source buffer.
The title is either the title keyword for an Org buffer, or the
file name of the source buffer.  When the source is not a
file (e.g. a website), it is its file name equivalent, such as
the URL for a website.

This function assumes
the current buffer is the source buffer.

Utility function to work with a single highlight overlay."
  (or (cadr (assoc "TITLE" (org-collect-keywords '("TITLE"))))
      (let* ((full-name (org-remark-source-find-file-name))
             (filename (if (and (string= "" (file-name-nondirectory full-name))
                                (string-match "[\/]+\\'" full-name))
                           ;; The name ends with a / (possibly a URL).
                           ;; Trim all the slashes at the end of the
                           ;; name.
                           (replace-match "" t t full-name)
                         full-name)))
        (if (or (null filename) (string= "" filename))
            (error "Could not extract highlight title")
            (file-name-sans-extension (file-name-nondirectory filename))))))

(defun org-remark-highlight-get-org-id (point)
  "Return Org-ID closest to POINT of the source buffer.
This function does this only when `org-remark-use-org-id' is
non-nil.  Returns nil otherwise, or when no Org-ID is found.

This function assumes the current buffer is the source buffer."
  (and org-remark-use-org-id
       (org-entry-get point "ID" :inherit)))

(defun org-remark-highlight-save (filename beg end props &optional title)
  "Save a single HIGHLIGHT in the marginal notes file.

Return the highlight's data properties list (TODO refer to ...).

FILENAME is the name of source file with which the marginal notes
buffer is associated.  When the source buffer does not visit a
file (e.g. a website), it is the source buffer's file name
equivalent, such as the URL.

BEG and END are the range of the highlight being saved.  It
is the highlight overlay's start and end.

PROPS are the highlight overlay's properties.  Not all the
properties will be added as headline properties.  Refer to
`org-remark-notes-set-properties'.

For the first highlight of the source buffer, this function will
create a new H1 headline for it at the bottom of the marginal
notes buffer with TITLE as its headline text.

When called for a new highlight that is unsaved in the marginal
notes file, this function will create a new H2 headline with the
highlighted text as its headline text at the end of the H1
headline for the source buffer.

If a headline with the same ID already exists, update its
position and properties named \"org-remark-*\" and CATEGORY from
the highlight overlay.  For update, the headline text will be
kept intact, because the user might have changed it to their
needs.

This function will also add a normal file link as property
\"org-remark-link\" of the H2 headline entry, pointing back to
the source file with search option \"::line-number\", or for
non-file sources, calls `run-hook-with-args-until-success' for
`org-remark-highlight-link-to-source-functions' with FILENAME as
the argument.

ORGID can be passed to this function.  If user option
`org-remark-use-org-id' is non-nil, this function will add an
Org-ID link in the body text of the headline, linking back to the
source with using ORGID.

When the current source buffer is not set up for sync with notes,
this function calls `org-remark-notes-setup' to prepare the notes
buffer for automatic sync."
  (let* ((filename (org-remark-source-get-file-name filename))
         (id (plist-get props 'org-remark-id))
         (text (org-with-wide-buffer
                (replace-regexp-in-string
                 "\n" " "
                 (buffer-substring-no-properties beg end))))
         (notes-buf (find-file-noselect (org-remark-notes-get-file-name)))
         (source-buf (current-buffer))
         (line-num (org-current-line beg))
         (orgid (org-remark-highlight-get-org-id beg))
         (link (if buffer-file-name
                   (concat "[[file:" filename
                           (when line-num (format "::%d" line-num)) "]]")
                 (run-hook-with-args-until-success
                  'org-remark-highlight-link-to-source-functions filename)))
         (notes-props))
    ;;; Set up notes buffer for sync for the source buffer
    (unless org-remark-source-setup-done
      (org-remark-notes-setup notes-buf source-buf))
    (with-current-buffer notes-buf
      (when (featurep 'org-remark-convert-legacy) (org-remark-convert-legacy-data))
      ;;`org-with-wide-buffer' is a macro that should work for non-Org file
      (org-with-wide-buffer
       (let ((file-headline
              (or (org-find-property
                   org-remark-prop-source-file filename)
                  (progn
                    ;; If file-headline does not exist, create one at the bottom
                    (goto-char (point-max))
                    ;; Ensure to be in the beginning of line to add a new headline
                    (when (eolp) (open-line 1) (forward-line 1) (beginning-of-line))
                    (insert (concat "* " title "\n"))
                    (org-set-property org-remark-prop-source-file filename)
                    (org-up-heading-safe) (point))))
             (id-headline (org-find-property org-remark-prop-id id)))
         ;; Add org-remark-link with updated line-num as a property
         (when link (plist-put props "org-remark-link" link))
         (if id-headline
             (progn
               (goto-char id-headline)
               ;; Update the existing headline and position properties
               ;; Don't update the headline text when it already exists
               ;; Let the user decide how to manage the headlines
               ;; (org-edit-headline text)
               (org-remark-notes-set-properties beg end props))
           ;; No headline with the marginal notes ID property. Create a new one
           ;; at the end of the file's entry
           (goto-char file-headline)
           (org-narrow-to-subtree)
           (goto-char (point-max))
           ;; Ensure to be in the beginning of line to add a new headline
           (when (eolp) (open-line 1) (forward-line 1) (beginning-of-line))
           ;; Create a headline
           ;; Add a properties
           (insert (concat "** " text "\n"))
           (org-remark-notes-set-properties beg end props)
           (when (and orgid org-remark-use-org-id)
             (insert (concat "[[id:" orgid "]" "[" title "]]"))))
         (setq notes-props (list :body (org-remark-notes-get-body)))))
      notes-props)))

(defun org-remark-highlight-load (highlight)
  "Load a single HIGHLIGHT to the source buffer.
Assume the current buffer is the source buffer."
  (let* ((id (plist-get highlight :id))
         (location (plist-get highlight :location))
         (beg (car location))
         (end (cdr location))
         (label (plist-get highlight :label))
         (ov nil)
         (props (plist-get highlight :props)))
    (let ((fn (intern (concat "org-remark-mark-" label))))
      (unless (functionp fn) (setq fn #'org-remark-mark))
      (setq ov (funcall fn beg end id :load))
      ;; TODO Generalize the part that updates properties.
      ;; :body should not be the fixed property.
      ;; '(:text (val . fn) :prop1 (val . fn) :prop2 (val .fn))
      ;; (dolist list)
      (unless (overlay-get ov 'help-echo)
        (overlay-put ov 'help-echo (plist-get props :body)))
      (overlay-put ov '*org-remark-note-body
                   (plist-get props :body)))))

(defun org-remark-highlight-clear (overlay)
  "Clear a single highlight OVERLAY.
It is a utility function to take care of both
`org-remark-highlights' and a highlight overlay at the same time."
  (setq org-remark-highlights (delete overlay org-remark-highlights))
  (delete-overlay overlay))


;;;;; org-remark-notes
;;    Private functions that work on marginal notes buffer (notes
;;    buffer).  Notes buffer visits an Org file, which serves as plain
;;    text database whose main purpose is to persist the location of
;;    highlights and body text for them if any. Each highlight can also
;;    hold properties related to Org-remark.  Their names are prefixed
;;    with "org-remark".  The exception to this is the Org's standard
;;    CATEGORY, which can be set as a property for Org-remark's custom
;;    highlighter pens.

;;    The Org file database has the following data structure and thus
;;    headline levels are fixed:

;;        H1: File (for non-file visiting buffer, file name equivalent
;;            such as URL for a website)
;;        H2: Highlight (each one has a dedicated H2 subtree)

;;    In general, -notes-* functions assume the current buffer is the
;;    notes buffer.  One remark on a subtlety: Org-remark clones an
;;    indirect buffer of notes buffer; this is meant to be user
;;    convenience. Users might interact with either the indirect buffer
;;    or directly with the base buffer.  For automatic sync
;;    functionality, Org-remark interacts directly with the base buffer.

(defun org-remark-notes-remove (id &optional delete)
  "Remove the note entry for highlight ID.
By default, it deletes only the properties of the entry keeping
the headline intact.  You can pass DELETE and delete the entire
note entry.

Return t if an entry is removed or deleted."
  (let* ((ibuf (org-remark-notes-buffer-get-or-create))
         (window? (get-buffer-window ibuf)))
    (with-current-buffer ibuf
      (org-with-wide-buffer
       (when-let ((id-headline (org-find-property org-remark-prop-id id)))
         (goto-char id-headline)
         (org-narrow-to-subtree)
         (dolist (prop (org-entry-properties))
           (when (string-prefix-p "org-remark-" (downcase (car prop)))
             (org-delete-property (car prop))))
         (when delete
           ;; CATEGORY prop won't be deleted. Move to line after props
           (org-end-of-meta-data t)
           (when-let (ok-to-delete?
                      (if (looking-at ".")
                          ;; If there is a content, display and prompt for
                          ;; confirmation
                          (progn
                            ;; This does not display the location correctly
                            ;; TODO This comment does not make sense now. Delete?
                            (display-buffer ibuf
                                            org-remark-notes-display-buffer-action)
                            (y-or-n-p "Highlight removed but notes exist.  \
Do you really want to delete the notes?"))
                        ;; If there is no content, it's OK
                        t))
             (delete-region (point-min)(point-max))
             (message "Deleted the marginal notes entry")))))
      (when (buffer-modified-p) (save-buffer))
      ;; Quit the marginal notes indirect buffer if it was not there
      ;; before the remove/delete -- go back to the original state.
      (when-let (ibuf-window (get-buffer-window ibuf))
        (unless window? (quit-window nil ibuf-window ))))
    t))

(defun org-remark-notes-buffer-get-or-create ()
  "Return marginal notes buffer.
It's a cloned indirect buffer of a buffer visiting the marginal
notes file of the current buffer.  This function ensures there is
only one of the marginal notes buffer per session."
  ;; Compare the target marginal notes buffer and current marginal notes buffer.
  ;; For the latter, we need the base buffer of an indirect buffer.
  (let ((cbuf (find-file-noselect (org-remark-notes-get-file-name)))
        (ibuf (when (buffer-live-p org-remark-last-notes-buffer)
                org-remark-last-notes-buffer)))
    (unless (eq (buffer-base-buffer ibuf) cbuf)
      ;; Fixed the issue of killing the main buffer when there is no
      ;; indirect buffer created yet
      (when ibuf (kill-buffer ibuf))
      (setq ibuf (make-indirect-buffer cbuf org-remark-notes-buffer-name
                                       :clone)))
    ;; set the variable and return the indirect buffer
    (setq org-remark-last-notes-buffer ibuf)))

(defun org-remark-notes-set-properties (beg end &optional props)
  "Set properties for the headline in the notes file.
Return t.

Minimal properties are:

- org-remark-id :: ID
- org-remark-source-beg :: BEG
- org-remark-source-end :: END

And the following are also reserved for Org-remark:
- org-remark-link

For PROPS, if the property name is CATEGORY \(case-sensitive\) or
prefixed with \"org-remark-\" set them to to headline's property
drawer.

In order to avoid adding org-remark-* overlay properties to Org
properties, add prefix \"*\"."

  (org-set-property org-remark-prop-source-beg
                    (number-to-string beg))
  (org-set-property org-remark-prop-source-end
                    (number-to-string end))

  ;; Delete property.  Prefer `org-entry-delete' over
  ;; `org-delete-property' as the former is silent.
  (org-entry-delete nil "CATEGORY")
  ;; TODO generalize org-entry-delete for other props so that they can
  ;; be deleted when the value previously existed and now being deleted.

  (while props
    (let ((p (pop props))
          (v (pop props)))
      (when (symbolp p) (setq p (symbol-name p)))
      (when (or (string-equal "CATEGORY" (upcase p))
                (and (> (length p) 11)
                     (string-equal "org-remark-" (downcase (substring p 0 11)))))
        (org-set-property p v))))
  t)

(defun org-remark-notes-get-body ()
  "Return the text body of a highlight in the notes buffer."
  (let ((full-text
         (save-excursion
           (org-end-of-meta-data :full)
           (if
               ;; handle empty annotation
               ;; (org-end-of-meta-data :full) took us to next org heading):
               (or (looking-at org-heading-regexp)
                   (eobp)) ;; end of buffer
               "[empty entry]"
             (buffer-substring-no-properties
              (point)
              (org-end-of-subtree))))))
    ;; TODO Consider customizing var for the max length 200
    (if (< 200 (length full-text))
        (substring-no-properties full-text 0 200)
      full-text)))

(defun org-remark-notes-setup (notes-buf source-buf)
  "Set up NOTES-BUF and SOURCE-BUF for sync.

Note that this function adds some local variables only to the
base-buffer of the notes and not to the indirect buffer."
  (let ((base-buf (or (buffer-base-buffer notes-buf) notes-buf)))
    (with-current-buffer base-buf
      (unless (member source-buf org-remark-notes-source-buffers)
        (cl-pushnew source-buf org-remark-notes-source-buffers)
        (add-hook 'after-save-hook #'org-remark-notes-sync-with-source nil :local))))
  (with-current-buffer source-buf
    (setq org-remark-source-setup-done t)))

(defun org-remark-notes-housekeep ()
 "Remove killed buffers from `org-remark-notes-source-buffers'."
 (setq org-remark-notes-source-buffers
       (seq-filter #'buffer-live-p org-remark-notes-source-buffers)))

(defun org-remark-notes-update-source (source-buffer)
  "Update SOURCE-BUFFER with marginal notes properties.
This function assumes the current buffer is one visiting the
notes file (indrect or base)."
  (let ((notes-buf (current-buffer)))
    (with-current-buffer source-buffer
      (dolist (highlight (org-remark-highlights-get notes-buf))
        (let* ((location (plist-get highlight :location))
               (beg (car location))
               (end (cdr location))
               (id (plist-get highlight :id))
               (ov (org-remark-find-overlay-in beg end id)))
          ;; In order to update the overlay, it is first gets deleted
          ;; and newly loaded.  This way, we avoid duplicate of the same
          ;; highlight.

          ;; FIXME Currently the when clause is used to guard against
          ;; the case wheremarkre a highlight overlay is not found.  It should
          ;; be an edge case but the highlight could have moved to a
          ;; completely new location where the old location does not
          ;; overlap with the new location at all.
          (when ov (org-remark-highlight-clear ov))
          (org-remark-highlight-load highlight))))))

(defun org-remark-notes-sync-with-source ()
  "Update sources from the current notes buffer.
This function iterates through `org-remark-notes-source-buffers'
in the base buffer of the notes.

It is meant to be used in `after-save-hook'."
  ;;; Assume the current buffer is either the indirect or notes buffer
  ;;; in question.  In order for the `after-save-hook' to correctly
  ;;; triggers notes sync, we need to get the base buffer if the note
  ;;; buffer being saved is an indirect one.
  (let ((notes-buffer (or (buffer-base-buffer) (current-buffer))))
    (with-current-buffer notes-buffer
      (org-remark-notes-housekeep)
      (dolist (source-buf org-remark-notes-source-buffers)
        (org-remark-notes-update-source source-buf)))))


;;;;; org-remark-highlights
;;    Work on all the highlights in the current buffer

(defun org-remark-highlights-get (notes-buf)
  "Return a list of highlights from NOTES-BUF.
The file name is returned by `org-remark-notes-get-file-name'.
It is assumed that the current buffer is source buffer.  Each
highlight is a property list in the following properties:
    (:id ID :location (BEG . END) :label LABEL :props (PROPERTIES)"
  ;; Set source-file-name first, as `find-file-noselect' will set the
  ;; current-buffer to source-file-name. Issue #39 FIXME: A way to make
  ;; this sequence agnostic is preferred, if there is a function that
  ;; visit file but not set the current buffer
  (when-let ((source-file-name (org-remark-source-get-file-name
                                (org-remark-source-find-file-name)))
             (notes-buf notes-buf))
    ;; TODO check if there is any relevant notes for the current file
    ;; This can be used for adding icon to the highlight
    (let ((highlights))
      (with-current-buffer notes-buf
        (when (featurep 'org-remark-convert-legacy)
          (org-remark-convert-legacy-data))
        (org-with-wide-buffer
         (let ((heading (org-find-property
                         org-remark-prop-source-file source-file-name)))
           (if (not heading)
               (message "No highlights or annotations found for %s."
                        source-file-name)
             (goto-char heading)
             ;; Narrow to only subtree for a single file.  `org-find-property'
             ;; ensures that it is the beginning of a headline
             (org-narrow-to-subtree)
             (org-show-children)
             ;; It's important that the headline levels are fixed
             ;; H1: File
             ;; H2: Highlighted region (each one has a dedicated H2 subtree)
             (while (not (org-next-visible-heading 1))
               (when-let ((id (org-entry-get (point) org-remark-prop-id))
                          (beg (string-to-number
                                (org-entry-get (point)
                                               org-remark-prop-source-beg)))
                          (end (string-to-number
                                (org-entry-get (point)
                                               org-remark-prop-source-end)))
                          (text (org-remark-notes-get-body)))
                 (push (list :id id
                             :location (cons beg end)
                             :label    (org-entry-get (point) "org-remark-label")
                             :props    (list :body text))
                       highlights))))
           highlights))))))

(defun org-remark-highlights-load ()
  "Visit `org-remark-notes-file' & load the saved highlights onto current buffer.
If there is no highlights or annotations for current buffer,
output a message in the echo.

Highlights tracked locally by variable `org-remark-highlights'
cannot persist when you kill current buffer or quit Emacs.  It is
recommended to set `org-remark-global-tracking-mode' in your
configuration.  It automatically turns on `org-remark-mode'.

Otherwise, do not forget to turn on `org-remark-mode' manually to
load the highlights"
  ;; Loop highlights and add them to the current buffer
  (let ((notes-buf (find-file-noselect (org-remark-notes-get-file-name)))
        (source-buf (current-buffer)))
    (dolist (highlight (org-remark-highlights-get notes-buf))
      (org-remark-highlight-load highlight))
    (org-remark-notes-setup notes-buf source-buf))
  t)

(defun org-remark-highlights-get-positions (&optional reverse)
  "Return list of the beginning point of all visible highlights in this buffer.
By default, the list is in ascending order.  If REVERSE is
non-nil, return list in the descending order.

This function also checks if the position is visible or not.
Return only visible ones.

If none, return nil."
  (when org-remark-highlights
    (let ((list org-remark-highlights))
      (setq list (mapcar
                  (lambda (h)
                    (let ((p (overlay-start h)))
                      ;; Checking if the p is visible or not
                      (if (or
                           (> p (point-max))
                           (< p (point-min))
                           ;; When the highlight is within a visible folded
                           ;; area, this function returns 'outline
                           (org-invisible-p p))
                          nil p)))
                  list))
      (setq list (remove nil list))
      (when list
        (if reverse (reverse list) list)))))

(defun org-remark-highlights-sort ()
  "Utility function to sort `org-remark-highlights'.
It checks if there is any element exists for `org-remark-highlights'.
Instead of receiving it as an arg, it assumes its existence.  It
also destructively updates `org-remark-highlights'.
It returns t when sorting is done."
  (when org-remark-highlights
    (setq org-remark-highlights
          (seq-sort-by (lambda (ov) (overlay-start ov))
                       #'<
                       org-remark-highlights))
    t))

(defun org-remark-highlights-hide ()
  "Hide highlights.
This function removes the font-lock-face of all the highlights,
and add *org-remark-hidden property with value t. It does not
check the current hidden state, thus not interactive.  Use
`org-remark-toggle' command to manually toggle the show/hide
state."
  (when-let ((highlights org-remark-highlights))
    (dolist (highlight highlights)
      (overlay-put highlight '*org-remark-face (overlay-get highlight 'face))
      (overlay-put highlight 'face nil)
      (overlay-put highlight '*org-remark-hidden t))
    (setq org-remark-highlights-hidden t)))

(defun org-remark-highlights-show ()
  "Show highlights.
This function adds the font-lock-face to all the highlighted text
regions.  It does not check the current hidden state, thus not
interactive.  Use `org-remark-toggle' command to manually toggle
the show/hide state."
  (when-let ((highlights org-remark-highlights))
    (dolist (highlight highlights)
      (overlay-put highlight '*org-remark-hidden nil)
      (overlay-put highlight 'face (overlay-get highlight '*org-remark-face)))
    (setq org-remark-highlights-hidden nil)))

(defun org-remark-highlights-housekeep ()
  "House keep the internal variable `org-remark-highlights'.

Return t.

This is a private function; house keep is automatically done on
mark, save, and remove -- before sort-highlights.

Case 1. Both start and end of an overlay are identical

        This should not happen when you manually mark a text
        region.  A typical cause of this case is when you delete a
        region that contains a highlight overlay.

        This also happens when EWW reloads the buffer or
        re-renders any part of the buffer.  This is because it
        removes overlays on re-render by calling
        `remove-overlays'.

Case 2. The overlay points to no buffer

        This case happens when overlay is deleted by
        `overlay-delete' but the variable not cleared."
  (dolist (ov org-remark-highlights)
    ;; Both start and end of an overlay are identical; this should not
    ;; happen when you manually mark a text region. A typical cause of
    ;; this case is when you delete a region that contains a highlight
    ;; overlay. This also happens when EWW reloads the buffer or
    ;; re-renders any part of the buffer. This is because it removes
    ;; overlays on re-render by calling `remove-overlays', which edits
    ;; the overlay-start and overlay-end properties. To guard against
    ;; this, we check if the buffer is write-able and only remove the
    ;; annotation when it is.
    (when (and (overlay-buffer ov)
               (= (overlay-start ov) (overlay-end ov)))
      (when (and (not buffer-read-only)
                 (not (derived-mode-p 'special-mode)))
                ;; buffer-size 0 happens for package like nov.el It
                ;; erases the buffer (size 0) and renders a new page in
                ;; the same buffer.  In this case, buffer is writable.
        ;; Removing the notes here is meant to be automatically remove
        ;; notes when you delete a region that contains a higlight
        ;; overlay.

        ;; TODO Relying on the current major mode being derived from
        ;; special-mode is not the best.
        (org-remark-notes-remove (overlay-get ov 'org-remark-id)))
      (delete-overlay ov))
    (unless (overlay-buffer ov)
      (setq org-remark-highlights (delete ov org-remark-highlights))))
  t)


;;;;; Other utilities
(defun org-remark-source-get-file-name (filename)
  "Convert FILENAME either to absolute or relative for marginal notes files.
Returns the standardized filename.

The current buffer is assumed to be visiting the source file.

FILENAME should be an absolute file name of the source file.

If FILENAME is nil, return nil."
  ;; Get the default-directory of the notes
  (when filename ; fix #23
    (with-current-buffer (find-file-noselect (org-remark-notes-get-file-name))
      (funcall org-remark-source-file-name filename))))

(defun org-remark-region-or-word ()
  "Return beg and end of the active region or of the word at point.
It is meant to be used within `interactive' in place for \"r\"
key.  The \"r\" key outputs an error when no mark is set. This
function extends the behavior and looks for the word at point"
  (let ((beg (mark))
        (end (point))
        (word (bounds-of-thing-at-point 'word)))
    ;; Use word's bounds when there is no active mark or one of beg/end is
    ;; missing. The latter can happen when there is no mark is set yet.
    (unless mark-active (setq beg (car word) end (cdr word)))
    ;; Check beg end is required as the cursor may be on an empty point with no
    ;; word under it.
    (if (and beg end)
        (progn
          (when (> beg end)
            (let ((large beg))
              (setq beg end
                    end large)))
          (list beg end))
      (user-error "No region selected and the cursor is not on a word"))))


;;;; Footer

(provide 'org-remark)

;;; org-remark.el ends here

;; Local Variables:
;; org-remark-notes-file-name: "README.org"
;; End:
