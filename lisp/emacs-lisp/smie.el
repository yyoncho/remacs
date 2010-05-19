;;; smie.el --- Simple Minded Indentation Engine

;; Copyright (C) 2010  Free Software Foundation, Inc.

;; Author: Stefan Monnier <monnier@iro.umontreal.ca>
;; Keywords: languages, lisp, internal, parsing, indentation

;; This file is part of GNU Emacs.

;; GNU Emacs is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; While working on the SML indentation code, the idea grew that maybe
;; I could write something generic to do the same thing, and at the
;; end of working on the SML code, I had a pretty good idea of what it
;; could look like.  That idea grew stronger after working on
;; LaTeX indentation.
;;
;; So at some point I decided to try it out, by writing a new
;; indentation code for Coq while trying to keep most of the code
;; "table driven", where only the tables are Coq-specific.  The result
;; (which was used for Beluga-mode as well) turned out to be based on
;; something pretty close to an operator precedence parser.

;; So here is another rewrite, this time following the actual principles of
;; operator precedence grammars.  Why OPG?  Even though they're among the
;; weakest kinds of parsers, these parsers have some very desirable properties
;; for Emacs:
;; - most importantly for indentation, they work equally well in either
;;   direction, so you can use them to parse backward from the indentation
;;   point to learn the syntactic context;
;; - they work locally, so there's no need to keep a cache of
;;   the parser's state;
;; - because of that locality, indentation also works just fine when earlier
;;   parts of the buffer are syntactically incorrect since the indentation
;;   looks at "as little as possible" of the buffer make an indentation
;;   decision.
;; - they typically have no error handling and can't even detect a parsing
;;   error, so we don't have to worry about what to do in case of a syntax
;;   error because the parser just automatically does something.  Better yet,
;;   we can afford to use a sloppy grammar.

;; The development (especially the parts building the 2D precedence
;; tables and then computing the precedence levels from it) is largely
;; inspired from page 187-194 of "Parsing techniques" by Dick Grune
;; and Ceriel Jacobs (BookBody.pdf available at
;; http://www.cs.vu.nl/~dick/PTAPG.html).
;;
;; OTOH we had to kill many chickens, read many coffee grounds, and practiced
;; untold numbers of black magic spells.

;;; Code:

(eval-when-compile (require 'cl))

;;; Building precedence level tables from BNF specs.

(defun smie-set-prec2tab (table x y val &optional override)
  (assert (and x y))
  (let* ((key (cons x y))
         (old (gethash key table)))
    (if (and old (not (eq old val)))
        (if (gethash key override)
            ;; FIXME: The override is meant to resolve ambiguities,
            ;; but it also hides real conflicts.  It would be great to
            ;; be able to distinguish the two cases so that overrides
            ;; don't hide real conflicts.
            (puthash key (gethash key override) table)
          (display-warning 'smie (format "Conflict: %s %s/%s %s" x old val y)))
      (puthash key val table))))

(defun smie-precs-precedence-table (precs)
  "Compute a 2D precedence table from a list of precedences.
PRECS should be a list, sorted by precedence (e.g. \"+\" will
come before \"*\"), of elements of the form \(left OP ...)
or (right OP ...) or (nonassoc OP ...)  or (assoc OP ...).  All operators in
one of those elements share the same precedence level and associativity."
  (let ((prec2-table (make-hash-table :test 'equal)))
    (dolist (prec precs)
      (dolist (op (cdr prec))
        (let ((selfrule (cdr (assq (car prec)
                                   '((left . >) (right . <) (assoc . =))))))
          (when selfrule
            (dolist (other-op (cdr prec))
              (smie-set-prec2tab prec2-table op other-op selfrule))))
        (let ((op1 '<) (op2 '>))
          (dolist (other-prec precs)
            (if (eq prec other-prec)
                (setq op1 '> op2 '<)
              (dolist (other-op (cdr other-prec))
                (smie-set-prec2tab prec2-table op other-op op2)
                (smie-set-prec2tab prec2-table other-op op op1)))))))
    prec2-table))

(defun smie-merge-prec2s (tables)
  (if (null (cdr tables))
      (car tables)
    (let ((prec2 (make-hash-table :test 'equal)))
      (dolist (table tables)
        (maphash (lambda (k v)
                   (smie-set-prec2tab prec2 (car k) (cdr k) v))
                 table))
      prec2)))

(defun smie-bnf-precedence-table (bnf &rest precs)
  (let ((nts (mapcar 'car bnf))         ;Non-terminals
        (first-ops-table ())
        (last-ops-table ())
        (first-nts-table ())
        (last-nts-table ())
        (prec2 (make-hash-table :test 'equal))
        (override (smie-merge-prec2s
                   (mapcar 'smie-precs-precedence-table precs)))
        again)
    (dolist (rules bnf)
      (let ((nt (car rules))
            (last-ops ())
            (first-ops ())
            (last-nts ())
            (first-nts ()))
        (dolist (rhs (cdr rules))
          (assert (consp rhs))
          (if (not (member (car rhs) nts))
              (pushnew (car rhs) first-ops)
            (pushnew (car rhs) first-nts)
            (when (consp (cdr rhs))
              ;; If the first is not an OP we add the second (which
              ;; should be an OP if BNF is an "operator grammar").
              ;; Strictly speaking, this should only be done if the
              ;; first is a non-terminal which can expand to a phrase
              ;; without any OP in it, but checking doesn't seem worth
              ;; the trouble, and it lets the writer of the BNF
              ;; be a bit more sloppy by skipping uninteresting base
              ;; cases which are terminals but not OPs.
              (assert (not (member (cadr rhs) nts)))
              (pushnew (cadr rhs) first-ops)))
          (let ((shr (reverse rhs)))
            (if (not (member (car shr) nts))
                (pushnew (car shr) last-ops)
              (pushnew (car shr) last-nts)
            (when (consp (cdr shr))
              (assert (not (member (cadr shr) nts)))
              (pushnew (cadr shr) last-ops)))))
        (push (cons nt first-ops) first-ops-table)
        (push (cons nt last-ops) last-ops-table)
        (push (cons nt first-nts) first-nts-table)
        (push (cons nt last-nts) last-nts-table)))
    ;; Compute all first-ops by propagating the initial ones we have
    ;; now, according to first-nts.
    (setq again t)
    (while (prog1 again (setq again nil))
      (dolist (first-nts first-nts-table)
        (let* ((nt (pop first-nts))
               (first-ops (assoc nt first-ops-table)))
          (dolist (first-nt first-nts)
            (dolist (op (cdr (assoc first-nt first-ops-table)))
              (unless (member op first-ops)
                (setq again t)
                (push op (cdr first-ops))))))))
    ;; Same thing for last-ops.
    (setq again t)
    (while (prog1 again (setq again nil))
      (dolist (last-nts last-nts-table)
        (let* ((nt (pop last-nts))
               (last-ops (assoc nt last-ops-table)))
          (dolist (last-nt last-nts)
            (dolist (op (cdr (assoc last-nt last-ops-table)))
              (unless (member op last-ops)
                (setq again t)
                (push op (cdr last-ops))))))))
    ;; Now generate the 2D precedence table.
    (dolist (rules bnf)
      (dolist (rhs (cdr rules))
        (while (cdr rhs)
          (cond
           ((member (car rhs) nts)
            (dolist (last (cdr (assoc (car rhs) last-ops-table)))
              (smie-set-prec2tab prec2 last (cadr rhs) '> override)))
           ((member (cadr rhs) nts)
            (dolist (first (cdr (assoc (cadr rhs) first-ops-table)))
              (smie-set-prec2tab prec2 (car rhs) first '< override))
            (if (and (cddr rhs) (not (member (car (cddr rhs)) nts)))
                (smie-set-prec2tab prec2 (car rhs) (car (cddr rhs))
                                   '= override)))
           (t (smie-set-prec2tab prec2 (car rhs) (cadr rhs) '= override)))
          (setq rhs (cdr rhs)))))
    prec2))

(defun smie-prec2-levels (prec2)
  "Take a 2D precedence table and turn it into an alist of precedence levels.
PREC2 is a table as returned by `smie-precs-precedence-table' or
`smie-bnf-precedence-table'."
  ;; For each operator, we create two "variables" (corresponding to
  ;; the left and right precedence level), which are represented by
  ;; cons cells.  Those are the vary cons cells that appear in the
  ;; final `table'.  The value of each "variable" is kept in the `car'.
  (let ((table ())
        (csts ())
        (eqs ())
        tmp x y)
    ;; From `prec2' we construct a list of constraints between
    ;; variables (aka "precedence levels").  These can be either
    ;; equality constraints (in `eqs') or `<' constraints (in `csts').
    (maphash (lambda (k v)
               (if (setq tmp (assoc (car k) table))
                   (setq x (cddr tmp))
                 (setq x (cons nil nil))
                 (push (cons (car k) (cons nil x)) table))
               (if (setq tmp (assoc (cdr k) table))
                   (setq y (cdr tmp))
                 (setq y (cons nil (cons nil nil)))
                 (push (cons (cdr k) y) table))
               (ecase v
                 (= (push (cons x y) eqs))
                 (< (push (cons x y) csts))
                 (> (push (cons y x) csts))))
             prec2)
    ;; First process the equality constraints.
    (let ((eqs eqs))
      (while eqs
        (let ((from (caar eqs))
              (to (cdar eqs)))
          (setq eqs (cdr eqs))
          (if (eq to from)
              (debug)                   ;Can it happen?
            (dolist (other-eq eqs)
              (if (eq from (cdr other-eq)) (setcdr other-eq to))
              (when (eq from (car other-eq))
                ;; This can happen because of `assoc' settings in precs
                ;; or because of a rhs like ("op" foo "op").
                (setcar other-eq to)))
            (dolist (cst csts)
              (if (eq from (cdr cst)) (setcdr cst to))
              (if (eq from (car cst)) (setcar cst to)))))))
    ;; Then eliminate trivial constraints iteratively.
    (let ((i 0))
      (while csts
        (let ((rhvs (mapcar 'cdr csts))
              (progress nil))
          (dolist (cst csts)
            (unless (memq (car cst) rhvs)
              (setq progress t)
              (setcar (car cst) i)
              (setq csts (delq cst csts))))
          (unless progress
            (error "Can't resolve the precedence table to precedence levels")))
        (incf i))
      ;; Propagate equalities back to their source.
      (dolist (eq (nreverse eqs))
        (assert (null (caar eq)))
        (setcar (car eq) (cadr eq)))
      ;; Finally, fill in the remaining vars (which only appeared on the
      ;; right side of the < constraints).
      ;; Tho leaving them at nil is not a bad choice, since it makes
      ;; it clear that these don't bind at all.
      ;; (dolist (x table)
      ;;   (unless (nth 1 x) (setf (nth 1 x) i))
      ;;   (unless (nth 2 x) (setf (nth 2 x) i)))
      )
    table))

;;; Parsing using a precedence level table.

(defvar smie-op-levels 'unset
  "List of token parsing info.
Each element is of the form (TOKEN LEFT-LEVEL RIGHT-LEVEL).
Parsing is done using an operator precedence parser.")

(defun smie-backward-token ()
  ;; FIXME: This may be an OK default but probably needs a hook.
  (buffer-substring (point)
                    (progn (if (zerop (skip-syntax-backward "."))
                               (skip-syntax-backward "w_'"))
                           (point))))

(defun smie-forward-token ()
  ;; FIXME: This may be an OK default but probably needs a hook.
  (buffer-substring (point)
                    (progn (if (zerop (skip-syntax-forward "."))
                               (skip-syntax-forward "w_'"))
                           (point))))

(defun smie-backward-sexp (&optional halfsexp)
  "Skip over one sexp.
HALFSEXP if non-nil, means skip over a partial sexp if needed.  I.e. if the
first token we see is an operator, skip over its left-hand-side argument.
Possible return values:
  (LEFT-LEVEL POS TOKEN): we couldn't skip TOKEN because its right-level
    is too high.  LEFT-LEVEL is the left-level of TOKEN,
    POS is its start position in the buffer.
  (t POS TOKEN): same thing but for an open-paren or the beginning of buffer.
  (nil POS TOKEN): we skipped over a paren-like pair.
  nil: we skipped over an identifier, matched parentheses, ..."
  (if (bobp) (list t (point))
    (catch 'return
      (let ((levels ()))
        (while
            (let* ((pos (point))
                   (token (progn (forward-comment (- (point-max)))
                                 (smie-backward-token)))
                   (toklevels (cdr (assoc token smie-op-levels))))

              (cond
               ((null toklevels)
                (if (equal token "")
                    (condition-case err
                        (progn (goto-char pos) (backward-sexp 1) nil)
                      (scan-error (throw 'return (list t (caddr err)))))))
               ((null (nth 1 toklevels))
                ;; A token like a paren-close.
                (assert (nth 0 toklevels)) ;Otherwise, why mention it?
                (push (nth 0 toklevels) levels))
               (t
                (while (and levels (< (nth 1 toklevels) (car levels)))
                  (setq levels (cdr levels)))
                (cond
                 ((null levels)
                  (if (and halfsexp (nth 0 toklevels))
                      (push (nth 0 toklevels) levels)
                    (throw 'return
                           (prog1 (list (or (car toklevels) t) (point) token)
                             (goto-char pos)))))
                 (t
                  (while (and levels (= (nth 1 toklevels) (car levels)))
                    (setq levels (cdr levels)))
                  (cond
                   ((null levels)
                    (cond
                     ((null (nth 0 toklevels))
                      (throw 'return (list nil (point) token)))
                     ((eq (nth 0 toklevels) (nth 1 toklevels))
                      (throw 'return
                             (prog1 (list (or (car toklevels) t) (point) token)
                               (goto-char pos))))
                     (t (debug))))      ;Not sure yet what to do here.
                   (t
                    (if (nth 0 toklevels)
                        (push (nth 0 toklevels) levels))))))))
              levels)
          (setq halfsexp nil))))))

;; Mirror image, not used for indentation.
(defun smie-forward-sexp (&optional halfsexp)
  "Skip over one sexp.
HALFSEXP if non-nil, means skip over a partial sexp if needed.  I.e. if the
first token we see is an operator, skip over its left-hand-side argument.
Possible return values:
  (RIGHT-LEVEL POS TOKEN): we couldn't skip TOKEN because its left-level
    is too high.  RIGHT-LEVEL is the right-level of TOKEN,
    POS is its end position in the buffer.
  (t POS TOKEN): same thing but for an open-paren or the beginning of buffer.
  (nil POS TOKEN): we skipped over a paren-like pair.
  nil: we skipped over an identifier, matched parentheses, ..."
  (if (eobp) (list t (point))
    (catch 'return
      (let ((levels ()))
        (while
            (let* ((pos (point))
                   (token (progn (forward-comment (point-max))
                                 (smie-forward-token)))
                   (toklevels (cdr (assoc token smie-op-levels))))

              (cond
               ((null toklevels)
                (if (equal token "")
                    (condition-case err
                        (progn (goto-char pos) (forward-sexp 1) nil)
                      (scan-error (throw 'return (list t (caddr err)))))))
               ((null (nth 0 toklevels))
                ;; A token like a paren-close.
                (assert (nth 1 toklevels)) ;Otherwise, why mention it?
                (push (nth 1 toklevels) levels))
               (t
                (while (and levels (< (nth 0 toklevels) (car levels)))
                  (setq levels (cdr levels)))
                (cond
                 ((null levels)
                  (if (and halfsexp (nth 1 toklevels))
                      (push (nth 1 toklevels) levels)
                    (throw 'return
                           (prog1 (list (or (nth 1 toklevels) t) (point) token)
                             (goto-char pos)))))
                 (t
                  (while (and levels (= (nth 0 toklevels) (car levels)))
                    (setq levels (cdr levels)))
                  (cond
                   ((null levels)
                    (cond
                     ((null (nth 1 toklevels))
                      (throw 'return (list nil (point) token)))
                     ((eq (nth 1 toklevels) (nth 0 toklevels))
                      (throw 'return
                             (prog1 (list (or (nth 1 toklevels) t) (point) token)
                               (goto-char pos))))
                     (t (debug))))      ;Not sure yet what to do here.
                   (t
                    (if (nth 1 toklevels)
                        (push (nth 1 toklevels) levels))))))))
              levels)
          (setq halfsexp nil))))))

(defun smie-backward-sexp-command (&optional n)
  "Move backward through N logical elements."
  (interactive "p")
  (if (< n 0)
      (smie-forward-sexp-command (- n))
    (let ((forward-sexp-function nil))
      (while (> n 0)
        (decf n)
        (let ((pos (point))
              (res (smie-backward-sexp 'halfsexp)))
          (if (and (car res) (= pos (point)) (not (bolp)))
              (signal 'scan-error
                      (list "Containing expression ends prematurely"
                            (cadr res) (cadr res)))
            nil))))))

(defun smie-forward-sexp-command (&optional n)
  "Move forward through N logical elements."
  (interactive "p")
  (if (< n 0)
      (smie-backward-sexp-command (- n))
    (let ((forward-sexp-function nil))
      (while (> n 0)
        (decf n)
        (let ((pos (point))
              (res (smie-forward-sexp 'halfsexp)))
          (if (and (car res) (= pos (point)) (not (bolp)))
              (signal 'scan-error
                      (list "Containing expression ends prematurely"
                            (cadr res) (cadr res)))
            nil))))))

;;; The indentation engine.

(defcustom smie-indent-basic 4
  "Basic amount of indentation."
  :type 'integer)

(defvar smie-indent-rules 'unset
  "Rules of the following form.
\(TOK OFFSET)		how to indent right after TOK.
\(TOK O1 O2)		how to indent right after TOK:
			  O1 is the default;
			  O2 is used if TOK is \"hanging\".
\((T1 . T2) . OFFSET)	how to indent token T2 w.r.t T1.
\((t . TOK) . OFFSET)	how to indent TOK with respect to its parent.
\(list-intro . TOKENS)	declare TOKENS as being followed by what may look like
			  a funcall but is just a sequence of expressions.
\(t . OFFSET)		basic indentation step.
\(args . OFFSET)		indentation of arguments.
A nil offset defaults to `smie-indent-basic'.")

(defun smie-indent-hanging-p ()
  ;; A Hanging keyword is one that's at the end of a line except it's not at
  ;; the beginning of a line.
  (and (save-excursion (smie-forward-token)
                       (skip-chars-forward " \t") (eolp))
       (save-excursion (skip-chars-backward " \t") (not (bolp)))))

(defun smie-bolp ()
  (save-excursion (skip-chars-backward " \t") (bolp)))

(defun smie-indent-offset (elem)
  (or (cdr (assq elem smie-indent-rules))
      (cdr (assq t smie-indent-rules))
      smie-indent-basic))

(defun smie-indent-calculate (&optional virtual)
  "Compute the indentation to use for point.
If VIRTUAL is non-nil, it means we're not trying to indent point but just
need to compute the column at which point should be indented
in order to figure out the indentation of some other (further down) point.
VIRTUAL can take two different non-nil values:
- :bolp: means that the current indentation of point can be trusted
  to be good only if it follows a line break.
- :hanging: means that the current indentation of point can be
  trusted to be good except if the following token is hanging."
  ;; FIXME: This has accumulated a lot of rules, some of which aren't
  ;; clearly orthogonal any more, so we should probably try and
  ;; restructure it somewhat.
  (or
   ;; Trust pre-existing indentation on other lines.
   (and virtual
        (if (eq virtual :hanging) (not (smie-indent-hanging-p)) (smie-bolp))
        (current-column))
   ;; Align close paren with opening paren.
   (save-excursion
     ;; (forward-comment (point-max))
     (when (looking-at "\\s)")
       (while (not (zerop (skip-syntax-forward ")")))
         (skip-chars-forward " \t"))
       (condition-case nil
           (progn
             (backward-sexp 1)
             (smie-indent-calculate :hanging))
         (scan-error nil))))
   ;; Align closing token with the corresponding opening one.
   ;; (e.g. "of" with "case", or "in" with "let").
   (save-excursion
     (let* ((pos (point))
            (token (smie-forward-token))
            (toklevels (cdr (assoc token smie-op-levels))))
       (when (car toklevels)
         (let ((res (smie-backward-sexp 'halfsexp)) tmp)
           ;; If we didn't move at all, that means we didn't really skip
           ;; what we wanted.
           (when (< (point) pos)
             (cond
              ((eq (car res) (car toklevels))
               ;; We bumped into a same-level operator. align with it.
               (goto-char (cadr res))
               ;; Don't use (smie-indent-calculate :hanging) here, because we
               ;; want to jump back over a sequence of same-level ops such as
               ;;    a -> b -> c
               ;;    -> d
               ;; So as to align with the earliest appropriate place.
               (smie-indent-calculate :bolp))
              ((equal token (save-excursion
                              (forward-comment (- (point-max)))
                              (smie-backward-token)))
               ;; in cases such as "fn x => fn y => fn z =>",
               ;; jump back to the very first fn.
               ;; FIXME: should we only do that for special tokens like "=>"?
               (smie-indent-calculate :bolp))
              ((setq tmp (assoc (cons (caddr res) token)
                                smie-indent-rules))
               (goto-char (cadr res))
               (+ (cdr tmp) (smie-indent-calculate :hanging)))
              (t
               (+ (or (cdr (assoc (cons t token) smie-indent-rules)) 0)
                  (current-column)))))))))
   ;; Indentation of a comment.
   (and (looking-at comment-start-skip)
        (save-excursion
          (forward-comment (point-max))
          (skip-chars-forward " \t\r\n")
          (smie-indent-calculate nil)))
   ;; Indentation inside a comment.
   (and (looking-at "\\*") (nth 4 (syntax-ppss))
        (let ((ppss (syntax-ppss)))
          (save-excursion
            (forward-line -1)
            (if (<= (point) (nth 8 ppss))
                (progn (goto-char (1+ (nth 8 ppss))) (current-column))
              (skip-chars-forward " \t")
              (if (looking-at "\\*")
                  (current-column))))))
   ;; Indentation right after a special keyword.
   (save-excursion
     (let* ((tok (progn (forward-comment (- (point-max)))
                        (smie-backward-token)))
            (tokinfo (assoc tok smie-indent-rules))
            (toklevel (assoc tok smie-op-levels)))
       (when (or tokinfo (and toklevel (null (cadr toklevel))))
         (if (or (smie-indent-hanging-p)
                 ;; If calculating the virtual indentation point, prefer
                 ;; looking up the virtual indentation of the alignment
                 ;; point as well.  This is used for indentation after
                 ;; "fn x => fn y =>".
                 virtual)
             (+ (smie-indent-calculate :bolp)
                (or (caddr tokinfo) (cadr tokinfo) (smie-indent-offset t)))
           (+ (current-column)
              (or (cadr tokinfo) (smie-indent-offset t)))))))
   ;; Main loop (FIXME: whatever that means!?).
   (save-excursion
     (let ((positions nil)
           (begline nil)
           arg)
       (while (and (null (car (smie-backward-sexp)))
                   (push (point) positions)
                   (not (setq begline (smie-bolp)))))
       (save-excursion
         ;; Figure out if the atom we just skipped is an argument rather
         ;; than a function.
         (setq arg (or (null (car (smie-backward-sexp)))
                       (member (progn (forward-comment (- (point-max)))
                                      (smie-backward-token))
                               (cdr (assoc 'list-intro smie-indent-rules))))))
       (cond
        ((and arg positions)
         (goto-char (car positions))
         (current-column))
        ((and (null begline) (cdr positions))
         ;; We skipped some args plus the function and bumped into something.
         ;; Align with the first arg.
         (goto-char (cadr positions))
         (current-column))
        ((and (null begline) positions)
         ;; We're the first arg.
         ;; FIXME: it might not be a funcall, in which case we might be the
         ;; second element.
         (goto-char (car positions))
         (+ (smie-indent-offset 'args)
            ;; We used to use (smie-indent-calculate :bolp), but that
            ;; doesn't seem right since it might then indent args less than
            ;; the function itself.
            (current-column)))
        ((and (null arg) (null positions))
         ;; We're the function itself.  Not sure what to do here yet.
         (if virtual (current-column)
           (save-excursion
             (let* ((pos (point))
                    (tok (progn (forward-comment (- (point-max)))
                                (smie-backward-token)))
                    (toklevels (cdr (assoc tok smie-op-levels))))
               (cond
                ((numberp (car toklevels))
                 ;; We're right after an infix token.  Let's skip over the
                 ;; lefthand side.
                 (goto-char pos)
                 (let (res)
                   (while (progn (setq res (smie-backward-sexp 'halfsexp))
                                 (and (not (smie-bolp))
                                      (equal (car res) (car toklevels)))))
                   ;; We should be right after a token of equal or
                   ;; higher precedence.
                   (cond
                    ((and (consp res) (memq (car res) '(t nil)))
                     ;; The token of higher-precedence is like an open-paren.
                     ;; Sample case for t: foo { bar, \n[TAB] baz }.
                     ;; Sample case for nil: match ... with \n[TAB] | toto ...
                     ;; (goto-char (cadr res))
                     (smie-indent-calculate :hanging))
                    ((and (consp res) (<= (car res) (car toklevels)))
                     ;; We stopped at a token of equal or higher precedence
                     ;; because we found a place with which to align.
                     (current-column))
                    )))
                ;; For other cases.... hmm... we'll see when we get there.
                )))))
        ((null positions)
         (smie-backward-token)
         (+ (smie-indent-offset 'args) (smie-indent-calculate :bolp)))
        ((car (smie-backward-sexp))
         ;; No arg stands on its own line, but the function does:
         (if (cdr positions)
             (progn
               (goto-char (cadr positions))
               (current-column))
           (goto-char (car positions))
           (+ (current-column) (smie-indent-offset 'args))))
        (t
         ;; We've skipped to a previous arg on its own line: align.
         (goto-char (car positions))
         (current-column)))))))

(defun smie-indent-line ()
  "Indent current line using the SMIE indentation engine."
  (interactive)
  (let* ((savep (point))
	 (indent (condition-case nil
		     (save-excursion
                       (forward-line 0)
                       (skip-chars-forward " \t")
                       (if (>= (point) savep) (setq savep nil))
                       (or (smie-indent-calculate) 0))
                   (error 0))))
    (if (not (numberp indent))
        ;; If something funny is used (e.g. `noindent'), return it.
        indent
      (if (< indent 0) (setq indent 0)) ;Just in case.
      (if savep
          (save-excursion (indent-line-to indent))
        (indent-line-to indent)))))

;;;###autoload
(defun smie-setup (op-levels indent-rules)
  (set (make-local-variable 'smie-indent-rules) indent-rules)
  (set (make-local-variable 'smie-op-levels) op-levels)
  (set (make-local-variable 'indent-line-function) 'smie-indent-line))


(provide 'smie)
;;; smie.el ends here