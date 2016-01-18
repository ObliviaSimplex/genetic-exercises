;;; =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
;;; Linear Genetic Algorithm
;;; =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
;;; TODO:
;;; - fix roulette (incorporate recent modifications to engine)
;;; - let seqs be vecs instead of lists, so that we can manipulate PC


(defpackage :genetic.linear
  (:use :common-lisp))

(in-package :genetic.linear)

(defun loadfile (filename)
  (load (merge-pathnames filename *load-truename*)))

(loadfile "/home/oblivia/Projects/genetic-exercises/genetic-linear/tictactoe.lisp")

(defparameter *tictactoe-path* "/home/oblivia/Projects/genetic-exercises/genetic-linear/datasets/TicTacToe/tic-tac-toe-balanced.data")

(defparameter *DEBUG* nil)

(defparameter *VERBOSE* nil)

(defparameter *ht* (make-hash-table :test 'equal))

;; =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
;; Genetic Parameters
;; =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=

(defparameter *best* (make-creature :fit 0))

(defparameter *population* '())

(defparameter *mutation-rate* 15)

(defstruct creature fit seq eff idx)

(defparameter *min-len* 2) ;; we want to prevent seqs shrinking to nil

(defparameter *max-len* 256) ;; max instruction length

(defparameter *max-start-len* 25) ;; max initial instruction length


;; =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
;;                            Virtual machine
;; =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
;;                           INSTRUCTION FIELDS
;; =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=

;; --- Adjust these 3 parameters to tweak the instruction set. ---
;; --- The rest of the parameters will respond automatically   ---
;; --- but due to use of inlining for optimization, it may     ---
;; --- be necessary to recompile the rest of the programme.    ---

(defparameter *opf* 3)   ;; size of opcode field, in bits

(defparameter *srcf* 3)  ;; size of source register field, in bits

(defparameter *dstf* 2)  ;; size of destination register field, in bits

;; --- Do not adjust the following five parameters manually ---

(defparameter *wordsize* (+ *opf* *srcf* *dstf*))

(defparameter *max-inst* (expt 2 *wordsize*)) ;; upper bound on inst size

(defparameter *opbits* (byte *opf* 0))

(defparameter *srcbits* (byte *srcf* *opf*))

(defparameter *dstbits* (byte *dstf* (+ *srcf* *opf*)))

;; --- Operations: these can be tweaked independently of the 
;; --- fields above, so long as their are at least (expt 2 *opf*)
;; --- elements in the *opcodes* vector. 

(declaim (inline DIV MUL XOR CNJ DIS PMD ADD SUB MUL JLE)) 

(defun DIV (&rest args)
  "A divide-by-zero-proof division operator."
  (if (some #'zerop args) 0
      (/ (car args) (cadr args))))

(defun XOR (&rest args) ;; xor integer parts
  (logxor (floor (car args)) (floor (cadr args))))

(defun CNJ (&rest args)
  (logand (floor (car args)) (floor (cadr args))))

(defun DIS (&rest args)
;;x  (declare (type (cons fixnum)) args)
  (lognot (logand  (lognot (floor (car args)))
                   (lognot (floor (cadr args))))))

(defun PMD (&rest args)
  "Protected MOD."
  (if (some #'zerop args) (car args)
      (mod (car args) (cadr args))))

(defun ADD (&rest args)
  (+ (car args) (cadr args)))

(defun SUB (&rest args)
  (- (car args) (cadr args)))

(defun MUL (&rest args)
  (* (car args) (cadr args)))

(defun JLE (&rest args) ;; CONDITIONAL JUMP OPERATOR
  (if (<= (car args) (cadr args)) (1+ (caddr args))
      (caddr args)))
    

(defparameter *opcodes*
  (vector  #'DIV #'MUL #'SUB #'ADD   ;; basic operations    (2bit opcode)
           #'XOR #'PMD #'CNJ #'JLE)) ;; extended operations (3bit opcode)

;; adding the extended opcodes seems to result in an immense boost in the
;; population's fitness -- 0.905 is now achieved in the time it took to
;; reach 0.64 with the basic operation set. (For tic-tac-toe.)

;; =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
;; General Mathematical Helper Functions
;; =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=

(defun n-rnd (low high &optional (r '()) (n 4))
  "Returns a list of n distinct random numbers between low and high."
  (declare (type fixnum low high n))
  (declare (optimize speed))
  (when (< (- high low) n)
    (error "Error in n-rnd: interval too small: infinite loop"))
  (loop (when (= (length r) n)
          (return r))
     (setf r (remove-duplicates (cons (+ low (random high)) r)))))

;; a helper:
(defun sieve-of-eratosthenes (maximum) "sieve for odd numbers"
       ;; taken from Rosetta Code. 
       (cons 2
             (let ((maxi (ash (1- maximum) -1))
                   (stop (ash (isqrt maximum) -1)))
               (let ((sieve (make-array (1+ maxi)
                                        :element-type 'bit
                                        :initial-element 0)))
                 (loop for i from 1 to maxi
                    when (zerop (sbit sieve i))
                    collect (1+ (ash i 1))
                    and when (<= i stop) do
                      (loop for j from
                           (ash (* i (1+ i)) 1) to maxi by (1+ (ash i 1))
                         do (setf (sbit sieve j) 1)))))))

;; =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
;; Parameters for register configuration.
;; =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=

(defparameter *maxval* (expt 2 16)) ;; max val that can be stored in reg

(defparameter *default-input-reg*
  (concatenate 'vector (loop for i from 1 to (- (expt 2 *srcf*) (expt 2 *dstf*))
                            collect (expt -1 i))))

(defparameter *default-registers*
  (concatenate 'vector #(0) (loop for i from 2 to (expt 2 *dstf*)
                               collect (expt -1 i))))

(defparameter *pc-idx*
  (+ (length *default-registers*) (length *default-input-reg*)))

(defparameter *initial-register-state*
  (concatenate 'vector
               *default-registers*
               *default-input-reg*
               #(0))) ;; PROGRAMME COUNTER

            ;;   (sieve-of-eratosthenes 18))) ;; some primes for fun

(defparameter *input-start-idx* (length *default-registers*))

(defparameter *input-stop-idx*
  (+ *input-start-idx* (length *default-input-reg*)))

;; =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
;; Functions for extracting fields from the instructions
;; and other low-level machine code operations.
;; =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=

(declaim (inline src? dst? op?))

(defun src? (inst)
  (declare (type fixnum inst))
  (declare (type cons *srcbits*))
  (ldb *srcbits* inst))

(defun dst? (inst)
  (declare (type fixnum inst))
  (declare (type cons *dstbits*))
  (ldb *dstbits* inst))

(defun op? (inst)
  (declare (type fixnum inst))
  (declare (type cons *opbits*))
  (declare (type (simple-array function) *opcodes*))
  (aref *opcodes* (ldb *opbits* inst)))

(defun jmp? (inst) ;; ad-hoc-ish...
  (equalp (op? inst) #'JLE))

(defun enter-input (registers input)
  (let ((copy (copy-seq registers)))
    (setf (subseq copy *input-start-idx*
                  (+ *input-start-idx* (length input)))
          input)
    copy))

;; =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
;; debugging functions
;; =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=

(defun print-registers (registers)
  (loop for i from 0 to (1- (length registers)) do
       (format t "R~d: ~6f ~c" i (aref registers i) #\TAB)
       (if (= 0 (mod (1+ i) 4)) (format t "~%")))
  (format t "~%"))

(defun func->string (func)
  (let* ((fm (format nil "~a" func))
         (i (mismatch fm "#<FUNCTION __"))
         (o (subseq fm i (1- (length fm)))))
    o))

(defun inst->string (inst &optional (registers *initial-register-state*))
  (format nil "[~a  R~d, R~d] ;; (~f, ~f)"
          (func->string (op? inst)) (src? inst) (dst? inst)
          (aref registers (src? inst)) (aref registers (dst? inst))))

(defun hrule ()
  (format t "-----------------------------------------------------------------------------~%"))

(defun disassemble-sequence (seq &key (registers *initial-register-state*)
                                   (input *default-input-reg*)) 
  (let ((od *debug*)
        (regs (copy-seq registers)))
    (enter-input regs input)
    (hrule)
    (print-registers regs)
    (hrule)
    (setf *debug* 1)
    (execute-sequence seq :input input :registers regs)
    (setf *debug* od)
    (print-registers regs)
    (hrule)))
    
(defun dbg (&optional on-off)
  (case on-off
    ((on)  (setf *debug* t))
    ((off) (setf *debug* nil))
    (otherwise (setf *debug* (not *debug*)))))

;; =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
;; Intron Removal and Statistics
;; =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=

(defun remove-introns (seq &key (out '(0)))
  (let ((efr out)
        (efseq '()))
    (loop for i from (1- (length seq)) downto 0 do
         (let ((inst (aref seq i)))
           (when (member (dst? inst) efr)
             (push (src? inst) efr)
             (push inst efseq))))
    (coerce efseq 'vector)))

(defun percent-effective (crt &key (out '(0)))
  (unless (creature-eff crt)
    (setf (creature-eff crt) (remove-introns (creature-seq crt) :out out)))
  (float (/ (length (creature-eff crt)) (length (creature-seq crt)))))

(defun average-effective (population &key (out 0))
  (/ (reduce #'+ (mapcar #'percent-effective population))
     (length population)))

;; =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
;; Execution procedure
;; =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=

(defun execute-sequence (seq &key (registers *initial-register-state* )
                               (input *default-input-reg*)
                                    (output 0))
  "Takes a sequence of instructions, seq, and an initial register 
state vector, registers, and then runs the virtual machine, returning the
resulting value in R0."
  ;; (declare (optimize (speed 1)))
  (declare (type (simple-array rational (*)) registers
                 input *default-input-reg* *initial-register-state*))
  (declare (type fixnum output *input-start-idx*))
  (declare (inline src? dst? op?))
  
  (let ((regs (copy-seq registers))
        (seqlen (length seq)))
    ;; the input values will be stored in read-only regs
    (setf (subseq regs *input-start-idx*
                  (+ *input-start-idx* (length input))) input)
    ;;      (format t "input: ~a~%regs: ~a~%" inp regs)
    (unless (zerop seqlen)
      (loop do
           (let* ((inst (aref seq (aref regs *pc-idx*)))
                (D (if (jmp? inst) *pc-idx* (dst? inst))))
             
             (and *debug* (format t "~8,'0b  ~a" inst
                                  (inst->string inst regs)))
             (incf (aref regs *pc-idx*))
             (setf (aref regs D)
                 (rem (apply (op? inst)
                             (list (aref regs (src? inst))
                                   (aref regs (dst? inst))
                                   (aref regs *pc-idx*))) *maxval*))
             (and *debug* (format t " ;; now R~d = ~f; PC = ~d~%"
                                  (dst? inst) (aref regs (dst? inst))
                                  (aref regs *pc-idx*)))
             (and (>= (aref regs *pc-idx*) seqlen) (return)))))
    (and *debug* (hrule))
    (aref regs output)))

;; =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
;; Genetic operations (variation)
;; =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=

(defun imutate-flip (inst)
  "Flips a random bit in the instruction."
  (declare (type fixnum inst))
  (logxor inst (ash 1 (random *wordsize*))))

;; Some of these mutations are destructive, some are not, so we'll
;; rig each of them to return the mutated sequence, and we'll treat
;; them as if they were purely functional, and combine them with an
;; setf to mutate their target. 

(defun smutate-swap (seq)
  "Exchanges the position of two instructions in a sequence."
  (declare (type simple-array seq))
  (and *debug* (print "smutate-swap"))
  (let* ((len (length seq))
         (i (random len))
         (j (random len))
         (tmp (elt seq i)))
    (setf (elt seq i) (elt seq i))
    (setf (elt seq j) tmp))
  seq)

(defun smutate-push (seq)
  "Adds another (random) instruction to a sequence."
  (declare (type simple-array seq))
  (and *debug* (print "smutate-push"))
  (push (random #x100) seq)
  seq)

(defun smutate-pop (seq)
  "Decapitates a sequence."
  (declare (type simple-array seq))
  (and *debug* (print "smutate-pop"))
  (and (> (length seq) *min-len*) (pop seq))
  seq)

(defun smutate-grow (seq)
  "Adds another (random) instruction to the end of the sequence."
  (declare (type simple-array seq))
  (and *debug* (print "smutate-append"))
  (setf seq (concatenate 'vector seq `(,(random #x100))))
  seq)

(defun smutate-imutate (seq)
  "Applies imutate-flip to a random instruction in the sequence."
  (declare (type simple-array seq))
  (and *debug* (print "smutate-imutate"))
  (let ((idx (random (length seq))))
    (setf (elt seq idx) (imutate-flip (elt seq idx))))
  seq)

(defparameter *mutations*
  (vector #'smutate-grow #'smutate-imutate #'smutate-swap))

(defun random-mutation (seq)
  (declare (type simple-array seq))
  (apply (aref *mutations* (random (length *mutations*))) `(,seq)))

(defun maybe-mutate (seq)
  (declare (type simple-array seq))
  (if (< (random 100) *mutation-rate*)
      (random-mutation seq)
      seq))

(defun crossover (p0 p1)
;;  (declare (type cons p0 p1))
;;  (declare (optimize (speed 2)))
  (let* ((p00 (creature-seq p0))
         (p01 (creature-seq p1))
         (parents (sort (list p00 p01) #'(lambda (x y) (< (length x) (length y)))))
         (father (car parents))  ;; we trim off the car, which holds fitness
         (mother (cadr parents)) ;; let the father be the shorter of the two
         (r-align (random 2)) ;; 1 or 0
         (offset (* r-align (- (length mother) (length father))))
         (daughter (copy-seq mother))
         (son (copy-seq father))
         (idx0 (random (length father)))
         (idx1 (random (length father)))
         (minidx (min idx0 idx1))
         (maxidx (max idx0 idx1)))
;;    (declare (type cons mother father daughter son))
;;    (declare (type fixnum idx0 idx1 minidx maxidx offset r-align))
    ;(format t "minidx: ~d  maxidx: ~d  offset: ~d~%" minidx maxidx offset)
    (setf (subseq daughter (+ offset minidx) (+ offset maxidx))
          (subseq father minidx maxidx))
    (setf (subseq son minidx maxidx)
          (subseq mother (+ offset minidx) (+ offset maxidx)))         
;;    (format t "mother: ~a~%father: ~a~%daughter: ~a~%son: ~a~%"
;;            mother father daughter son)
    (list (make-creature :seq (maybe-mutate son))
          (make-creature :seq (maybe-mutate daughter)))))
;; we still need to make this modification to roulette, to accommodate the
;; fitness-storing cons cell in the car of each individual 

;; =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
;; Functions related to fitness measurement
;; =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=

;; Convention for fitness functions: let 1 be maximum value. no lower bound -- may
;; go to arbitrarily small fractions < 1

(declaim (inline binary-error-measure))

(defun binary-error-measure (raw goal)
  ;; goal is a boolean value (t or nil)
  ;; raw is, typically, the return value in r0
  (let ((div (/ *maxval* 10000)))
    (flet ((sigmoid (x)
             (tanh (/ x div))))
      ;; if raw is < 0, then (sigmoid raw) will be between
      ;; 0 and -1. If the goal is -1, then the final result
      ;; will be (-1 + p)/2 -- a value between -0.5 and -1,
      ;; but taken absolutely as a val between 0.5 and 1.
      ;; likewise when raw is > 0. 
      (/ (abs (+ (sigmoid raw) goal)) 2))))

(defun fitness-binary-classifier-1 (seq hashtable)
  ;; positive = t; negative = nil
  ;; (declare (type hash-table hashtable))
  ;; (declare (type cons seq))
  ;; (declare (optimize speed))
  (let ((results (loop for pattern being the hash-keys in hashtable collect
                      (binary-error-measure (execute-sequence seq :input pattern)
                                            (gethash pattern hashtable)))))
    ;; (declare (type (cons rational) results))
    (and *debug* *verbose*
         (format t "SEQUENCE:~a~%RESULTS:~%~a~%" seq results))
    (/ (apply #'+ results) (length results)))) ;; average

(defun fitness-binary-classifier-2 (seq hashtable)
  ;; (declare (type hash-table hashtable))
  ;; (declare (type (cons rational) seq))
  ;; (declare (optimize speed))
  (let ((correct 0)
        (incorrect 0))
    ;; (declare (type integer correct incorrect))
    (loop for pattern being the hash-keys in hashtable do
         (let ((f (execute-sequence seq :input pattern))
               (v (gethash pattern hashtable)))
           ;; (declare (type rational f v))
           (if (> (* f v) 0) (incf correct) (incf incorrect))))
    ;;    (format t "SEQ: ~a~%CORRECT: ~d    INCORRECT ~d~%~%" seq correct incorrect)
    (if (zerop incorrect) 1
        (/ correct (+ correct incorrect)))))

(defun fitness-0 (seq)
  (let ((target 666))
    (/ 1 (1+ (abs (- (execute-sequence (final-dst seq 0)
                                       :registers *initial-register-state*)
                     target))))))

(defun fitness (crt &key (lookup nil) (output-register 0))
  ;; we execute (cdr seq), because the first cons cell of
  ;; each sequence stores the fitness of that sequence, or
  ;; else, nil. 
  (unless (creature-fit crt)  
    (flet ((fitfunc (s)
             (fitness-binary-classifier-1 s lookup)))
      (setf (creature-eff crt)
            (remove-introns (creature-seq crt) :out (list output-register)))
      (setf (creature-fit crt) (fitfunc (creature-eff crt)))
      (when (or (null (creature-fit *best*)) (> (creature-fit crt) (creature-fit *best*)))
        (setf *best* (copy-structure crt))
        (and *debug* (format t "FITNESS: ~f~%BEST:    ~f~%"
                             (creature-fit crt) (creature-fit *best*))))))
  (creature-fit crt))

;; =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
;; Selection functions
;; =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=

(defun tournement (population &key (lookup nil))
  (let* ((lots (n-rnd 0 (length *population*)))
         (combatants (mapcar #'(lambda (i) (nth i population)) lots)))
    (and *debug* (format t "COMBATANTS BEFORE: ~a~%" combatants))
    (loop for combatant in combatants do
         (unless (creature-fit combatant)
           (setf (creature-fit combatant)
                 (fitness combatant :lookup lookup))))
    (and *debug* (format t "COMBATANTS AFTER: ~a~%" combatants))
    (let* ((ranked (sort combatants #'(lambda (x y) (< (creature-fit x) (creature-fit y)))))
           (parents (cddr ranked))
           (children (apply #'crossover parents))
           (the-dead (subseq ranked 0 2)))
      (map 'list #'(lambda (i j) (setf (creature-idx i) (creature-idx j)))
           children the-dead)
      (mapcar #'(lambda (x) (setf (nth (creature-idx x) population) x)) children) 
      (and *debug* (format t "RANKED: ~a~%" ranked))
      *best*)))

(defun spin-wheel (wheel top)
  (let ((ball (random (float top)))
        (ptr (car wheel)))
    ;; (format t "TOP: ~a~%BALL: ~a~%" top ball)
    (loop named spinning for slot in wheel do
         (when (< ball (car slot))
           (return-from spinning))
         (setf ptr slot))
    ;; ptr now points to where the ball 'lands'
    ;; (and (null ptr) (error "NIL PTR RESULTING FROM SPIN WHEEL."))
    ;; (format t "PTR: ~a~%" ptr)
    (cdr ptr)))
  
(defun roulette (population &key (lookup nil))
  (let* ((tally 0)
         (popsize (length population))
         (wheel (loop for creature in population
                   collect (progn
                             (let ((f (float (fitness creature
                                                      :lookup lookup))))
                               (incf tally f)
                               (cons tally creature)))))
         ;; the roulette wheel is now built
         ;;(format t "WHEEL: ~a~%" wheel)
         (breeders (loop for i from 1 to popsize
                      collect (spin-wheel wheel tally)))
         (half (/ popsize 2))
         (mothers (subseq breeders 0 half))
         (fathers (subseq breeders half popsize)))
    ;;(format t "MOTHERS: ~a~%FATHERS: ~a~%" mothers fathers)
    ;;(print "CHILDREN:")
    (apply #'concatenate 'list (map 'list #'crossover mothers fathers))))
           
(defun next-generation (&key (lookup nil))
  (setf *population* (roulette *population* :lookup lookup)))

;; =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
;; Initialization functions
;; =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=

(defun spawn-sequence (len)
  (concatenate 'vector (loop repeat len collect (random *max-inst*))))

(defun spawn-creature (len &key idx)
  (make-creature :seq (spawn-sequence len) :idx idx))

(defun init-population (popsize slen)
  (loop for i from 0 to (1- popsize) collect
       (spawn-creature (+ *min-len* (random slen)) :idx i)))

(defun setup-tictactoe (&optional (graycode t))
  (let* ((filename "/home/oblivia/Projects/genetic-exercises/genetic-linear/datasets/TicTacToe/tic-tac-toe-balanced.data")
         (hashtable (datafile->hashtable filename :int graycode)))
    (setf *best* (make-creature :fit 0))
    (setf *population* (init-population 500 *max-start-len*))
    (print "population initialized in *population*; data read; hashtable in *ht*")
    (setf *ht* hashtable)
    hashtable))

;; =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
;; User interface functions
;; =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=

(defun classification-report (crt &optional (ht *ht*))
  (format t "REPORT FOR ~a~%=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=~%" crt)
  (let ((seq (creature-eff crt))
        (correct 0)
        (incorrect 0))
    (loop for k being the hash-keys in ht do
         (let ((i (aref k 0))
               (f (execute-sequence seq :input k)))
           (format t "~%~a~%" (int->board i))
         (cond ((> (* (gethash k ht) f) 0)
                (format t "CORRECTLY CLASSIFIED ~a -> ~f~%~%" i f)
                (incf correct))
               ((< (* (gethash k ht) f) 0)
                (format t "INCORRECTLY CLASSIFIED ~a -> ~f~%~%" i f)
                (incf incorrect))
               (t (format t "WHO'S TO SAY? ~a -> ~f~%~%" i f))))
         (hrule))
    (format t "TOTAL CORRECT:   ~d~%TOTAL INCORRECT: ~d~%"
            correct incorrect)))
    ;;(format t "~%A STRANGE GAME.~%THE ONLY WINNING MOVE IS NOT TO PLAY.~%~%HOW ABOUT A NICE GAME OF CHESS?")))

(defun do-tournements (&key (rounds 10000) (target 0.97))
  (let ((oldbest *best*))
    (time (block tournies
            (dotimes (i rounds)
              (tournement *population* :lookup *ht*)
              (when (or (null (creature-fit *best*))
                        (> (creature-fit *best*) (creature-fit oldbest)))
                (setf oldbest *best*)
                (format t "NEW BEST AT ROUND ~d: ~a~%" i *best*)
                (disassemble-sequence (creature-eff *best*)))
              (and (> (creature-fit *best*) target) (return-from tournies)))))
    (format t "BEST: ~f~%" (creature-fit *best*))))

