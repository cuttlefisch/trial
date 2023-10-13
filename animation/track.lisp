(in-package #:org.shirakumo.fraf.trial)

(defstruct (animation-frame
            (:constructor make-frame (time curve)))
  (time 0.0 :type single-float)
  (curve NIL :type (function (T single-float) T)))

(defmethod print-object ((frame animation-frame) stream)
  (print-unreadable-object (frame stream :type T)
    (format stream "~a" (animation-frame-time frame))))

(defclass animation-track (sequences:sequence standard-object)
  ((name :initarg :name :initform NIL :accessor name)
   (frames :initform #() :accessor frames)
   (interpolation :initarg :interpolation :initform :linear :accessor interpolation)))

(defmethod shared-initialize :after ((track animation-track) slots &key times values frames)
  (cond ((and times values)
         (setf (frames track) (cons times values)))
        (frames
         (setf (frames track) frames))))

(defmethod print-object ((track animation-track) stream)
  (print-unreadable-object (track stream :type T)
    (if (valid-p track)
        (format stream "~a ~a" (start-time track) (end-time track))
        (format stream "INVALID"))))

(defgeneric start-time (track))
(defgeneric end-time (track))
(defgeneric duration (track))
(defgeneric sample (target track time &key))
(defgeneric find-frame-idx (track time loop-p))

(defmethod (setf frames) ((keyframes cons) (track animation-track))
  (destructuring-bind (times . values) keyframes
    (let ((frames (make-array (length times)))
          (j 0))
      (dotimes (i (length times))
        (setf (aref frames i)
              (make-frame (elt times i)
                          (ecase (interpolation track)
                            (:constant
                             (incf j)
                             (constant (elt values (1- j))))
                            (:linear
                             (incf j)
                             (linear (elt values (1- j)) (elt values j)))
                            (:hermite
                             (incf j 3)
                             (hermite (elt values (- j 2)) (elt values (- j 1))
                                      (elt values (+ j 1)) (elt values (+ j 0))))
                            (:bezier
                             ;; DATA is ordered like this: i0 v0 o0 i1 v1 o1
                             (incf j 3)
                             (bezier (elt values (- j 2)) (elt values (- j 1))
                                     (elt values (+ j 1)) (elt values (+ j 0))))
                            (:custom
                             (incf j)
                             (elt values (1- j)))))))
      (setf (frames track) frames))))

(declaim (ftype (function (animation-track single-float boolean) single-float) fit-to-track))
(declaim (inline fit-to-track))
(defun fit-to-track (track time loop-p)
  (declare (optimize speed (safety 0)))
  (let ((frames (frames track)))
    (declare (type simple-vector frames))
    (declare (type single-float time))
    (if (<= (length frames) 1)
        0.0
        (let ((start (animation-frame-time (svref frames 0)))
              (end (animation-frame-time (svref frames (1- (length frames))))))
          (if loop-p
              (+ start (mod (- time start) (- end start)))
              (clamp start time end))))))

(defmethod valid-p ((track animation-track))
  (< 1 (length (frames track))))

(defmethod start-time ((track animation-track))
  (animation-frame-time (svref (frames track) 0)))

(defmethod end-time ((track animation-track))
  (animation-frame-time (svref (frames track) (1- (length (frames track))))))

(defmethod duration ((track animation-track))
  (let ((frames (frames track)))
    (- (animation-frame-time (svref (frames track) (1- (length frames))))
       (animation-frame-time (svref (frames track) 0)))))

(defmethod sequences:adjust-sequence ((track animation-track) length &rest args)
  (setf (frames track) (apply #'adjust-array (frames track) length args))
  track)

(defmethod sequences:length ((track animation-track))
  (length (frames track)))

(defmethod sequences:elt ((track animation-track) index)
  (svref (frames track) index))

(defmethod (setf sequences:elt) (value (track animation-track) index)
  (setf (svref (frames track) index) value))

(defmethod find-frame-idx ((track animation-track) x loop-p)
  (let ((x (fit-to-track track x loop-p))
        (frames (frames track)))
    (loop for i from 0 below (length frames)
          do (when (<= x (animation-frame-time (svref frames i)))
               (return (1- i)))
          finally (return (1- (length frames))))))

(defmethod sample (target (track animation-track) time &key loop-p)
  (declare (optimize speed))
  (let ((frames (frames track))
        (i (find-frame-idx track time loop-p)))
    (declare (type (signed-byte 31) i))
    (declare (type single-float time))
    (if (< i 0)
        (funcall (animation-frame-curve (svref frames 0)) target 0.0)
        (let* ((l (svref frames i))
               (r (svref frames (1+ i)))
               (x (/ (- time (animation-frame-time l))
                     (- (animation-frame-time r) (animation-frame-time l)))))
          (funcall (animation-frame-curve l) target x)))))

(defclass fast-animation-track (animation-track)
  ((sampled-frames :initform (make-array 0 :element-type '(unsigned-byte 32)) :accessor sampled-frames)
   (sample-rate :initform 60.0 :initarg :sample-rate :accessor sample-rate)
   (duration :initform 0f0 :accessor duration)))

(defmethod update-instance-for-different-class :after ((current animation-track) (new fast-animation-track) &key)
  (setf (sampled-frames new) (generate-index-lookup-table new)))

(defun generate-index-lookup-table (track)
  (declare (optimize speed))
  (let* ((frames (frames track))
         (frame-count (length frames)))
    (declare (type simple-vector frames))
    (when (< 1 frame-count)
      (let* ((rate (sample-rate track))
             (duration (- (animation-frame-time (svref frames (1- frame-count)))
                          (animation-frame-time (svref frames 0))))
             (samples (truncate (+ rate (* rate duration))))
             (sampled (make-array samples :element-type '(unsigned-byte 32)))
             (dt (/ duration (float (1- samples) 0f0)))
             (time (start-time track)))
        (declare (type single-float rate duration dt time))
        (setf (duration track) duration)
        (dotimes (i samples sampled)
          (let ((frame-index 0))
            (loop for j downfrom (1- frame-count) to 0
                  for frame = (svref frames j)
                  do (when (<= (animation-frame-time frame) time)
                       (setf frame-index j)
                       (when (<= (- frame-count 2) frame-index)
                         (setf frame-index (- frame-count 2)))
                       (return)))
            (setf (aref sampled i) frame-index))
          (incf time dt))))))

(defmethod (setf sequences:elt) :after (value (track fast-animation-track) index)
  (setf (sampled-frames track) (generate-index-lookup-table track)))

(defmethod (setf frames) :after (value (track fast-animation-track))
  (setf (sampled-frames track) (generate-index-lookup-table track)))

(defmethod find-frame-idx ((track fast-animation-track) time loop-p)
  (declare (optimize speed))
  (let* ((frames (frames track))
         (size (length frames))
         (time1 time))
    (declare (simple-array frames))
    (if (< 1 size)
        (let* ((rate (sample-rate track))
               (time (fit-to-track track time loop-p))
               (duration (duration track))
               (samples (truncate (+ rate (* duration rate))))
               (time (/ time duration))
               (index (truncate (* time (1- samples))))
               (sampled (sampled-frames track)))
          (declare (type single-float rate time duration))
          (declare (type (simple-array (unsigned-byte 32) (*)) sampled))
          (declare (type (unsigned-byte 32) index samples))
          (if (< index (length sampled))
              (loop with l = (1- (length frames))
                    for r from (aref sampled index)
                    while (and (< r l)
                               (< (animation-frame-time (svref frames (1+ r)))
                                  time1))
                    do (incf index)
                    finally (return r))
              -1))
        -1)))

(defclass transform-track ()
  ((name :initarg :name :initform NIL :accessor name)
   (location :initform (make-instance 'fast-animation-track) :accessor location)
   (scaling :initform (make-instance 'fast-animation-track) :accessor scaling)
   (rotation :initform (make-instance 'fast-animation-track) :accessor rotation)))

(defmethod print-object ((track transform-track) stream)
  (print-unreadable-object (track stream :type T)
    (if (valid-p track)
        (format stream "~s ~a ~a" (name track)
                (start-time track)
                (end-time track))
        (format stream "~s INVALID" (name track)))))

(defmethod start-time ((track transform-track))
  (let ((min most-positive-single-float))
    (flet ((try (track)
             (when (valid-p track)
               (setf min (min min (start-time track))))))
      (try (location track))
      (try (scaling track))
      (try (rotation track))
      (if (= min most-positive-single-float)
          0.0 min))))

(defmethod end-time ((track transform-track))
  (let ((max most-negative-single-float))
    (flet ((try (track)
             (when (valid-p track)
               (setf max (max max (end-time track))))))
      (try (location track))
      (try (scaling track))
      (try (rotation track))
      (if (= max most-negative-single-float)
          0.0 max))))

(defmethod sample ((transform transform) (track transform-track) time &key loop-p)
  (declare (type single-float time))
  (declare (optimize speed))
  (when (< 1 (length (location track)))
    (sample (tlocation transform) (location track) time :loop-p loop-p))
  (when (< 1 (length (scaling track)))
    (sample (tscaling transform) (scaling track) time :loop-p loop-p))
  (when (< 1 (length (rotation track)))
    (sample (trotation transform) (rotation track) time :loop-p loop-p))
  transform)

(defmethod valid-p ((track transform-track))
  (or (< 1 (length (location track)))
      (< 1 (length (scaling track)))
      (< 1 (length (rotation track)))))
