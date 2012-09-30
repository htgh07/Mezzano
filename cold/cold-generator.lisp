(defpackage #:cold-generator
  (:use #:cl #:iterate #:nibbles))

(in-package #:cold-generator)

(defparameter *source-files*
  '("../cold/test.lisp"))

;; name, allocation mode, initial size (2MB pages), <2gb addresses only.
(defparameter *initial-areas*
  '((support-area :static 1 t)
    (page-table-area :raw 4 t)
    (function-area :static 32 nil)
    (interrupt-area :static 1 nil)
    (stack-area :stack 1 nil)
    (runtime-allocation-area :dynamic 16 nil)))

(defparameter *undefined-function-thunk*
  `((sys.lap-x86:cmp64 :rcx ,(* 5 8))
    (sys.lap-x86:jl register-args-only)
    ;; Have to spill R12 on the stack.
    (sys.lap-x86:mov64 (:lsp -8) nil)
    (sys.lap-x86:sub64 :lsp 8)
    (sys.lap-x86:mov64 (:lsp) :r12)
    register-args-only
    ;; Shuffle registers up.
    (sys.lap-x86:mov64 :r12 :r11)
    (sys.lap-x86:mov64 :r11 :r10)
    (sys.lap-x86:mov64 :r10 :r8)
    (sys.lap-x86:mov64 :r9 :r8)
    ;; Pass invoked-through as the first argument.
    (sys.lap-x86:mov64 :r8 :r13)
    (sys.lap-x86:add64 :rcx ,(* 1 8))
    ;; Tail call through to RAISE-UNDEFINED-FUNCTION and let that
    ;; handle the heavy work.
    (sys.lap-x86:mov64 :r13 (:constant raise-undefined-function))
    (sys.lap-x86:jmp (:symbol-function :r13)))
  "Code for the undefined function thunk.")

(defparameter *setup-function*
  `((sys.lap-x86:!code32)
    (sys.lap-x86:mov32 :esp initial-stack)
    ;; Compute the start of the function.
    (sys.lap-x86:call get-eip)
    get-eip
    (sys.lap-x86:pop :esi)
    ;; Set ESI to the start of the function.
    (sys.lap-x86:sub32 :esi get-eip)
    ;; Enable long mode.
    (sys.lap-x86:movcr :eax :cr4)
    (sys.lap-x86:or32 :eax #x000000A0)
    (sys.lap-x86:movcr :cr4 :eax)
    (sys.lap-x86:mov32 :eax initial-page-table)
    (sys.lap-x86:movcr :cr3 :eax)
    (sys.lap-x86:mov32 :ecx #xC0000080)
    (sys.lap-x86:rdmsr)
    (sys.lap-x86:or32 :eax #x00000100)
    (sys.lap-x86:wrmsr)
    (sys.lap-x86:movcr :eax :cr0)
    (sys.lap-x86:or32 :eax #x80000000)
    (sys.lap-x86:movcr :cr0 :eax)
    (sys.lap-x86:lgdt (:esi gdtr))
    (sys.lap-x86:lidt (:esi idtr))
    ;; There was a far jump here, but that's hard to make position-independent.
    (sys.lap-x86:push #x0008)
    (sys.lap-x86:lea32 :eax (:esi long64))
    (sys.lap-x86:push :eax)
    (sys.lap-x86:retf)
    (sys.lap-x86:!code64)
    long64
    (sys.lap-x86:xor32 :eax :eax)
    (sys.lap-x86:movseg :ds :eax)
    (sys.lap-x86:movseg :es :eax)
    (sys.lap-x86:movseg :fs :eax)
    (sys.lap-x86:movseg :gs :eax)
    (sys.lap-x86:movseg :ss :eax)
    ;; Save the multiboot pointer.
    (sys.lap-x86:mov32 :ebx :ebx)
    (sys.lap-x86:shl64 :rbx 3)
    (sys.lap-x86:mov64 :r8 (:constant *multiboot-info*))
    (sys.lap-x86:mov64 (:symbol-value :r8) :rbx)
    ;; SSE init.
    ;; Set CR4.OSFXSR and CR4.OSXMMEXCPT.
    (sys.lap-x86:movcr :rax :cr4)
    (sys.lap-x86:or64 :rax #x00000600)
    (sys.lap-x86:movcr :cr4 :rax)
    ;; Clear CR0.EM and set CR0.MP.
    (sys.lap-x86:movcr :rax :cr0)
    (sys.lap-x86:and64 :rax -5)
    (sys.lap-x86:or64 :rax #x00000002)
    (sys.lap-x86:movcr :cr0 :rax)
    ;; Clear FPU state.
    (sys.lap-x86:fninit)
    ;; Preset the initial stack group.
    (sys.lap-x86:mov64 :r8 (:constant *initial-stack-group*))
    (sys.lap-x86:mov64 :r8 (:symbol-value :r8))
    (sys.lap-x86:mov64 :csp (:r8 ,(- (* 5 8) +tag-array-like+)))
    (sys.lap-x86:add64 :csp (:r8 ,(- (* 6 8) +tag-array-like+)))
    (sys.lap-x86:mov64 :lsp (:r8 ,(- (* 7 8) +tag-array-like+)))
    (sys.lap-x86:add64 :lsp (:r8 ,(- (* 8 8) +tag-array-like+)))
    ;; Clear binding stack.
    (sys.lap-x86:mov64 :rdi (:r8 ,(- (* 9 8) +tag-array-like+)))
    (sys.lap-x86:mov64 :rcx (:r8 ,(- (* 10 8) +tag-array-like+)))
    (sys.lap-x86:sar64 :rcx 3)
    (sys.lap-x86:xor32 :eax :eax)
    (sys.lap-x86:rep)
    (sys.lap-x86:stos64)
    ;; Set the binding stack pointer.
    (sys.lap-x86:mov64 (:r8 ,(- (* 1 8) +tag-array-like+)) :rdi)
    ;; Clear TLS binding slots.
    (sys.lap-x86:lea64 :rdi (:r8 ,(- (* 12 8) +tag-array-like+)))
    (sys.lap-x86:mov64 :rax -2)
    (sys.lap-x86:mov32 :ecx 500)
    (sys.lap-x86:rep)
    (sys.lap-x86:stos64)
    ;; Mark the SG as running/unsafe.
    (sys.lap-x86:mov64 (:r8 ,(- (* 2 8) +tag-array-like+)) 0)
    ;; Initialize GS.
    (sys.lap-x86:mov64 :rax :r8)
    (sys.lap-x86:mov64 :rdx :r8)
    (sys.lap-x86:sar64 :rdx 32)
    (sys.lap-x86:mov64 :rcx #xC0000101)
    (sys.lap-x86:wrmsr)
    ;; Clear frame pointers.
    (sys.lap-x86:mov64 :cfp 0)
    (sys.lap-x86:mov64 :lfp 0)
    ;; Clear data registers.
    (sys.lap-x86:xor32 :r8d :r8d)
    (sys.lap-x86:xor32 :r9d :r9d)
    (sys.lap-x86:xor32 :r10d :r10d)
    (sys.lap-x86:xor32 :r11d :r11d)
    (sys.lap-x86:xor32 :r12d :r12d)
    (sys.lap-x86:xor32 :ebx :ebx)
    ;; Prepare for call.
    (sys.lap-x86:mov64 :r13 (:constant initialize-lisp))
    (sys.lap-x86:xor32 :ecx :ecx)
    ;; Call the entry function.
    (sys.lap-x86:call (:symbol-function :r13))
    ;; Crash if it returns.
    here
    (sys.lap-x86:ud2)
    (sys.lap-x86:jmp here)
    #+nil(:align 4) ; TODO!! ######
    gdtr
    (:d16/le gdt-length)
    (:d32/le gdt)
    idtr
    (:d16/le idt-length)
    (:d32/le idt)))

(defvar *area-info*)
(defvar *symbol-table*)
(defvar *keyword-table*)
(defvar *undefined-function-address*)
(defvar *load-time-evals*)

(defvar *pending-fixups*)

(defun allocate (word-count &optional (area 'runtime-allocation-area))
  (when (oddp word-count) (incf word-count))
  (let* ((info (nth (position area *initial-areas* :key 'first)
                    *area-info*))
         (offset (first info)))
    (assert (<= (+ (first info) word-count)
                (* (third (find area *initial-areas* :key 'first))
                   #x40000))
            (area word-count) "Allocation of ~S words exceeds area size." word-count)
    (incf (first info) word-count)
    (+ (* (second info) #x40000) offset)))

(defun allocate-stack (size style)
  (check-type style (member :control :data :binding))
  (allocate size 'stack-area))

(defun (setf word) (new-value address)
  ;; Find the area holding this word.
  (dolist (a *area-info* (error "Word ~S not in any area?" address))
    (when (and (<= (* (second a) #x40000) address)
               (< (- address (* (second a) #x40000)) (first a)))
      (return (setf (ub64ref/le (third a) (* (- address (* (second a) #x40000)) 8)) new-value)))))

(defun word (address)
  ;; Find the area holding this word.
  (dolist (a *area-info* (error "Word ~S not in any area?" address))
    (when (and (<= (* (second a) #x40000) address)
               (< (- address (* (second a) #x40000)) (first a)))
      (return (ub64ref/le (third a) (* (- address (* (second a) #x40000)) 8))))))

(defun compile-lap-function (code &optional (area 'function-area) extra-symbols constant-values)
  "Compile a list of LAP code as a function. Constants must by symbols only."
  (multiple-value-bind (mc constants fixups)
      (sys.lap-x86:assemble (list* (list :d32/le 0 0 0) code) ; 12 byte header.
	:base-address 0
        :initial-symbols (list* '(nil . :fixup)
                                '(t . :fixup)
                                extra-symbols))
    (let ((total-size (+ (* (truncate (length mc) 16) 2)
                         (length constants))))
      (when (oddp total-size) (incf total-size))
      (let ((address (allocate total-size area)))
        ;; Copy machine code into the area.
        (dotimes (i (truncate (length mc) 8))
          (setf (word (+ address i)) (nibbles:ub64ref/le mc (* i 8))))
        ;; Write constant pool.
        (dotimes (i (length constants))
          (cond ((assoc (aref constants i) constant-values)
                 (setf (word (+ address
                                (truncate (length mc) 8)
                                i))
                       (cdr (assoc (aref constants i) constant-values))))
                (t (check-type (aref constants i) symbol)
                   (push (list (list 'quote (aref constants i))
                               (+ address
                                  (truncate (length mc) 8)
                                  i)
                               0
                               :full64)
                         *pending-fixups*))))
        (dolist (fixup fixups)
          (push (list (car fixup) address (cdr fixup) :signed32)
                *pending-fixups*))
        address))))

(defun create-area-info (areas)
  (let ((32-bit-base 1) ; 2MB
        (64-bit-base 1024)) ; 2GB
    (iter (for (name allocation-mode initial-size 32-bit) in areas)
          (format t "Area ~S begins at word ~X~%" name (* (if 32-bit 32-bit-base 64-bit-base) #x40000))
          (collect (list 0 ; free pointer.
                         (if 32-bit 32-bit-base 64-bit-base) ; offset.
                         ;; Storage.
                         (make-array (* initial-size #x40000 8)
                                     :element-type '(unsigned-byte 8)
                                     :initial-element 0 #+nil #x5555555555555555)
                         ;; newspace offset.
                         (ecase allocation-mode
                           ((:static :stack :raw) nil)
                           (:dynamic
                            (if 32-bit
                                (incf 32-bit-base initial-size)
                                (incf 64-bit-base initial-size))))))
            (if 32-bit
                (incf 32-bit-base initial-size)
                (incf 64-bit-base initial-size)))))

(defun make-value (address tag)
  (logior (* address 8) tag))

(defun pointer-part (value)
  (ash (ldb (byte 64 4) value) 1))

(defun tag-part (value)
  (ldb (byte 4 0) value))

(defun make-fixnum (value)
  (check-type value (signed-byte 61))
  (ldb (byte 64 0) (ash value 3)))

(defconstant +tag-even-fixnum+   #b0000)
(defconstant +tag-cons+          #b0001)
(defconstant +tag-symbol+        #b0010)
(defconstant +tag-array-header+  #b0011)
(defconstant +tag-std-instance+  #b0100)
;;(defconstant +tag-+  #b0101)
;;(defconstant +tag-+  #b0110)
(defconstant +tag-array-like+    #b0111)
(defconstant +tag-odd-fixnum+    #b1000)
;;(defconstant +tag-+  #b1001)
(defconstant +tag-character+     #b1010)
(defconstant +tag-single-float+  #b1011)
(defconstant +tag-function+      #b1100)
;;(defconstant +tag-+  #b1101)
(defconstant +tag-unbound-value+ #b1110)
(defconstant +tag-gc-forward+    #b1111)

(defconstant +array-type-t+ 0)
(defconstant +array-type-base-char+ 1)
(defconstant +array-type-character+ 2)
(defconstant +array-type-bit+ 3)
(defconstant +array-type-unsigned-byte-2+ 4)
(defconstant +array-type-unsigned-byte-4+ 5)
(defconstant +array-type-unsigned-byte-8+ 6)
(defconstant +array-type-unsigned-byte-16+ 7)
(defconstant +array-type-unsigned-byte-32+ 8)
(defconstant +array-type-unsigned-byte-64+ 9)
(defconstant +array-type-signed-byte-1+ 10)
(defconstant +array-type-signed-byte-2+ 11)
(defconstant +array-type-signed-byte-4+ 12)
(defconstant +array-type-signed-byte-8+ 13)
(defconstant +array-type-signed-byte-16+ 14)
(defconstant +array-type-signed-byte-32+ 15)
(defconstant +array-type-signed-byte-64+ 16)
(defconstant +array-type-single-float+ 17)
(defconstant +array-type-double-float+ 18)
(defconstant +array-type-long-float+ 19)
(defconstant +array-type-xmm-vector+ 20)
(defconstant +array-type-complex-single-float+ 21)
(defconstant +array-type-complex-double-float+ 22)
(defconstant +array-type-complex-long-float+ 23)
(defconstant +last-array-type+ 23)
(defconstant +array-type-bignum+ 25)
(defconstant +array-type-stack-group+ 30)
(defconstant +array-type-struct+ 31)

(defun store-string (string)
  (let ((address (allocate (1+ (ceiling (length string) 8)))))
    ;; Header word.
    (setf (word address) (logior (ash (length string) 8) (ash +array-type-base-char+ 1)))
    (dotimes (i (ceiling (length string) 8))
      (let ((value 0))
        (dotimes (j 8)
          (when (< (+ (* i 8) j) (length string))
            (setf (ldb (byte 8 64) value) (char-code (char string (+ (* i 8) j)))))
          (setf value (ash value -8)))
        (setf (word (+ address 1 i)) value)))
    address))

(defun symbol-address (name keywordp &optional (createp t))
  (or (gethash name (if keywordp *keyword-table* *symbol-table*))
      (when (not createp)
        (error "Symbol ~A~A does not exist."
               (if keywordp #\: "")
               name))
      (let ((address (allocate 6)))
        (setf (word address) (make-value (store-string name)
                                           +tag-array-like+)
              (word (+ address 1)) (make-value (gethash "T" *symbol-table*) +tag-symbol+)
              (word (+ address 2)) (if keywordp
                                       (make-value address +tag-symbol+)
                                       (make-value 0 +tag-unbound-value+))
              (word (+ address 3)) (make-value *undefined-function-address* +tag-function+)
              (word (+ address 4)) (make-value (gethash "NIL" *symbol-table*) +tag-symbol+)
              ;; fixme, keywords should be constant.
              (word (+ address 5)) (make-fixnum 0))
        (setf (gethash name (if keywordp *keyword-table* *symbol-table*)) address))))

;; fixme, nil and t should be constant.
(defun create-support-objects ()
  "Create NIL, T and the undefined function thunk."
  (let ((nil-value (allocate 6 'support-area))
        (t-value (allocate 6 'support-area))
        (undef-fn (compile-lap-function *undefined-function-thunk* 'support-area)))
    (setf (word nil-value) (make-value (store-string "NIL")
                                         +tag-array-like+)
          (word (+ nil-value 1)) (make-value t-value +tag-symbol+)
          (word (+ nil-value 2)) (make-value 0 +tag-unbound-value+)
          (word (+ nil-value 3)) (make-value undef-fn +tag-function+)
          (word (+ nil-value 4)) (make-value nil-value +tag-symbol+)
          (word (+ nil-value 5)) (make-fixnum 0))
    (setf (word t-value) (make-value (store-string "T")
                                       +tag-array-like+)
          (word (+ t-value 1)) (make-value t-value +tag-symbol+)
          (word (+ t-value 2)) (make-value 0 +tag-unbound-value+)
          (word (+ t-value 3)) (make-value undef-fn +tag-function+)
          (word (+ t-value 4)) (make-value nil-value +tag-symbol+)
          (word (+ t-value 5)) (make-fixnum 0))
    (format t "NIL at word ~X~%" nil-value)
    (format t "  T at word ~X~%" t-value)
    (format t "UDF at word ~X~%" undef-fn)
    (setf (gethash "NIL" *symbol-table*) nil-value
          (gethash "T" *symbol-table*) t-value
          *undefined-function-address* undef-fn)))

(defun write-image (name description)
  (declare (ignore description))
  (with-open-file (s (format nil "~A.image" name)
                     :direction :output
                     :element-type '(unsigned-byte 8)
                     :if-exists :supersede)
    (dolist (area *area-info*)
      (format t "Writing ~S bytes of area ~S to offset ~D.~%"
              (* (ceiling (first area) #x40000) #x40000 8)
              (first (nth (position area *area-info*) *initial-areas*))
              (file-position s))
      (write-sequence (third area) s :end (* (ceiling (first area) #x40000) #x40000 8)))))

(defun array-header (tag length)
  (logior (ash tag 1)
          (ash length 8)))

(defun pack-halfwords (low high)
  (dpb high (byte 32 32) low))

(defconstant +page-table-present+  #b0000000000001)
(defconstant +page-table-writable+ #b0000000000010)
(defconstant +page-table-user+     #b0000000000100)
(defconstant +page-table-pwt+      #b0000000001000)
(defconstant +page-table-pcd+      #b0000000010000)
(defconstant +page-table-accessed+ #b0000000100000)
(defconstant +page-table-dirty+    #b0000001000000)
(defconstant +page-table-large+    #b0000010000000)
(defconstant +page-table-global+   #b0000100000000)
(defconstant +page-table-pat+      #b1000000000000)

(defun create-page-tables ()
  (let ((pml4 (allocate 512 'page-table-area))
        (data-pml3 (allocate 512 'page-table-area))
        (phys-pml3 (allocate 512 'page-table-area))
        (data-pml2 (allocate (* 512 512) 'page-table-area))
        (phys-pml2 (allocate (* 512 512) 'page-table-area)))
    (format t "PML4 at ~X~%" (* pml4 8))
    (format t "Data PML3 at ~X. PML2s at ~X~%" (* data-pml3 8) (* data-pml2 8))
    (format t "Phys PML3 at ~X. PML2s at ~X~%" (* phys-pml3 8) (* phys-pml2 8))
    (dotimes (i 512)
      ;; Clear PML4.
      (setf (word (+ pml4 i)) 0)
      ;; Link PML3s to PML2s.
      (setf (word (+ data-pml3 i)) (logior (* (+ data-pml2 (* i 512)) 8)
                                           +page-table-present+
                                           +page-table-global+))
      (setf (word (+ phys-pml3 i)) (logior (* (+ phys-pml2 (* i 512)) 8)
                                           +page-table-present+
                                           +page-table-global+))
      (dotimes (j 512)
        ;; Clear the data PML2.
        (setf (word (+ data-pml2 (* i 512) j)) 0)
        ;; Map the physical PML2 to the first 512GB of physical memory.
        (setf (word (+ phys-pml2 (* i 512) j)) (logior (* (+ (* i 512) j) #x200000)
                                                       +page-table-present+
                                                       +page-table-global+
                                                       +page-table-large+))))
    ;; Link the PML4 to the PML3s.
    ;; Data PML3 at 0, physical PML3 at 512GB.
    (setf (word (+ pml4 0)) (logior (* data-pml3 8)
                                    +page-table-present+
                                    +page-table-global+))
    (setf (word (+ pml4 1)) (logior (* phys-pml3 8)
                                    +page-table-present+
                                    +page-table-global+))
    ;; Map each area in. Image is loaded to #x200000.
    (let ((phys #x200000))
      (dolist (area *area-info*)
        (let ((len (ceiling (first area) #x40000))
              (virtual (second area)))
          (dotimes (i len)
            (setf (word (+ data-pml2 virtual i)) (logior phys
                                                         +page-table-present+
                                                         +page-table-global+
                                                         +page-table-large+))
            (incf phys #x200000)))))
    (* pml4 8)))

(defun create-initial-stack-group ()
  (let* ((address (allocate 512 'support-area))
         (control-stack-size 4096)
         (control-stack (allocate-stack control-stack-size :control))
         (data-stack-size 1024)
         (data-stack (allocate-stack data-stack-size :data))
         (binding-stack-size 1024)
         (binding-stack (allocate-stack binding-stack-size :binding)))
    ;; Array tag.
    (setf (word (+ address 0)) (array-header +array-type-stack-group+ 511))
    ;; Binding stack pointer.
    (setf (word (+ address 1)) (make-fixnum (+ binding-stack binding-stack-size)))
    ;; State word. Unsafe, active.
    (setf (word (+ address 2)) (make-fixnum 0))
    ;; Saved control stack pointer.
    (setf (word (+ address 3)) (make-fixnum (+ control-stack control-stack-size)))
    ;; Name.
    (setf (word (+ address 4)) (make-value (store-string "Initial stack group") +tag-array-like+))
    ;; Control stack base.
    (setf (word (+ address 5)) (make-fixnum control-stack))
    ;; Control stack size.
    (setf (word (+ address 6)) (make-fixnum control-stack-size))
    ;; Data stack base.
    (setf (word (+ address 7)) (make-fixnum data-stack))
    ;; Data stack size.
    (setf (word (+ address 8)) (make-fixnum data-stack-size))
    ;; Binding stack base.
    (setf (word (+ address 9)) (make-fixnum binding-stack))
    ;; Binding stack size.
    (setf (word (+ address 10)) (make-fixnum binding-stack-size))
    ;; Resumer.
    (setf (word (+ address 12)) (make-value (symbol-address "NIL" nil) +tag-symbol+))
    ;; Start of TLS slots.
    (dotimes (i (- 512 13))
      (setf (word (+ address 13 i)) #xFFFFFFFFFFFFFFFE))
    (setf (word (+ (symbol-address "*INITIAL-STACK-GROUP*" nil) 2))
          (make-value address +tag-array-like+))))

(defun make-image (image-name &optional description extra-source-files)
  (let ((*area-info* (create-area-info *initial-areas*))
        (*pending-fixups* '())
        (*symbol-table* (make-hash-table :test 'equal))
        (*keyword-table* (make-hash-table :test 'equal))
        (*undefined-function-address* nil)
        (*load-time-evals* '())
        (setup-fn nil)
        (gdt nil)
        (idt nil)
        (multiboot nil)
        (initial-stack nil)
        (initial-pml4))
    (create-support-objects)
    (create-initial-stack-group)
    (load-source-files *source-files*)
    (load-source-files extra-source-files)
    ;; Create GDT.
    (setf gdt (allocate 3 'support-area)
          (word gdt) (array-header +array-type-unsigned-byte-64+ 2)
          (word (+ gdt 1)) 0
          (word (+ gdt 2)) #x00209A0000000000)
    ;; Create IDT.
    (setf idt (allocate 257 'support-area)
          (word idt) (array-header +array-type-unsigned-byte-64+ 256))
    (dotimes (i 256)
      (setf (word (1+ idt)) 0))
    ;; Create the setup stack.
    (setf initial-stack (allocate 8 'support-area)
          (word initial-stack) (array-header +array-type-unsigned-byte-64+ 7))
    ;; Generate page tables.
    (setf initial-pml4 (create-page-tables))
    ;; Create setup function.
    (setf setup-fn (compile-lap-function *setup-function* 'support-area
                                         (list (cons 'gdt (* (1+ gdt) 8))
                                               (cons 'gdt-length (1- (* 2 8)))
                                               (cons 'idt (* (1+ idt) 8))
                                               (cons 'idt-length (1- (* 256 8)))
                                               (cons 'initial-stack (* (+ initial-stack 8) 8))
                                               (cons 'initial-page-table initial-pml4))))
    ;; Create multiboot header.
    (setf multiboot (allocate 5 'support-area)
          (word multiboot) (array-header +array-type-unsigned-byte-32+ 8)
          (word (+ multiboot 1)) (pack-halfwords #x1BADB002 #x00010003)
          (word (+ multiboot 2)) (pack-halfwords (ldb (byte 32 0) (- (+ #x1BADB002 #x00010003)))
                                                 (* (1+ multiboot) 8))
          (word (+ multiboot 3)) (pack-halfwords #x200000 0)
          (word (+ multiboot 4)) (pack-halfwords 0 (make-value setup-fn +tag-function+)))
    (format t "Entry point at ~X~%" (make-value setup-fn +tag-function+))
    (apply-fixups *pending-fixups*)
    (write-image image-name description)))

(defun load-source-files (files)
  (mapc 'load-source-file files))

(defconstant +llf-end-of-load+ #xFF)
(defconstant +llf-backlink+ #x01)
(defconstant +llf-function+ #x02)
(defconstant +llf-cons+ #x03)
(defconstant +llf-symbol+ #x04)
(defconstant +llf-uninterned-symbol+ #x05)
(defconstant +llf-unbound+ #x06)
(defconstant +llf-string+ #x07)
(defconstant +llf-setf-symbol+ #x08)
(defconstant +llf-integer+ #x09)
(defconstant +llf-invoke+ #x0A)
(defconstant +llf-setf-fdefinition+ #x0B)
(defconstant +llf-simple-vector+ #x0C)
(defconstant +llf-character+ #x0D)
(defconstant +llf-structure-definition+ #x0E)
(defconstant +llf-single-float+ #x10)

;;; Mostly duplicated from the file compiler...
(defun load-integer (stream)
  (let ((value 0) (shift 0))
    (loop
         (let ((b (read-byte stream)))
           (when (not (logtest b #x80))
             (setf value (logior value (ash (logand b #x3F) shift)))
             (if (logtest b #x40)
                 (return (- value))
                 (return value)))
           (setf value (logior value (ash (logand b #x7F) shift)))
           (incf shift 7)))))

(defun utf8-sequence-length (byte)
  (cond
    ((eql (logand byte #x80) #x00)
     (values 1 byte))
    ((eql (logand byte #xE0) #xC0)
     (values 2 (logand byte #x1F)))
    ((eql (logand byte #xF0) #xE0)
     (values 3 (logand byte #x0F)))
    ((eql (logand byte #xF8) #xF0)
     (values 4 (logand byte #x07)))
    (t (error "Invalid UTF-8 lead byte ~S." byte))))

(defun load-character (stream)
  (multiple-value-bind (length value)
      (utf8-sequence-length (read-byte stream))
    ;; Read remaining bytes. They must all be continuation bytes.
    (dotimes (i (1- length))
      (let ((byte (read-byte stream)))
        (unless (eql (logand byte #xC0) #x80)
          (error "Invalid UTF-8 continuation byte ~S." byte))
        (setf value (logior (ash value 6) (logand byte #x3F)))))
    value))

(defun load-ub8-vector (stream)
  (let* ((len (load-integer stream))
         (seq (make-array len :element-type '(unsigned-byte 8))))
    (read-sequence seq stream)
    seq))

(defun load-vector (stream omap)
  (let* ((len (load-integer stream))
         (address (allocate (1+ len))))
    ;; Header word.
    (setf (word address) (logior (ash len 8) (ash +array-type-t+ 1)))
    (dotimes (i len)
      (setf (word (+ address i)) (load-object stream omap)))
    (make-value address +tag-array-like+)))

(defun load-string (stream)
  (let* ((len (load-integer stream))
         (address (allocate (1+ (ceiling len 2)))))
    ;; Header word.
    (setf (word address) (logior (ash len 8) (ash +array-type-character+ 1)))
    (dotimes (i (ceiling len 2))
      (let ((value 0))
        (dotimes (j 2)
          (when (< (+ (* i 2) j) len)
            (setf (ldb (byte 32 64) value) (load-character stream)))
          (setf value (ash value -32)))
        (setf (word (+ address 1 i)) value)))
    (make-value address +tag-array-like+)))

(defun load-string* (stream)
  (let* ((len (load-integer stream))
         (seq (make-array len :element-type 'character)))
    (dotimes (i len)
      (setf (aref seq i) (code-char (load-character stream))))
    seq))

(defun llf-next-is-unbound-p (stream)
  (let ((current-position (file-position stream)))
    (cond ((eql (read-byte stream) +llf-unbound+)
           t)
          (t (file-position stream current-position)
             nil))))

(defun extract-array (address element-width)
  (let* ((size (ldb (byte 56 8) (word address)))
         (array (make-array size))
         (elements-per-word (/ 64 element-width)))
    (dotimes (i size)
      (multiple-value-bind (word offset)
          (truncate i elements-per-word)
        (setf (aref array i) (ldb (byte element-width (* offset element-width))
                                  (word (+ address 1 word))))))
    array))

(defun extract-object (value)
  (let ((address (pointer-part value)))
    (ecase (tag-part value)
      (#.+tag-symbol+
       (let ((name (extract-object (word address)))
             (package (word (+ address 1))))
         (when (eql package (make-value (symbol-address "NIL" nil) +tag-symbol+))
           (error "Attemping to extract an uninterned symbol."))
         (intern name '#:cold-generator)))
      (#.+tag-array-like+
       (ecase (ldb (byte 6 1) (word address))
         (#.+array-type-base-char+
          (map 'simple-string 'code-char (extract-array address 8)))
         (#.+array-type-character+
          (map 'simple-string 'code-char (extract-array address 32))))))))

(defun load-object-in-host (stream omap)
  (extract-object (load-object stream omap)))

(defun load-one-object (command stream omap)
  (ecase command
    (#.+llf-function+
     (let* ((tag (read-byte stream))
            (mc-length (load-integer stream))
            (mc-position (file-position stream))
            (fixups (progn (file-position stream (+ mc-position mc-length))
                           (load-object-in-host stream omap)))
            (constants-length (load-integer stream))
            (constants-position (file-position stream))
            (total-size (+ (* (ceiling (+ mc-length 12) 16) 2)
                           constants-length))
            (address (allocate total-size 'function-area)))
       ;; Copy machine code bytes.
       (file-position stream (- mc-position 4))
       (dotimes (i (ceiling (+ mc-length 4) 8))
         (let ((value 0))
           (dotimes (j 8)
             (when (< (+ (* i 8) j) (+ mc-length 4))
               (setf (ldb (byte 8 64) value) (read-byte stream)))
             (setf value (ash value -8)))
           (setf (word (+ address 1 i)) value)))
       ;; Set function header.
       (setf (word address) 0)
       (setf (ldb (byte 16 0) (word address)) tag
             (ldb (byte 16 16) (word address)) (ceiling (+ mc-length 12) 16)
             (ldb (byte 16 32) (word address)) constants-length)
       ;; Set constant pool.
       (file-position stream constants-position)
       (dotimes (i constants-length)
         (setf (word (+ address (* (ceiling (+ mc-length 12) 16) 2) i)) (load-object stream omap)))
       ;; Add fixups to the list.
       (dolist (fixup fixups)
         (push (list (car fixup) address (cdr fixup) :signed32)
               *pending-fixups*))
       (make-value address +tag-function+)))
    (#.+llf-cons+
     (let* ((cdr (load-object stream omap))
            (car (load-object stream omap))
            (address (allocate 2)))
       (setf (word address) car
             (word (1+ address)) cdr)
       (make-value address +tag-cons+)))
    (#.+llf-symbol+
     (let* ((name (load-string* stream))
            (package (load-string* stream)))
       (make-value (symbol-address name (string= package "KEYWORDP"))
                   +tag-symbol+)))
    (#.+llf-uninterned-symbol+
     (let* ((name (load-string* stream))
            (address (allocate 6)))
       (setf (word address) (make-value (store-string name) +tag-array-like+)
             (word (+ address 1)) (make-value (symbol-address "NIL" nil) +tag-symbol+)
             (word (+ address 2)) (if (llf-next-is-unbound-p stream)
                                      (make-value 0 +tag-unbound-value+)
                                      (load-object stream omap))
             (word (+ address 3)) (if (llf-next-is-unbound-p stream)
                                      (make-value *undefined-function-address* +tag-function+)
                                      (load-object stream omap))
             (word (+ address 4)) (load-object stream omap)
             (word (+ address 5)) (make-fixnum 0))
       (make-value address +tag-symbol+)))
    #+nil(#.+llf-string+ (load-string stream))
    #+nil(#.+llf-setf-symbol+
     (let ((symbol (load-object stream omap)))
       (function-symbol `(setf ,symbol))))
    (#.+llf-integer+ (make-fixnum (load-integer stream)))
    #+nil(#.+llf-simple-vector+ (load-vector stream omap))
    (#.+llf-character+ (make-value (load-character stream)
                                   +tag-character+))
    #+nil(#.+llf-structure-definition+
     (make-struct-type (load-object stream omap)
                       (load-object stream omap)))
    (#.+llf-single-float+
     (logior (ash (load-integer stream) 32)
             +tag-single-float+))))

(defun load-object (stream omap)
  (let ((command (read-byte stream)))
    (case command
      (#.+llf-end-of-load+
       (values nil t))
      (#.+llf-backlink+
       (let ((id (load-integer stream)))
         (assert (< id (hash-table-count omap)) () "Object id ~S out of bounds." id)
         (values (gethash id omap) nil)))
      (#.+llf-invoke+
       (let ((fn (load-object stream omap)))
         (push fn *load-time-evals*)
         (values fn nil)))
      (#.+llf-setf-fdefinition+
       (let* ((fn-value (load-object stream omap))
              (base-name (load-object stream omap))
              (name (resolve-function-name base-name)))
         (format t "Setting (fdefinition ~X) to ~X~%" name fn-value)
         (setf (word (+ (pointer-part name) 3)) fn-value)))
      (#.+llf-unbound+ (error "Should not seen UNBOUND here."))
      (t (let ((id (hash-table-count omap)))
           (setf (gethash id omap) '"!!!LOAD PLACEHOLDER!!!")
           (let ((obj (load-one-object command stream omap)))
             (setf (gethash id omap) obj)
             (values obj nil)))))))

(defun resolve-function-name (value)
  (let ((name (extract-object value)))
    (cond ((symbolp name)
           (format t "Resolved function ~S to ~S~%" name value)
           value)
          (t (error "TODO: setf symbols.")))))

(defun load-source-file (file)
  (let ((llf-path (merge-pathnames (make-pathname :type "llf" :defaults file)))
        (omap (make-hash-table)))
    (when (not (probe-file llf-path))
      (error "Compiled file of ~S does not exist." file))
    (when (<= (file-write-date llf-path) (file-write-date file))
      (warn "~S is out of date and should be recompiled." file))
    (format t ";; Loading ~S.~%" llf-path)
    (with-open-file (s llf-path :element-type '(unsigned-byte 8))
      ;; Check the header.
      (assert (and (eql (read-byte s) #x4C)
                   (eql (read-byte s) #x4C)
                   (eql (read-byte s) #x46)
                   (eql (read-byte s) #x00)))
      ;; Read forms.
      (loop (when (nth-value 1 (load-object s omap))
              (return))))))

(defun apply-fixups (fixups)
  (mapc 'apply-fixup fixups))

(defun apply-fixup (fixup)
  (destructuring-bind (what address byte-offset type) fixup
    (let* ((value (if (consp what)
                      (make-value (symbol-address (symbol-name (second what))
                                                    (keywordp (second what))
                                                    t)
                                    +tag-symbol+)
                      (ecase what
                        ((nil t) (make-value (symbol-address (symbol-name what) nil)
                                               +tag-symbol+))
                        (:undefined-function (make-value *undefined-function-address*
                                                           +tag-function+)))))
           (length (ecase type
                     (:signed32 (check-type value (signed-byte 32))
                                4)
                     (:full64 (check-type value (unsigned-byte 64))
                              8))))
      (dotimes (byte length)
        (multiple-value-bind (word byten)
            (truncate (+ byte-offset byte) 8)
          (setf (ldb (byte 8 (* byten 8)) (word (+ address word)))
                (ldb (byte 8 (* byte 8)) value)))))))
