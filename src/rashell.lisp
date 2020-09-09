;;;; rashell.lisp – Resilient replicant Shell Programming Library for Common Lisp

;;;; Rashell (https://github.com/michipili/cl-rashell)
;;;; This file is part of Rashell
;;;;
;;;; Copyright © 2017–2020 Michaël Le Barbier
;;;;
;;;; This file must be used under the terms of the MIT license.
;;;; This source file is licensed as described in the file LICENSE, which
;;;; you should have received as part of this distribution. The terms
;;;; are also available at
;;;; https://opensource.org/licenses/MIT

(in-package #:rashell)

;;;;
;;;; Signal Table
;;;;

(defparameter *signal-table*
  (append
   '((:hangup . 1)
     (:interrupt . 2)
     (:quit . 3)
     (:illegal-instruction . 4)
     (:breakpoint-trap . 5)
     (:abort . 6)
     (:emulation-trap . 7)
     (:arithmetic-exception . 8)
     (:kill . 9)
     (:bus-error . 10)
     (:segmentation-fault . 11)
     (:bad-system-call . 12)
     (:broken-pipe . 13)
     (:alarm-clock . 14)
     (:terminate . 15))
   #+os-macosx
   '((:stop . 17)
     (:terminal-stop . 18)
     (:continue . 19))
   )
  "The table mapping symbolic signal names to numeric signal names.")

;;;;
;;;; The COMMAND class
;;;;

(defclass command ()
  ((program
    :initarg :program
    :initform #p"/usr/bin/false"
    :documentation 
    "A path to the program to run.")
   (argv
    :initarg :argv
    :initform nil
    :documentation
    "A sequence to be used as the argument vector for the program.")
   (directory
    :initarg :directory
    :initform nil
    :documentation
    "The working directory of the program to run.
If not provided, the current working directory is used.")
   (environment
    :initarg :environment
    :initform nil
    :documentation
    "Environment variable bindings for the program to run.
The ENVIRONMENT must be a sequence whose terms are:
 - maybe the keywords :APPEND at the first position,
   meaning the environment definitions should be appended to
   the environment of the current process.
 - maybe the keyword :SUPERSEDE at the first position, meaning
   that the environment definitions describe the entire environment
   definitions available for the external process.
 - either a string of the form \"VARIABLE=VALUE\";
 - or a cons cell of the form (VARIABLE . VALUE).

When the ENVIRONMENT is NIL, then the environment of the calling process
is inherited.")
   (process
    :initform nil
    :documentation
    "The external process running the program.")
   (documentation
    :initarg :documentation
    :initform nil
    :documentation
    "The documentation of the command instance."))
  (:documentation
   "The COMMAND structure captures the parameters used to start an external program."))


;;;;
;;;; The DEFINE-COMMAND Macro
;;;;

(defun define-command/to-string (argument)
  "Convert ARGUMENT to a string."
  (typecase argument
    (string
     argument)
    (keyword
     (symbol-name argument))
    (pathname
     (namestring argument))
    (t
     (write-to-string argument))))

(defun define-command/prepare-argv (argument spec)
  "Prepare argument vector interpreation fragment for ARGUMENT interpreted according to SPEC."
  (let ((option (getf spec :option))
        (flag (getf spec :flag))
        (to-string (getf spec :to-string)))
    (cond
      (flag
       `(when ,argument (list ,flag)))
      ((and option to-string (getf spec :multiple))
       `(loop for single-argument in (ensure-list ,argument)
              collect ,option
              collect (funcall ,to-string single-argument)))
      ((and option (getf spec :multiple))
       `(loop for single-argument in (ensure-list ,argument)
              collect ,option
              collect single-argument))
      ((and option to-string (not (getf spec :multiple)))
       `(when ,argument
          (list ,option (funcall ,to-string ,argument))))
      ((and option (not (getf spec :multiple)))
       `(when ,argument
          (list ,option ,argument)))
      (t
       (error "~S: Cannot prepare argument vector according to SPEC." spec)))))


(defmacro define-command (name argv options spec)
  "Define a function NAME that can run a command according to SPEC.

The function NAME accepts arguments ARGV and optional arguments as specified by the OPTIONS
parameter, see below.  The SPEC parameter is a property list specifiying various aspects of how the
command is run.

The OPTIONS parameter is a list of option specifications. An option specification is a list
starting with a symbol, the OPTION-NAME, which is used to label the optional parameter of
the function NAME. The allowed forms for option specifications are:

  '(OPTION-NAME :flag FLAG-STRING)
    The parameter OPTION-NAME is interpreted as a generalised boolean.  When it is set, the
    FLAG-STRING is added to the command-lin of the external program being run.

  '(OPTION-NAME :option OPTION-STRING [:to-string CONVERT] [:multiple MULTIPLE-FLAG])
    The parameter OPTION-NAME is interpreted as an arbitrary value is a string, or is converted to a
    string either by applying the function passed as the :to-string property, 
    or by using `write-to-string' if none of the preceeding rules apply.

    When set, the MULTIPLE-FLAG makes the OPTION-NAME accept a list or a single value. 
    The elements of this list are converted to strings as described above and each of
    the resulting string is added to the command line, preceded by OPTION-STRING.

The SPEC is a property list where the following properties are allowed:

  :PROGRAM PATH-TO-PROGRAM
    The path to the program run by the function NAME.

  :REFERENCE
    A reference to be added to the documentation.

  :DOCUMENTATION
    A documentation string for NAME.

  :REST
    A form to evalute in order to produce remaining arguments on the command line.
    (The arguments are sometimes denoted as “rest arguments.”

TODO
- Describe the ENVIRONMENT parameter.
- Describe the WORKDIR parameter.
"
  (let ((docstring
          (getf spec :documentation))
        (defun-argv
          (concatenate 'list argv '(&key) '(directory environment) (mapcar #'first options)))
        (program
          (getf spec :program))
        (prepare-argv-body
          (let ((argv-rest (getf spec :rest)))
            (cond
              ((eq (first argv-rest) 'append)
               (rest argv-rest))
              (t
               (list argv-rest))))))
    (dolist (option options)
      (push (define-command/prepare-argv (first option) (rest option)) prepare-argv-body))
    `(defun ,name (,@defun-argv)
       ,docstring
       (let ((command-argv
               (mapcar #'define-command/to-string (append ,@prepare-argv-body))))
         (make-instance 'command
                        :program ,program
                        :argv command-argv
                        :directory directory
                        :environment environment
                        :documentation ,docstring)))))


;;;;
;;;; Starting and controlling external programs associated to a command
;;;;

(defgeneric run-command
    (command &key input if-input-does-not-exist
                  output if-output-exists
                  error if-error-exists
                  status-hook)
  (:documentation
   "Start a process executing the specified command in an external (UNIX) process.

Parameters INPUT, OUTPUT, and ERROR all behave similarly. They accept one of
the following values:

  NIL
    When a null stream should be used,

  T
    The standard input (resp. output, error) from the process runinng the Lisp
    is inherited by the created external process.

  A-STREAM
    The A-STREAM is attached to the standard input (resp. output, error) of
    the created external process.

  A-PATHNAME-DESIGNATOR
    The corresponding file is open and attached to the standard input
    (resp. output, error) of the created external process.

 :STREAM
    A new stream opened for character input or output is created and
    attached to the created external process.  This stream can
    be manipulated by one of the COMMAND-*-STREAM functions.

 :OUTPUT
    This value is only valid for the :ERROR parameter and directs the
    standard error of the created process output to the same destination
    as the standard output.

When :INPUT is the name of a file, the IF-INPUT-DOES-NOT-EXIST parameter
defines the behaviour of the start command when it would attach standard
input for the process to a non existing file. This parameter can take
the following values:

  NIL (default)
    The start command does not create an external process and returns NIL.

  :ERROR
    The start command does not create an external process and signals
    an error condition.

  :CREATE
    The start command creates an empty file.

When :OUTPUT is the name of a file, the IF-OUTPUT-EXISTS parameter
defines the behaviour of the start command when it would attach standard
output for the process to an already existing file. This parameter can take
the following values:

  NIL (default)
    The start command does not create an external process and returns NIL.

  :ERROR
    The start command does not create an external process and signals
    an error condition.

  :SUPERSEDE
    The content of the file will be superseded by the output of the
    external process.

  :APPEND
    The output of the external process will be appended to the content
    of the file.

When :ERROR is the name of a file, the IF-ERROR-EXISTS parameter
defines the behaviour of the start command when it would attach standard
error to an existing file.  It takes the exact same values as IF-OUTPUT-EXISTS.

STATUS-HOOK is a function the system calls whenever the status of
the process changes. The function takes the command as an argument.")
  #+sbcl
  (:method ((command command) &key input if-input-does-not-exist
                                   output if-output-exists
                                   error if-error-exists
                                   status-hook)
    (with-slots (program argv environment process) command
      (when process
        (error "The COMMAND has already been started."))
      (setf process
            (sb-ext:run-program
             program argv
             :environment environment
             :input input :if-input-does-not-exist if-input-does-not-exist
             :output output :if-output-exists if-output-exists
             :error error :if-error-exists if-error-exists
             :wait nil
             :status-hook status-hook))
      (values command))))

(defun command-p (object)
  "T if object is a command, NIL otherwise."
  (typep object 'command))

(defgeneric command-status (command)
  (:documentation
   "Return a keyword denoting the status of the external process running
the command:

The status can be one of

  :PENDING
    When the command has not been started, so that no external process
    actually runs it.

  :RUNNING
    When the command has been started and an external process currently runs it.

  :STOPPED
    When the operating system stopped the process and the process can be restarted.

  :EXITED
    When the process terminated after exiting. The exit code
    of the process is returned as a second value.

  :SIGNALED
    When the process terminated after receiving a signal. The signal number
    that terminated the process is returned as a second value.")
  #+sbcl
  (:method ((command command))
    (with-slots (process) command
      (let ((process-status
              (if process
                  (sb-ext:process-status process)
                  :pending)))
        (ecase process-status
          ((:pending :running :stopped)
           process-status)
          ((:exited :signaled)
           (values process-status (sb-ext:process-exit-code process))))))))
      
(defgeneric command-input (command)
  (:documentation
   "The standard input of the external process running the command or NIL.")
  #+sbcl
  (:method ((command command))
    (with-slots (process) command
        (when process (sb-ext:process-input process)))))

(defgeneric command-output (command)
  (:documentation
   "The standard output of the external process running the command or NIL.")
  #+sbcl
  (:method ((command command))
    (with-slots (process) command
        (when process (sb-ext:process-output process)))))

(defgeneric command-error (command)
  (:documentation
   "The standard error of the external process running the command or NIL.")
  #+sbcl
  (:method ((command command))
    (with-slots (process) command
      (when process (sb-ext:process-error process)))))

(defgeneric kill-command (command signal)
  (:documentation
   "Sends the given UNIX SIGNAL to the external process running COMMAND.
The SIGNAL can be either an integer or one of the keyword in `*SIGNAL-TABLE*'.
When the PROCESS for command is in :PENDING state, no action is taken
and NIL is returned.")
  #+sbcl
  (:method ((command command) signal)
    (declare ((or keyword integer) signal))
    (let ((signal-value
            (if (keywordp signal)
                (or (cdr (assoc signal *signal-table*))
                    (error "The keyword ~A is not associated to a numeric signal value." signal)))))
      (with-slots (process) command
        (when process (sb-ext:process-kill process signal-value))))))

(defgeneric wait-command (command &optional check-for-stopped)
  (:documentation
   "Wait for the external process running COMMAND to quit running.
When CHECK-FOR-STOPPED is T, also returns when process is stopped.
When the command is still :PENDING it returns immediately.
Returns COMMAND.")
  #+sbcl
  (:method ((command command) &optional check-for-stopped)
    (and
     (sb-ext:process-wait (slot-value command 'process) check-for-stopped)
     command)))

(defgeneric close-command (command)
  (:documentation
   "Close all streams connected to the process running the COMMAND and stop maintaining the status slot.
Returns COMMAND.
TODO:
- Clarify when to use this method – after or before the process exited?")
  #+sbcl
  (:method ((command command))
    (with-slots (process) command
      (and process (sb-ext:process-close process)))
    (values command)))

(defmethod print-object ((command command) stream)
  (print-unreadable-object (command stream :type t :identity t)
    (print-object (slot-value command 'program) stream)
    (multiple-value-bind (status code) (command-status command)
      (write-string " :" stream)
      (write-string (symbol-name status) stream)
      (case status
        ((:signaled :exited)
         (write-char #\Space stream)
         (write code :stream stream))))))

(defmethod describe-object ((command command) stream)
  (print-object command stream)
  (format stream "~%  [standard-object]~%~%")
  (format stream "A command to run the program ~S on the arguments ~S.~%"
          (slot-value command 'program)
          (slot-value command 'argv))
  (multiple-value-bind (status code) (command-status command)
    (format stream "~%Status:~%  ")
    (ecase status
      (:pending
       (format stream "The command has not been started yet.~%"))
      (:running
       (format stream "The command is currently running.~%"))
      (:stopped
       (format stream "The command has been stopped by the operating system. It can be
resumed by sending the :CONTINUE signal.~%"))
      (:exited
       (format stream "The command terminated normally by calling exit with the status code ~D.~%" code))
      (:signaled
       (format stream "The command terminated because it received the signal ~D." code)))))


;;;;
;;;; Hardwired Conversation
;;;;

(defun arranged-conversation (clauses)
  "Prepare a command providing an arranged in advance conversation according to CLAUSES.
The command evaluates each clause in CLAUSES in sequence. Each of these clauses
can be one of the following forms:

  (:SLEEP DURATION-IN-SECONDS)
    Put process to sleep for DURATION-IN-SECONDS

  (:WRITE-OUTPUT-LINE STRING)
    Write STRING on process standard output. The output is not buffered.

  (:WRITE-ERROR-LINE STRING)
    Write STRING on process standard error. The output is not buffered.

  (:READ-INPUT-LINE STRING)
    Read a line from process standard input. If the input is different from string,
    then an explanatory error message is printed on standard error and the command
    terminates with exit code 1.

Bugs:
- The implementation does not validate the clauses.
- The implementation generates a shell script transferred
  as an argument to /bin/sh -c which limits the number of clauses
  that can consitute an arranged conversation.
- The implementation pass all strings to shell as-is in single quotes, which
  is extremly brittle.

(The intended use of HARDWIRED-CONVERSATION is for testing and debugging.)"
  (labels
      ((write-script (clauses)
         (write-string "write_output_line()
{
  printf '%s\\n' \"$1\"
}

write_error_line()
{
  1>&2 printf '%s\\n' \"$1\"
}

read_input_line()
{
  local expected got
  expected=\"$1\"

  read got
  if [ \"${expected}\" != \"${got}\" ]; then
    1>&2 printf 'Error: GOT: %s\\n' \"${got}\"
    1>&2 printf 'Error: EXPECTED: %s\\n' \"${expected}\"
  fi
}
")
         (loop for clause in clauses
               do
               (case (first clause)
                 (:sleep
                  (format *standard-output* "sleep ~A~%" (second clause)))
                 (:exit
                  (format *standard-output* "exit ~A~%" (second clause)))
                 (:write-output-line
                  (format *standard-output* "write_output_line '~A'~%" (second clause)))
                 (:write-error-line
                  (format *standard-output* "write_error_line '~A'~%" (second clause)))
                 (:read-input-line
                  (format *standard-output* "read_input_line '~A'~%" (second clause)))))
         (finish-output))
       (prepare-script (clauses)
         (with-output-to-string (script)
           (let ((*standard-output* script))
             (write-script clauses))))
       (prepare-documentation (clauses)
         (format nil "A command running an arranged conversation.
The arranged conversation is driven by the following clauses:
~S
" clauses)))
    (make-instance 'command
                   :program #p"/bin/sh"
                   :argv (list "-c" (prepare-script clauses))
                   :documentation (prepare-documentation clauses))))

;;;; End of file `rashell.lisp'
