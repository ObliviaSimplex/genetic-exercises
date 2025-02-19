(in-package :genlin)
;; =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
;; Pack operations
;; =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=

;; a pack is a list of creatures
;; we'll start with a simple control structure: the car of the pack is
;; the delegator. It delegates the decision to (elt pack (execute-sequence
;; (creature-eff (car pack))) mod (length pack)), which is then executed.
;; obviously, it is possible to develop more complicated control structures,
;; so long as provisions are made to handle the halting problem (a timer, e.g.)
;; but we'll start with these simple constructions of "star packs".

(defun execute-pack (alpha-crt &key (input) (output *out-reg*))
  (let ((delegator-registers ;; should store as a constant. 
         (loop for i from 0 to (1- (expt 2 *destination-register-bits* collect i)))))
    ;; let the delegation task use a distinct register, if available,
    ;; by setting its output register to the highest available R/W reg. 
    (execute-creature
     (elt (creature-pack alpha-crt) 
          (register-vote (execute-creature alpha-crt
                                           :input input
                                           :output delegator-registers
                                           (length pack)))
     :input input
     :output output)))


(defun pmutate-shuffle (pack)
  (shuffle pack))

(defun pmutate-shuffle-underlings (pack)
  (cons (car pack) (shuffle (cdr pack))))

(defun pmutate-swap-alpha (pack)
  (let ((tmp))
    (setf tmp (car pack))
    (setf (pick (cdr pack)) (car pack))
    (setf (car pack) tmp)
    pack))

(defun pmutate-inbreed (pack)
  (let* ((p0 (pick pack))
         (p1 (if (> (length pack) 2)
                 (pick (remove p0 pack))
                 (random-mutation p0)))
         (cubs))
    (unless (or (null p0) (null p1))
      (setf cubs (mate p0 p1 :sex t)))
    (nsubst p0 (car cubs) pack)
    (nsubst p1 (cdr cubs) pack)    
    pack))

(defun pmutate-alpha (pack)
  (setf #1=(creature-seq (car pack))
          (random-mutation #1#))
  pack)

(defun pmutate-smutate (pack)
  (let ((mutant (pick pack)))
    (setf #1=(creature-seq mutant)
          (random-mutation #1#))
  pack))

(defun pmutate-smutate-underlings (pack)
  (cons (car pack) (pmutate-smutate (cdr pack))))

(defun pack-mingle (pack1 pack2)
  "Destructively mingles the two packs, preserving alphas and size."
  (let ((underlings (shuffle (concatenate 'list (cdr pack1) (cdr pack2)))))
    (setf pack1 (cons (car pack1)
                      (subseq underlings 0 (length pack1))))
    (setf pack2 (cons (car pack2)
                      (subseq underlings (length pack1))))
    (list pack1 pack2)))


;; Note for pack mutations: do not mutate a creature without replacing it. otherwise eff, fit, cas, etc. are falsified. if not replacing, then reset these attributes. 

(defun pack-mate (pack1 pack2)
  "Nondestructively mates the two packs, pairwise, producing two new packs."
  (let ((offspring
         (loop
            for p1 in pack1
            for p2 in pack2 collect
              (mate p1 p2))))
    (list (mapcar #'car offspring)
          (mapcar #'cadr offspring))))
    

(defparameter *pack-mutations*
  (vector #'pmutate-smutate #'pmutate-inbreed #'pmutate-swap-alpha
  #'pmutate-shuffle-underlings #'pmutate-alpha))


(defparameter *underling-mutations*
  (vector #'pmutate-shuffle-underlings #'pmutate-inbreed))
;; accidental cloning problem...
;; packs seem to collapse into pointers to identical creatures.
;; needs some tinkering. 

(defun random-pack-mutation (pack)
  (setf pack (funcall (pick *pack-mutations*) pack)))


(defun pack-coverage (pack &key (ht *training-hashtable*))
  (measure-population-case-coverage (cdr pack) ht))

(defun mutate-pack (pack)
  (cond ((= 1 (pack-coverage pack))
         ;; when pack coverage complete, mutate alpha
         (random-mutation (car pack)))
        (t (
