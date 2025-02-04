;;;
;;; grep.lisp - “Global” Regular Expression Print
;;;

(defpackage :grep
  (:documentation "Regular expression search in streams.")
  (:use :cl :cl-ppcre :opsys :dlib :grout :fatchar :stretchy
	:char-util :collections :table :theme :style :view-generic)
  (:export
   #:grep
   #:grep-files
   #:!grep
   #:grep-result
   #:grep-result-file #:grep-result-line-number #:grep-result-line
   #:make-grep-result
   ))
(in-package :grep)

(declaim #.`(optimize ,.(getf los-config::*config* :optimization-settings)))
;; (declaim (optimize (speed 0) (safety 3) (debug 3)
;; 		   (space 0) (compilation-speed 0)))
;; (declaim (optimize (speed 3) (safety 0) (debug 0)
;; 		   (space 2) (compilation-speed 0)))

;;;(define-constant +color-loop+
(defparameter +color-loop+
    '#1=(:red :yellow :blue :green :magenta :cyan :white . #1#))

(defparameter *grep-error-output* nil)

;; If you want fast, don't use color.

(defvar *fat-string* nil)

(defun set-region (fat start end color attr)
  (declare (type (vector fatchar *) fat)
	   (type fixnum start end)
	   (type keyword color attr))
  (loop :for i fixnum :from start :below end :do
     (setf (fatchar-fg (aref fat i)) color)
     (pushnew attr (fatchar-attrs (aref fat i)))))

;; It might be nice if we could highlight the unfiltered match in the unfiltered
;; line, but I have no idea how to do it.
(defun print-match (use-color pattern scanner line
		    filtered-pattern filtered-line)
  (if use-color
      (let (fat-line)
	(when (not *fat-string*)
	  (setf *fat-string*
		(make-fat-string
		 :string (make-array (length line)
				     :adjustable t :fill-pointer 0
				     :element-type 'fatchar
				     :initial-element (make-fatchar)))))
	(setf fat-line (fat-string-string *fat-string*))
	(setf (fill-pointer fat-line) 0)
	(loop
	   :for c :across line :and i = 0 :then (1+ i)
	   :do (stretchy-append fat-line (make-fatchar :c c)))
	(if scanner
	    ;; regexp
	    (do-scans (s e rs re scanner (or filtered-line line))
	      (set-region fat-line s e (first +color-loop+) :underline)
	      (loop
		 :for start :across rs
		 :for end :across re
		 :for color = (cdr +color-loop+) :then (cdr color) ;)
		 :do
		 (when (and start end)
		   (set-region fat-line start end (car color) :underline))))
	    ;; fixed string
	    (loop :with pos
	       :and start = 0
	       :and pattern-len = (length pattern)
	       :and color = +color-loop+
	       :while (setf pos (search filtered-pattern (or filtered-line line)
					:start2 start))
	       :do
	       (set-region fat-line pos (+ pos pattern-len)
			   (car color) :underline)
	       (setf start (+ pos pattern-len)
		     #| color (cdr color) |#)))
	(grout-princ *fat-string*)
	(grout-princ #\newline))
      ;; No color
      (progn
	(grout-format "~a~%" line))))

(defun print-prefix (use-color prefix)
  (declare (ignore use-color))
  (grout-color :magenta :default (princ-to-string prefix))
  (grout-color :cyan :default ":"))

(defun normalize-filter (string)
  "Return STRING in Unicode normalized form NFD."
  (char-util:normalize-string string))

(defun remove-combining-filter (string)
  "Return STRING in Unicode normalized form NFD, with combining characters
removeed."
  (remove-if #'char-util:combining-char-p
	     (char-util:normalize-string string)))

(defun make-filter (unicode-normalize unicode-remove-combining filter)
  (cond
    (filter
     (cond
       (unicode-remove-combining
	(lambda (s) (remove-combining-filter (funcall filter s))))
       (unicode-normalize
	(lambda (s) (normalize-filter (funcall filter s))))
       (t filter)))
    (t
     (or (and unicode-remove-combining #'remove-combining-filter)
	 (and unicode-normalize #'normalize-filter)))))

(defstruct grep-result
  file
  line-number
  line)

(defparameter *grep-theme*
  (let ((tt (make-theme 'grep-default
			:title "Grep default theme."
			:description "Theme for the grep command.")))
    (set-theme-items
     tt
     `((:program :grep :filename :style)    (:magenta)
       (:program :grep :line-number :style) (:white)
       (:program :grep :line :style)        (:green)
       (:program :grep :separator :style)   (:cyan)))
    tt))

(defmethod print-object ((object grep-result) stream)
  "Print a grep-result to STREAM."
  (with-slots (file line-number line) object
    (let* ((tt (list *theme* *grep-theme*))
	   (colon (styled-span
		   (theme-value tt '(:program :grep :separator :style))
		   ":")))
      (cond
	((or *print-readably* *print-escape*)
	 (call-next-method))
	((typep stream '(or terminal:terminal terminal:terminal-stream
			 fatchar-io:fat-string-output-stream))
	 (print-object
	  (span-to-fat-string
	   `(,(styled-span (theme-value tt '(:program :grep :filename :style))
			   file)
	     ,colon
	     ,(styled-span (theme-value tt '(:program :grep :line-number :style))
			   line-number)
	     ,colon
	     ,(styled-span (theme-value tt '(:program :grep :line :style))
			   line))
	     :unknown-func #'princ-to-string)
	   stream))
	(t
	 (format stream "~a:~a:~a" file line-number line))))))

(defmethod view ((thing grep-result))
  (when (find-package :pager)
    (symbol-call :pager :pager (vector (grep-result-file thing)
				       (grep-result-line-number thing)))))

(eval-when (:compile-toplevel)
  (defmacro with-grep-source ((source filename) &body body)
    "Evalute body where a GET-RESULT function sets it's GREP-RESULT argument
to subsequent lines from SOURCE and returns the LINE or NIL at the end. SOURCE
can be a pathname designator, a stream, or a list of lines, or a list of
GREP-RESULTS."
    (with-unique-names (src stream thunk nl-func l #|result|# line-count)
      `(let ((,src ,source) ,nl-func #|,result|# (,line-count 0))
	 (declare (type fixnum ,line-count))
	 (labels ((get-result (r) (funcall ,nl-func r))
		  (,thunk () ,@body))
	   (etypecase ,src
	     ((or stream string pathname)
	      (with-open-file-or-stream (,stream ,src)
		(setf ,nl-func
		      (lambda (r)
			(setf
			 (grep-result-file r) ,filename
			 (grep-result-line-number r) (incf ,line-count)
			 (grep-result-line r) (read-line ,stream nil nil))))
		(,thunk)))
	     (list
	      (let ((,l ,src))
		(if (and (plusp (length ,src)) (typep (first ,src) 'grep-result))
		    (progn
		      (setf ,nl-func
			    (lambda (r)
			      (let ((nr (pop ,l)))
				(when nr
				  (setf
				   (grep-result-file r)
				   (grep-result-file nr)
				   (grep-result-line-number r)
				   (grep-result-line-number nr)
				   (grep-result-line r)
				   (grep-result-line nr))))))
		      (,thunk))
		    (progn
		      (setf ,nl-func
			    (lambda (r)
			      (let ((nr (princ-to-string (pop ,l))))
				(when nr
				  (setf
				   (grep-result-file r) ,filename
				   (grep-result-line-number r)
				   (incf ,line-count)
				   (grep-result-line r) nr)))))
		      (,thunk)))))))))))

(defun grep (pattern file-or-stream
	     &key
	       (output-stream *standard-output*)
	       count extended fixed file ignore-case quiet invert
	       line-number files-with-match files-without-match
	       filename use-color collect
	       scanner
	       unicode-normalize unicode-remove-combining filter
	       &allow-other-keys)
  "Print occurances of the regular expression PATTERN in STREAM.
Aruguments are:
  OUTPUT-STREAM       - Where to print the output, Defaults to *STANDARD-OUTPUT*.
  COUNT               - True to show a count of matches.
  EXTENDED            - True to use extended regular expressions.
  FIXED               - True to search for fixed strings only, not regexps.
  IGNORE-CASE         - True to ignore character case when matching.
  QUIET               - True to not print matches.
  INVERT              - True to only print lines that don't match.
  LINE-NUMER          - True to precede matching lines by a line number.
  FILES-WITH-MATCH    - True to print only the file name for matches.
  FILES-WITHOUT-MATCH - True to print only the file name for matches.
  FILENAME            - Name of the file to print before the matching line.
  USE-COLOR           - True to highlight substrings in color.
  COLLECT             - True to return the results.
  SCANNER	      - A PPCRE scanner as returned by CREATE-SCANNER.
The first value is:
  if COLLECT is true, a list of GREP-RESULT,
  if COUNT is true the number of matches,
  if neither COLLECT or COUNT is true, a boolean indicating if there were any
  matches.
Second value is the scanner that was used.
"  
  (declare (ignore file) ;; @@@
	   #| (type stream output-stream) |#)
  (when (or files-with-match files-without-match)
    ;; @@@ For efficiency we should probably arrange for an early exit if
    ;; either of these is true, providied we aren't otherwise collecting the
    ;; results.
    (setf quiet t))

  ;; (macrolet ((add-result (result slot value)
  ;; 	       ;; Just be aware we're not proctecting againt multiple eval.
  ;; 	       (let ((slot-name (symbolify (s+ "grep-result-" slot)))
  ;; 		     (slot-arg (keywordify slot)))
  ;; 		 `(if ,result
  ;; 		      (setf (,slot-name ,result) ,value)
  ;; 		      (setf ,result (make-grep-result ,slot-arg ,value))))))
  (let* ((*fat-string* nil)
	 (match-count 0)
	 ;; (line-count 0)
	 ;; result
	 (line (make-grep-result))
	 match
	 matches
	 filtered-line
	 (composed-filter (make-filter
			   unicode-normalize unicode-remove-combining filter))
	 (filtered-pattern (or (and composed-filter
				    (funcall composed-filter pattern))
			       pattern))
	 (check-it
	  (if fixed
	      (if composed-filter
		  (lambda () (search filtered-pattern
				     (setf filtered-line
					   (funcall composed-filter
						    (grep-result-line line)))))
		  (lambda () (search filtered-pattern (grep-result-line line))))
	      (if composed-filter
		  (lambda () (scan scanner
				   (setf filtered-line
					 (funcall composed-filter
						  (grep-result-line line)))))
		  (lambda () (scan scanner (grep-result-line line)))))))
    (declare (type fixnum #|line-count|# match-count))
    (setf scanner (and (not fixed)
		       (or scanner
			   (create-scanner
			    filtered-pattern
			    :extended-mode extended
			    :case-insensitive-mode ignore-case))))
    (with-grout (*grout* output-stream)
      ;;(with-open-file-or-stream (stream file-or-stream)
      (with-grep-source (file-or-stream filename)
	(setf matches
	      ;;(loop :while (setf line (resilient-read-line stream nil nil))
	      ;; (loop :while (setf line (read-line stream nil nil))
	      (loop :while (get-result line)
		 :do
		 (setf match (funcall check-it))
		 (cond
		   ((or (and match (not invert))
			(and (not match) invert))
		    (progn
		      (incf match-count)
		      (when filename
			(when (not quiet)
			  (print-prefix use-color (grep-result-file line)))
			;; (when collect
			;;   (add-result match file (grep-result-file match))))
			)
		      (when line-number
			(when (not quiet)
			  ;; (print-prefix use-color (1+ line-count)))
			  (print-prefix use-color
					(grep-result-line-number line)))
			;; (when collect
			;;   ;; (push line-count match)
			;;   ;; (add-result match line-number line-count)
			;;   (add-result match line-number
			;; 		(grep-result-line-number line))
			;;   )
			)
		      (when (not quiet)
			(print-match use-color pattern scanner
				     (or filtered-line (grep-result-line line))
				     filtered-pattern filtered-line))
		      ;; (when collect
		      ;;   ;; (push line match)
		      ;;   (add-result match line line)
		      ;;   )
		      ))
		   ((or (and (not match) (not invert))
			(and match invert))
		    #| don't print match |#))
		 ;; (incf line-count)
		 :when (and collect match)
		 :collect (if (or filename line-number)
			      (make-grep-result
			       :file (grep-result-file line)
			       :line-number (grep-result-line-number line)
			       :line (grep-result-line line))
			      (grep-result-line line))))))
    (values
     (if collect
	 matches
	 (if count match-count (/= 0 match-count)))
     scanner)))

(defun native-pathname (str)
  #-sbcl str
  #+sbcl (sb-ext:native-pathname str))

(defun grep-files (pattern &rest keywords
		   &key files recursive input-lines
		     (output-stream *standard-output*)
		     count extended fixed ignore-case quiet invert
		     line-number files-with-match files-without-match
		     use-color collect no-filename signal-errors print-errors
		     unicode-normalize unicode-remove-combining filter)
  "Call GREP with PATTERN on FILES. Arguments are:
  FILES       - A list of files to search.
  RECURSIVE   - If FILES contain directory names, recursively search them.
  INPUT-LINES - A sequence of lines to use instead of *standard-input*.
 See the documentation for GREP for an explanation the other arguments."
  (declare (ignorable count extended ignore-case invert
		      recursive line-number use-color fixed
		      unicode-normalize unicode-remove-combining filter)) ;; @@@
  (let ((*grep-error-output* (if print-errors *error-output* nil))
	results scanner result)
    (labels ((call-grep (pattern stream &optional args)
	       "Call grep with the same arguments we got."
	       (if args
		   (apply #'grep pattern stream :scanner scanner args)
		   (grep pattern stream :scanner scanner)))
	     (grep-one-file (f)
	       (with-open-file-or-stream (stream
					  (if (streamp f)
					      f
					      (native-pathname f)))
		 (multiple-value-setq (result scanner)
		   (call-grep pattern stream
			      (if (not no-filename)
				  (append keywords `(:filename ,f))
				  keywords)))))
	     (grep-with-handling (f)
	       (if signal-errors
		   (grep-one-file f)
		   (handler-case
		       (grep-one-file f)
		     ((or stream-error file-error #+sbcl type-error) (c)
		       ;; (finish-output)
		       (grout-finish)
		       (let ((*print-pretty* nil))
			 (format *grep-error-output*
				 "~a: ~a ~a~%" f (type-of c) c))
		       (invoke-restart 'continue))))))
      ;;(with-term-if (use-color output-stream)
      (with-grout (*grout* output-stream)
	(cond
	  ((null files)
	   (setf results (call-grep pattern (or input-lines
						*standard-input*) keywords)))
	  (t
	   (when (not (consp files))
	     (setf files (list files)))
	   (loop
	      :for f :in files
	      :do
		(restart-case
		    (progn
		      (cond
			((streamp f)
			 (grep-with-handling f))
			((not (file-exists f))
			  (if signal-errors
			      (error "~a: No such file or directory~%" f)
			      (progn
				;; Note that if we don't do grout-finish here,
				;; and in the other places before printing
				;; errors, it can trigger some very annoying
				;; bugs where the error message is printed in
				;; the middle of the search output, and
				;; potentially output in the middle of an escape
				;; sequence that can fuck up the terminal,
				;; seemingly at random, since it's data
				;; dependant and a rare coincidence.
				(grout-finish)
				(format *grep-error-output*
					"~a: No such file or directory~%" f))))
			(t
			 (cond
			   ((eq :directory (file-info-type (get-file-info f)))
			    (cond
			      (recursive
			       (let ((kw (copy-list keywords))
				     (dir-list
				       (nos:read-directory :dir f
							   :omit-hidden t)))
				 (when dir-list
				   (setf (getf kw :files)
					 (mapcar (_ (nos:path-append f _))
						 dir-list))
				   (setf result
					 (apply #'grep-files pattern kw)))))
			      ((= (length files) 1)
			       ;; Don't bother complaining about directories if
			       ;; we have more than one file.
			       (if signal-errors
				   (error "~a: Is a directory~%" f)
				   (progn
				     (grout-finish)
				     (format *grep-error-output*
					     "~a: Is a directory~%" f))))))
			   (t
			    (grep-with-handling f)))))
		      (cond
			((and result files-with-match (not quiet))
			 (grout-format "~a~%" f))
			((and (not result) files-without-match (not quiet))
			 (grout-format "~a~%" f)))
		      (when collect
			(mapc (_ (push _ results)) result)))
		  (continue ()
		    :report "Skip this file.")
		  (skip-all ()
		    :report "Skip remaining files with errors."
		    (setf signal-errors nil))))
	   (setf results (nreverse results)))))
      ;;:when collect :collect result))
      (when (and collect files-with-match)
	(setf results
	      (remove-duplicates (mapcar #'first results) :test #'equal)))
      results)))

(defmethod make-result-table (table results)
  "Return a new copy of TABLE, but with only the rows from RESULTS, where
RESULTS is a list of (row-number column-number match)."
  (let* ((class (class-of table))
	 (result (allocate-instance class)))
    (loop :for slot :in (mapcar #'mop:slot-definition-name
				(mop:class-slots class))
       :when (slot-boundp table slot)
       :do (setf (slot-value result slot)
		 (slot-value table slot)))
    (setf (container-data result)
	  (omap (lambda (r)
		  (copy-seq (oelt table (car r))))
		results))
    result))

;; @@@ Maybe someday consider how to refactor overlap with (grep …)
(defun grep-table (pattern table #| &rest keywords |#
		   &key (output-stream *standard-output*)
		     count extended fixed ignore-case quiet invert
		     line-number use-color collect
		     unicode-normalize unicode-remove-combining filter)
  "Call GREP with PATTERN on TABLE. See the documentation for GREP for an
explanation the other arguments."
  (declare (ignorable count
		      ;; extended
		      ;; ignore-case
		      invert
		      line-number use-color
		      ;; fixed
		      ;; unicode-normalize unicode-remove-combining filter
		      ))
  (let* (match
	 scanner
	 (x 0) (y 0)
	 (match-count 0)
	 results
	 result-table
	 filtered-line ;; actually cell
	 (composed-filter (make-filter
			   unicode-normalize unicode-remove-combining filter))
	 (filtered-pattern (or (and composed-filter
				    (funcall composed-filter pattern))
			       pattern))
	 (check-it
	   (if fixed
	       (if composed-filter
		   (lambda (x)
		     (search filtered-pattern
			     (setf filtered-line
				   (funcall composed-filter x))))
		   (lambda (x)
		     (search filtered-pattern x)))
	       (if composed-filter
		   (lambda (x)
		     (scan scanner
			   (setf filtered-line
				 (funcall composed-filter x))))
		   (lambda (x)
		     (scan scanner x))))))
    (declare (type fixnum #|line-count|# match-count))
    (setf scanner (and (not fixed)
		       (or scanner
			   (create-scanner
			    filtered-pattern
			    :extended-mode extended
			    :case-insensitive-mode ignore-case))))
    (with-grout (*grout* output-stream)
      (omapn
       (lambda (row)
	 (omapn
	  (lambda (col)
	    (when (setf match
			(funcall check-it
				 (typecase col
				   (string col)
				   (t (princ-to-string col)))))
	      (incf match-count)
	      (push (list y x match) results))
	    (incf x))
	  row)
	 (incf y))
       table)
      (setf results (nreverse results)
	    result-table (make-result-table table results))
      (when (not quiet)
	(grout-print-table result-table))
      (if collect result-table results))))

#+lish
(lish:defcommand grep
  ((pattern string :help "Regular expression to search for.")
   (pattern-expression string :short-arg #\e
    :help "Regular expression to search for.")
   (files input-stream-or-filename
    :repeating t
    :help "Files to search in.")
   (files-with-match boolean
    :short-arg #\l
    :help "Print only the file name (list) once for matches.")
   (files-without-match boolean
    :short-arg #\L
    :help "Print only the file name (list) of files with no matches.")
   (ignore-case boolean
    :short-arg #\i
    :help "Ignore character case when matching.")
   (invert boolean
    :short-arg #\v
    :help "Only print lines that don't match.")
   (no-filename boolean
    :short-arg #\h
    :help "Never print filenames (headers) with output.")
   (line-number boolean
    :short-arg #\n
    :help "Print line numbers.")
   (quiet boolean
    :short-arg #\q
    :help "Don't produce output.")
   (fixed boolean
    :short-arg #\F
    :help "Search for a fixed strings, not regular expressions.")
   ;; (line-up boolean :short-arg #\l
   ;;  :help "Line up matches.")
   (use-color boolean
    :short-arg #\C :default t
    :help "Highlight substrings in color.")
   (recursive boolean :short-arg #\r
    :help "Recursively search directories.")
   (collect boolean
    :short-arg #\c
    :default '(lish:accepts :sequence)
    :use-supplied-flag t
    :help "Collect matches in a sequence.")
   (signal-errors boolean :short-arg #\E
    :help "Signal errors.")
   (print-errors boolean :short-arg #\P
    :help "Print errors *error-output*.")
   (positions boolean :short-arg #\p
    :help "Send positions to Lish output. Equivalent to -nqc, except
it's only quiet if the receiving command accepts sequences.")
   (input-as-files boolean :short-arg #\s
    :help "Treat *input* as files to search instead of text.")
   (unicode-normalize boolean :short-arg #\u :default t
    :help "Normalize unicode before comparison.")
   (unicode-remove-combining boolean :short-arg #\U
    :help "Normalize and remove unicode combining characters.")
   (filter function :short-arg #\f
    :help "Function to apply to strings before comparing."))
  :accepts (:stream :sequence)
  "Search for patterns in input."
  (let (result table)
    (cond
      ((and (lish:accepts :sequence) (not collect-supplied-p))
       (setf collect t)
       (when positions
	 (setf quiet t)))
      ((lish:accepts :grotty-stream)
       (setf use-color t))
      (t
       ;; (dbugf :accepts "grep output accepts ~s~%" lish::*accepts*)
       ))
    ;; (dbugf :accepts "no files given~%")
    ;; (dbugf :accepts "type-of *input* = ~s~%" (type-of lish:*input*))
    ;; (dbugf :accepts "*input* = ~s~%" lish:*input*)
    (when positions
      (setf line-number t collect t))
    (when (not (or pattern pattern-expression))
      (error "A pattern argument wasn't given."))
    (setf result
	  (cond
	    ((setf table (or (and lish:*input* (typep lish:*input* 'table)
				  lish:*input*)
			     (and files (typep files 'table)
				  files)))
	     ;; Default to collect when given a table.
	     (when (not collect-supplied-p)
	       (setf collect t))
	     (finish-output)
	     (grep-table (or pattern pattern-expression)
			 table
			 :fixed fixed
			 :ignore-case ignore-case
			 :invert invert
			 :line-number line-number
			 :quiet quiet
			 :use-color use-color
			 :collect collect
			 :unicode-normalize unicode-normalize
			 :unicode-remove-combining unicode-remove-combining
			 :filter filter))
	    (t
	     (grep-files (or pattern pattern-expression)
			 :input-lines (and (not input-as-files)
					   (not (streamp lish:*input*))
					   (typep lish:*input* 'sequence)
					   lish:*input*)
			 :files
			 (or files (and lish:*input*
					(typep lish:*input* 'sequence)
					(or input-as-files
					    ;; too dwim-ish??
					    (and (plusp (length lish:*input*))
						 (typep (elt lish:*input* 0)
							'pathname)))
					lish:*input*))
			 :files-with-match files-with-match
			 :files-without-match files-without-match
			 :no-filename no-filename
			 :fixed fixed
			 :ignore-case ignore-case
			 :invert invert
			 :line-number line-number
			 :quiet quiet
			 :use-color use-color
			 :recursive recursive
			 :collect collect
			 :signal-errors signal-errors
			 :print-errors print-errors
			 :unicode-normalize unicode-normalize
			 :unicode-remove-combining unicode-remove-combining
			 :filter filter))))
    (if collect
	(progn
	  (setf lish:*output* result))
	result)))

;; EOF
