;;;; Copyright (c) Frank James 2015 <frank.a.james@gmail.com>
;;;; This code is licensed under the MIT license.

;;; This file defines the shared database used to store records.

(in-package #:dragons)

(defvar *db* nil)
(defvar *database-path* (merge-pathnames "dragons.dat" (user-homedir-pathname)))

;; FIXME: this is not guaranteed to be large enough to hold a record. 
;; names can be up to 255 characters, the record itself larger still.
;; Reserving e.g. 1k per entry seems excessive (or is it?)
;; Otherwise we'd need to be able to store variable length records, which is a pain.
(defconstant +block-size+ 1024)
(defconstant +block-data+ 1016)

;; each record is:
;; expiry uint64
;; rr

(defun encode-record (stream val)
  (let ((blk (xdr-block +block-data+)))
    (destructuring-bind (rr expiration) val
      (setf (nibbles:ub64ref/be (xdr-block-buffer blk)
				      0)
	    expiration)
      (incf (xdr-block-offset blk) 8)
      (let ((*pointer-offsets* nil))
	(declare (special *pointer-offsets*))
	(encode-rr blk rr)))
    (write-sequence (xdr-block-buffer blk) stream
		    :end (xdr-block-offset blk))))

(defun decode-record (stream)
  (let ((blk (xdr-block +block-data+)))
    (read-sequence (xdr-block-buffer blk) stream)    
    (let ((expiry (nibbles:ub64ref/be (xdr-block-buffer blk) 0)))
      (incf (xdr-block-offset blk) 8)
      (let ((rr (decode-rr blk)))
	(list rr expiry)))))

(defun close-dn-db ()
  (when *db* 
    (pounds.db:close-db *db*)
    (setf *db* nil)))

(defun open-dn-db (&optional (count 32))
  (unless *db*
    (setf *db* (pounds.db:open-db *database-path* 
                                  #'decode-record
                                  #'encode-record
                                  :count count
                                  :block-size +block-size+))))

(defun rr-eql (r1 r2)
  (declare (type rr r1 r2))
  (and (eq (rr-type r1) (rr-type r2))
       (eq (rr-class r1) (rr-class r2))
       (string-equal (rr-name r1) (rr-name r2))))

(defun add-record (rr &optional expiration)
  (open-dn-db)
  (setf (pounds.db:find-entry rr *db*
                              :test (lambda (x y) (declare (ignore x y)) nil) ;; #'rr-eql
                              :key #'car)
        (list rr (or expiration #xffffffffffffffff))))

(defun insert-record (name rdata &optional (type :a) (ttl 300) (class :in))
  "Insert a static record into the database."
  (open-dn-db)
  (add-record (make-rr :name name
                       :type type
                       :class class
                       :ttl ttl
                       :rdata rdata)
              #xffffffffffffffff))

(defun remove-record (name &optional (type :a) (class :in))
  (open-dn-db)
  (pounds.db:remove-entry (make-rr :name name
				   :type type
				   :class class)
			  *db*
			  :test #'rr-eql
			  :key #'car))

;; we define our own wrapper to iterate over the entries to ensure we delete
;; those entries once they have expired.
(defmacro dorecords ((var) &body body)
  (alexandria:with-gensyms (gnow gvar)
    `(let ((,gnow (get-universal-time)))
       (pounds.db:doentries (,gvar *db*)
         (if (< (cadr ,gvar) ,gnow)
             (pounds.db:clear-entry)
             (let ((,var (car ,gvar)))
               ,@body))))))

(defun find-record (rr)
  (declare (type rr rr))
  (open-dn-db)
  (dorecords (entry)
    (when (and entry (rr-eql entry rr))
      (return-from find-record entry))))

(defun list-records ()
  (open-dn-db)
  (let (entries)
    (dorecords (entry)
      (when entry 
        (push entry entries)))
    entries))

(defun purge-records (&optional age)
  (open-dn-db)
  (let ((purge-age (+ (get-universal-time) (or age 0))))
    (pounds.db:doentries (entry *db*)
      (when (< (cadr entry) purge-age)
        (pounds.db:clear-entry)))))
