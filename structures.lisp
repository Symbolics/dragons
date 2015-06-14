

(in-package #:dragons)


;; -------------------------

(defun encode-string (string stream)
  (let ((len (length string)))
    (write-byte len stream)
    (write-sequence (babel:string-to-octets string) stream)))

(defun decode-string (stream)
  (let ((len (read-byte stream)))
    (let ((v (nibbles:make-octet-vector len)))
      (read-sequence v stream)
      (babel:octets-to-string v))))

;; -------------------------

(defparameter *resolve-pointer-hook* nil
  "This should be bound to a function accepting a single parameter, offset, which is the offset back into the original buffer
and should return the name pointed to by that offset, i.e. it should call decode-name at that point.")

(defun encode-label (string stream)
  (encode-string string stream))

(defun decode-label (stream)
  (let ((len (read-byte stream)))
    (cond
      ((= len 0) (values nil nil))
      ((<= len 63)
       (let ((v (nibbles:make-octet-vector len)))
	 (read-sequence v stream)
	 (values (babel:octets-to-string v) 
		 nil)))
      (t       
       ;; this is a pointer, call into the hook to decode the name 
       (let ((offset (logior (ash (logand len 63) 8)
			     (read-byte stream))))
	 (values (funcall *resolve-pointer-hook* offset)
		 t))))))
      
;; -------------------------

(defun encode-name (name stream)
  "Encode a dotted string name as a list of labels to the stream."
  (do ((pos 0))
      ((>= pos (length name))
       (encode-label "" stream))
    (let ((p (position #\. name :test #'char= :start pos)))
      (cond
	(p
	 (encode-label (subseq name pos p) stream)
	 (setf pos (1+ p)))
	(t 
	 (encode-label (subseq name pos) stream)
	 (setf pos (length name)))))))


(defun decode-name (stream)
  "Decode a list of labels from the stream. Returns a dotted string."
  (with-output-to-string (s)
    (do ((done nil)
	 (first t))
	(done)
      (multiple-value-bind (label pointer) (decode-label stream)
	(when pointer (setf done t))
	(cond
	  ((null label) (setf done t))
	  ((string= label "")
	   (setf done t))
	  (t 
	   (unless first (write-char #\. s))
	   (setf first nil)
	   (write-string label s)))))))

;; -------------------------


(defparameter *type-codes*
  '((:a 1)
    (:ns 2)
    (:cname 5)
    (:soa 6)
    (:mb 7)
    (:mg 8)
    (:mr 9)
    (:null 10)
    (:wks 11)
    (:ptr 12)
    (:hinfo 13)
    (:minfo 14)
    (:mx 15)
    (:txt 16)
    (:srv 33)
    (:axfr 252)
    (:mailb 253)
    (:maila 254)
    (:all 255)))

(defparameter *class-codes*
  '((:in 1) ;; internet 
    (:ch 3) ;; CHAOS
    (:hs 4))) ;; HESIOD ??

;; ----------------------------

(defgeneric encode-rdata (type data stream)
  (:documentation "Encode a object of specified type to the stream. TYPE should be a keyword in *TYPE-CODES*."))
(defgeneric decode-rdata (type stream)
  (:documentation "Decode an object of specified type from the stream. The stream contains all the data for the object,
so you may read until EOF to extract all the information."))

;; default methods leave data untouched and assume the data is just a vector
(defmethod encode-rdata (type data stream)
  (write-sequence data stream))
(defmethod decode-rdata (type stream)
  ;; read until eof
  (flexi-streams:with-output-to-sequence (s)
    (do ((b (read-byte stream nil nil) (read-byte stream nil nil)))
	((null b))
      (write-byte b s))))

;; ------- cname -----

(defmethod encode-rdata ((type (eql :cname)) data stream)
  (encode-name data stream))

(defmethod decode-rdata ((type (eql :cname)) stream)
  (decode-name stream))

;; -------- hinfo -----

(defmethod encode-rdata ((type (eql :hinfo)) data stream)
  (let ((cpu (getf data :cpu))
	(os (getf data :os)))
    (encode-string cpu stream)
    (encode-string os stream)))

(defmethod decode-rdata ((type (eql :hinfo)) stream)
  (let ((cpu (decode-string stream))
	(os (decode-string stream)))
    (list :cpu cpu :os os)))

;; ----------- madname --------

(defmethod encode-rdata ((type (eql :mb)) data stream)
  (encode-name data stream))

(defmethod decode-rdata ((type (eql :mb)) stream)
  (decode-name stream))

;; ---------- a -------------

;; address.
(defmethod encode-rdata ((type (eql :a)) data stream)
  (write-sequence 
   (etypecase data
     (string (usocket:dotted-quad-to-vector-quad data))
     (vector data))
   stream))

;; don't provide a method for decoding Address types because it's just a vector which is the same as the default method

;; ----------- ns -----------------

(defmethod encode-rdata ((type (eql :ns)) data stream)
  (encode-name data stream))

(defmethod decode-rdata ((type (eql :ns)) stream)
  (decode-name stream))

;; ----------- txt ----------------

(defmethod encode-rdata ((type (eql :txt)) data stream)
  (encode-string data stream))

(defmethod decode-rdata ((type (eql :txt)) stream)
  (decode-string stream))

;; ------------- srv ----------------

(defmethod encode-rdata ((type (eql :srv)) data stream)
  (let ((priority (getf data :priority))
	(weight (getf data :weight))
	(port (getf data :port))
	(target (getf data :target)))
    (nibbles:write-ub16/be priority stream)
    (nibbles:write-ub16/be weight stream)
    (nibbles:write-ub16/be port stream)
    (encode-name target stream)))

(defmethod decode-rdata ((type (eql :srv)) stream)
  (let ((priority (nibbles:read-ub16/be stream))
	(weight (nibbles:read-ub16/be stream))
	(port (nibbles:read-ub16/be stream))
	(target (decode-name stream)))
    (list :priority priority
	  :weight weight
	  :port port
	  :target target)))

;; --------------------------------------------

;; resource record structure 
(defstruct rr 
  name type class ttl rdata)

(defun encode-rr (stream rr)
  (let ((name (rr-name rr))
	(type (rr-type rr))
	(class (rr-class rr))
	(ttl (rr-ttl rr))
	(rdata (rr-rdata rr)))
    ;; name
    (encode-name name stream)
    ;; type
    (nibbles:write-ub16/be (or (cadr (assoc type *type-codes*))
			       (error "Unknown TYPE ~A" type))
			   stream)
    ;; class
    (nibbles:write-ub16/be (cadr (assoc class *class-codes*)) stream)
    ;; ttl
    (nibbles:write-sb32/be ttl stream)
    ;; rdlength 
    (nibbles:write-ub16/be (length rdata) stream)
    ;; rdata
    (encode-rdata type rdata stream)))

(defun decode-rr (stream)
  (let* ((name (decode-name stream))
	 (type (nibbles:read-ub16/be stream))
	 (class (nibbles:read-ub16/be stream))
	 (ttl (nibbles:read-sb32/be stream)))
    (let ((len (nibbles:read-ub16/be stream))
	  (tname (car (find type *type-codes*
			    :key #'cadr :test #'=))))
      (let ((v (nibbles:make-octet-vector len)))
	(read-sequence v stream)
	(flexi-streams:with-input-from-sequence (s v)
	  (make-rr :name name
		   :type tname
		   :class (car (find class *class-codes*
				     :key #'cadr :test #'=))
		   :ttl ttl
		   :rdata (decode-rdata tname s)))))))

;;; -----------------------------


(defstruct header 
  id qr opcode rcode qcount acount ncount rcount)

(defun encode-header (stream header)
  (nibbles:write-ub16/be (header-id header) stream)
  (nibbles:write-ub16/be (logior (ecase (header-qr header)
				   (:query 0)
				   (:reply (ash 1 15)))
				 (ash (ecase (header-opcode header)
					(:query 0)
					(:iquery 1)
					(:status 2))
				      11)
				 (ecase (header-rcode header)
				   (:ok 0)
				   (:format-error 1)
				   (:server-failure 2)
				   (:name-error 3)
				   (:not-implemented 4)
				   (:refused 5)))
			 stream)
  (nibbles:write-ub16/be (header-qcount header) stream)
  (nibbles:write-ub16/be (header-acount header) stream) 
  (nibbles:write-ub16/be (header-ncount header) stream)
  (nibbles:write-ub16/be (header-rcount header) stream))


(defun decode-header (stream)
  (let ((h (make-header)))
    (setf (header-id h) (nibbles:read-ub16/be stream))
    (let ((flags (nibbles:read-ub16/be stream)))
      (if (logtest flags #x8000)
	  (setf (header-qr h) :reply)
	  (setf (header-qr h) :query))
      (setf (header-opcode h)
	    (ecase (logand (ash flags -11) #x3)
	      (0 :query)
	      (1 :iquery)
	      (2 :status)))
      (setf (header-rcode h)
	    (ecase (logand flags #x7)
	      (0 :ok)
	      (1 :format-error)
	      (2 :server-failure)
	      (3 :name-error)
	      (4 :not-implemented)
	      (5 :refused))))
    (setf (header-qcount h) (nibbles:read-ub16/be stream)
	  (header-acount h) (nibbles:read-ub16/be stream)
	  (header-ncount h) (nibbles:read-ub16/be stream)
	  (header-rcount h) (nibbles:read-ub16/be stream))
    h))


;; questions

(defun encode-question (stream question)
  (let ((name (getf question :name))
	(type (getf question :type))
	(class (getf question :class)))
    (encode-name name stream)
    (nibbles:write-ub16/be (cadr (assoc type *type-codes*)) stream)
    (nibbles:write-ub16/be (cadr (assoc class *class-codes*)) stream)))

(defun decode-question (stream)
  (let ((name (decode-name stream))
	(type (nibbles:read-ub16/be stream))
	(class (nibbles:read-ub16/be stream)))
    (list :name name 
	  :type (car (find type *type-codes* :key #'cadr :test #'=))
	  :class (car (find class *class-codes* :key #'cadr :test #'=)))))

(defun question (name &optional (type :a) (class :in))
  "Allocate a question to use with QUERY.

NAME ::= a hostname.
TYPE ::= the type of query.
CLASS ::= the class of query, almost always :IN (internet).
"
  (declare (type string name)
	   (type symbol type class))
  (list :name name :type type :class class))

;; --------------------

;; message

(defstruct message 
  header questions answers authorities additionals)

(defun encode-message (stream message)
  (encode-header stream (message-header message))
  (dolist (q (message-questions message))
    (encode-question stream q))
  (dolist (answer (message-answers message))
    (encode-rr stream answer))
  (dolist (auth (message-authorities message))
    (encode-rr stream auth))
  (dolist (a (message-additionals message))
    (encode-rr stream a)))

(defun decode-message (stream)
  (let ((header (decode-header stream)))
    (make-message :header header
		  :questions 
		  (loop :for i :below (header-qcount header)
		     :collect (decode-question stream))
		  :answers 
		  (loop :for i :below (header-acount header)
		     :collect (decode-rr stream))
		  :authorities 
		  (loop :for i :below (header-ncount header)
		     :collect (decode-rr stream))
		  :additionals 
		  (loop :for i :below (header-rcount header)
		     :collect (decode-rr stream)))))

(defun message (questions &key (qr :query) (opcode :query) (rcode :ok) answers authorities additionals)
  (make-message :header (make-header :opcode opcode
				     :id (random (expt 2 16))
				     :qr qr
				     :rcode rcode
				     :qcount (length questions)
				     :acount (length answers)
				     :ncount (length authorities)
				     :rcount (length additionals))
		:questions questions
		:answers answers
		:authorities authorities
		:additionals additionals))


;; ------------------------------------------

;; for testing purposes only 
;; (defun pack (encoder obj)
;;   (flexi-streams:with-output-to-sequence (s)
;;     (funcall encoder s obj)))

;; (defun unpack (decoder buffer)
;;   (flexi-streams:with-input-from-sequence (s buffer)
;;     (funcall decoder s)))