(in-package #:org.shirakumo.fraf.trial)

(defgeneric intersects-p (a b))
(defgeneric distance (a b))
(defgeneric detect-hits (a b contacts start end))
(defgeneric support-function (primitive local-direction next))

(defmethod distance ((a vec3) (b vec3))
  (vdistance a b))

(defmethod distance ((a vec2) (b vec2))
  (vdistance a b))

(defun detect-hit (a b &optional (hit (make-hit)))
  (let ((array (make-array 1)))
    (declare (dynamic-extent array))
    (setf (aref array 0) hit)
    (let ((count (detect-hits a b array 0 1)))
      (when (< 0 count)
        hit))))

(defmethod intersects-p (a b)
  (let ((hit (make-hit))
        (hits (make-array 1)))
    (declare (dynamic-extent hit hits))
    (setf (aref hits 0) hit)
    (< 0 (detect-hits a b hits 0 1))))

(defmacro define-distance ((a b) &body body)
  (let ((av (intern "A")) (bv (intern "B"))
        (block (gensym "BLOCK")))
    `(progn
       (defmethod distance ((,av ,a) (,bv ,b))
         (block ,block
           ,@body))
       ,@(unless (eql a b)
           `((defmethod distance ((b ,b) (a ,a))
               (block ,block
                 ,@body)))))))

(defmacro define-intersection-test ((a b) &body body)
  (let ((av (intern "A")) (bv (intern "B"))
        (block (gensym "BLOCK")))
    `(progn
       (defmethod intersects-p ((,av ,a) (,bv ,b))
         (block ,block
           ,@body))
       ,@(unless (eql a b)
           `((defmethod intersects-p ((b ,b) (a ,a))
               (block ,block
                 ,@body)))))))

(defmacro define-support-function (type (dir next) &body body)
  `(defmethod support-function ((primitive ,type) ,dir ,next)
     (declare (type vec3 ,dir ,next))
     (declare (optimize speed (safety 1)))
     ,@body))

(defun global-support-function (primitive global-direction next)
  (declare (optimize speed (safety 1)))
  (declare (type primitive primitive))
  (declare (type vec3 global-direction next))
  (let ((local (vec3)))
    (declare (dynamic-extent local))
    (v<- local global-direction)
    (n*m4/3inv (primitive-transform primitive) local)
    (support-function primitive local next)
    (n*m (primitive-transform primitive) next)))

(defun finish-hit (hit a b)
  (declare (type hit hit))
  (declare (type primitive a))
  (declare (optimize speed))
  #-trial-release (when (v= 0 (hit-normal hit)) (error "Hit normal not set correctly."))
  (setf (hit-a hit) (primitive-entity a))
  (setf (hit-b hit) (if (typep b 'primitive) (primitive-entity b) b))
  (multiple-value-bind (static-friction dynamic-friction restitution)
      (material-interaction-properties
       (primitive-material a) (if (typep b 'primitive) (primitive-material b) NIL))
    (setf (hit-static-friction hit) static-friction)
    (setf (hit-dynamic-friction hit) dynamic-friction)
    (setf (hit-restitution hit) restitution)
    hit))

(defmacro define-hit-detector ((a b) &body body)
  (let ((av (intern "A")) (bv (intern "B"))
        (block (gensym "BLOCK")))
    `(progn
       (defmethod detect-hits ((,av ,a) (,bv ,b) hits start end)
         (declare (type (unsigned-byte 32) start end))
         (declare (type simple-vector hits))
         (when (<= end start)
           (return-from detect-hits start))
         (let ((hit (aref hits start)))
           (block ,block
             (flet ((finish-hit ()
                      (finish-hit hit ,av ,bv)
                      (incf start)
                      (if (< start end)
                          (setf hit (aref hits start))
                          (return-from ,block)))
                    (detect-hits (,av ,bv)
                      (setf start (detect-hits ,av ,bv hits start end))))
               (declare (ignorable #'finish-hit #'detect-hits))
               ,@body))
           start))
       ,@(unless (eql a b)
           `((defmethod detect-hits ((a ,b) (b ,a) hits start end)
               (let ((nstart (detect-hits b a hits start end)))
                 ;; Reverse the information to ensure consistency with hit-a/hit-b
                 (loop for i from start below nstart
                       for hit = (aref hits i)
                       do (reverse-hit hit))
                 nstart)))))))

(defparameter *collision-system-indices*
  (replace (make-array 32 :fill-pointer 3)
           '("system-0" "system-1" "system-2")))

(defun normalize-collision-system-name (name)
  (with-output-to-string (out)
    (loop for char across (string name)
          do (case char
               ((#\- #\_ #\/ #\. #\Space)
                (write-char #\- out))
               ((#\' #\"))
               (T
                (write-char (char-downcase char) out))))))

(defun collision-system-idx (system-ish)
  (etypecase system-ish
    (integer
     system-ish)
    ((or string symbol)
     (let* ((name (normalize-collision-system-name system-ish))
            (pos (position name *collision-system-indices* :test #'string=)))
       (unless pos
         (setf pos (length *collision-system-indices*))
         (vector-push name *collision-system-indices*))
       pos))
    (sequence
     (let ((mask 0))
       (sequences:dosequence (system systems mask)
         (setf (ldb (byte 1 (collision-system-idx system)) mask) 1))))))

(defstruct primitive
  (entity NIL :type T)
  (material NIL :type T)
  (local-transform (meye 4) :type mat4)
  (transform (meye 4) :type mat4)
  (global-bounds-cache (%make-global-bounds-cache) :type global-bounds-cache)
  ;; 32-bit mask to designate which systems to interact with.
  (collision-mask 1 :type (unsigned-byte 32)))

(define-transfer primitive primitive-material primitive-local-transform primitive-collision-mask
  (:eval (let ((target (primitive-global-bounds-cache target))
               (source (primitive-global-bounds-cache source)))
           (setf (global-bounds-cache-radius target) (global-bounds-cache-radius source))
           (v<- (global-bounds-cache-location target) (global-bounds-cache-location source))
           (v<- (global-bounds-cache-obb target) (global-bounds-cache-obb source))
           (v<- (global-bounds-cache-aabb target) (global-bounds-cache-aabb source)))))

(declaim (ftype (function (T) (unsigned-byte 32)) collision-mask))
(defmethod collision-mask ((primitive primitive))
  (primitive-collision-mask primitive))

(defmethod (setf collision-mask) ((mask integer) (primitive primitive))
  (setf (primitive-collision-mask primitive) mask))

(defmethod (setf collision-mask) ((systems sequence) (primitive primitive))
  (setf (collision-mask primitive) (collision-system-idx systems))
  systems)

(defmethod global-transform-matrix ((primitive primitive) &optional target)
  (etypecase target
    (null (primitive-transform primitive))
    (mat4 (m<- target (primitive-transform primitive)))))

(defmethod global-bounds-cache ((primitive primitive))
  (primitive-global-bounds-cache primitive))

(defmethod global-location ((primitive primitive) &optional target)
  (global-location (primitive-global-bounds-cache primitive) target))

(defmethod global-orientation ((primitive primitive) &optional (quat (quat)))
  (!qfrom-mat quat (primitive-transform primitive)))

(defmethod global-bsize ((primitive primitive) &optional target)
  (global-bsize (primitive-global-bounds-cache primitive) target))

(defmethod location ((primitive primitive))
  (mcol3 (primitive-local-transform primitive) 3))

(defmethod (setf location) ((vec vec3) (primitive primitive))
  (with-fast-matref (m (primitive-local-transform primitive))
    (setf (m 0 3) (vx3 vec))
    (setf (m 1 3) (vy3 vec))
    (setf (m 2 3) (vz3 vec))
    (invalidate-global-bounds-cache primitive)
    vec))

(defmethod orientation ((primitive primitive))
  (qfrom-mat (primitive-local-transform primitive)))

(defmethod (setf orientation) ((quat quat) (primitive primitive))
  (let ((src (mat3))
        (dst (primitive-local-transform primitive)))
    (declare (dynamic-extent src))
    (qmat quat src)
    (with-fast-matref (s src)
      (with-fast-matref (d dst)
        (setf (d 0 0) (s 0 0) (d 0 1) (s 0 1) (d 0 2) (s 0 2))
        (setf (d 1 0) (s 1 0) (d 1 1) (s 1 1) (d 1 2) (s 1 2))
        (setf (d 2 0) (s 2 0) (d 2 1) (s 2 1) (d 2 2) (s 2 2))))
    (invalidate-global-bounds-cache primitive)
    quat))

(defmethod 3ds:location ((primitive primitive))
  (global-location (primitive-global-bounds-cache primitive)))

(defmethod 3ds:bsize ((primitive primitive))
  (global-bsize (primitive-global-bounds-cache primitive)))

(defmethod 3ds:radius ((primitive primitive))
  (global-radius (primitive-global-bounds-cache primitive)))

(defmethod invalidate-global-bounds-cache ((primitive primitive))
  (setf (global-bounds-cache-dirty-p (primitive-global-bounds-cache primitive)) T))

(define-accessor-delegate-methods entity (primitive-entity primitive))
(define-accessor-delegate-methods material (primitive-material primitive))
(define-accessor-delegate-methods transform-matrix (primitive-transform primitive))

(defmethod sample-volume :around ((primitive primitive) &optional result)
  (declare (ignore result))
  (let ((result (call-next-method))
        (transform (primitive-transform primitive)))
    (etypecase result
      (vec3 (n*m transform result))
      (simple-vector
       (dotimes (i (length result) result)
         (n*m transform (the vec3 (aref result i)))))
      (sequence
       (sequences:dosequence (el (length result) result)
         (n*m transform (the vec3 el)))))))

(defun make-primitive-like (primitive constructor &rest args)
  (apply constructor :entity (primitive-entity primitive)
                     :material (primitive-material primitive)
                     :local-transform (primitive-local-transform primitive)
                     :transform (mcopy (primitive-transform primitive))
                     :collision-mask (primitive-collision-mask primitive)
                     args))

(defmacro define-primitive-type (name slots &body body)
  (destructuring-bind (name &optional (super 'primitive)) (enlist name)
    (let ((int-constructor (mksym *package* '%make- name))
          (constructor (mksym *package* 'make- name)))
      `(progn
         (declaim (inline ,constructor))
         (defstruct (,name (:constructor ,int-constructor)
                           (:include ,super))
           ,@slots)

         (defun ,constructor (&rest args &key location orientation &allow-other-keys)
           (let* ((primitive (apply #',int-constructor (remf* args :location :orientation)))
                  (cache (primitive-global-bounds-cache primitive)))
             (when location (setf (location primitive) location))
             (when orientation (setf (orientation primitive) orientation))
             (setf (global-bounds-cache-generator cache) primitive)
             (setf (global-bounds-cache-radius cache) (compute-radius primitive))
             (v<- (global-bounds-cache-obb cache) (compute-bsize primitive))
             ,@body
             primitive))

         (defmethod clone ((,name ,name) &key)
           (let ((,name (<- (,int-constructor) ,name)))
             (setf (global-bounds-cache-generator (primitive-global-bounds-cache ,name)) ,name)))

         ,@(loop for (slot) in slots
                 collect `(defmethod ,slot ((primitive ,name))
                            (,(mksym *package* name '- slot) primitive))
                 collect `(defmethod (setf ,slot) (value (primitive ,name))
                            (setf (,(mksym *package* name '- slot) primitive) value)
                            (let ((cache (primitive-global-bounds-cache primitive)))
                              (setf (global-bounds-cache-radius cache) (compute-radius primitive))
                              (v<- (global-bounds-cache-obb cache) (compute-bsize primitive)))
                            value))))))

(define-primitive-type sphere
    ((radius 1.0 :type single-float)))

(define-transfer sphere sphere-radius)

(defmethod print-object ((primitive sphere) stream)
  (print-unreadable-object (primitive stream :type T :identity T)
    (format stream "~f" (radius primitive))))

(defmethod compute-bsize ((primitive sphere))
  (vec3 (sphere-radius primitive)))

(defmethod compute-radius ((primitive sphere))
  (sphere-radius primitive))

(defmethod sample-volume ((primitive sphere) &optional vec)
  (sampling:sphere (sphere-radius primitive) vec))

(define-support-function sphere (dir next)
  (nv* (!vunit* next dir) (sphere-radius primitive)))

(define-primitive-type ellipsoid
    ((radius (vec3 1 1 1) :type vec3)))

(define-transfer ellipsoid ellipsoid-radius)

(defmethod print-object ((primitive ellipsoid) stream)
  (print-unreadable-object (primitive stream :type T :identity T)
    (format stream "~a" (radius primitive))))

(defmethod compute-bsize ((primitive ellipsoid))
  (ellipsoid-radius primitive))

(defmethod compute-radius ((primitive ellipsoid))
  (let ((r (ellipsoid-radius primitive)))
    (max (vx r) (vy r) (vz r))))

(defmethod sample-volume ((primitive ellipsoid) &optional vec)
  (sampling:sphere (ellipsoid-radius primitive) vec))

(define-support-function ellipsoid (dir next)
  (nv* (nvunit (!v* next dir (ellipsoid-radius primitive))) (ellipsoid-radius primitive)))

(define-primitive-type plane
    ((normal (vec3 0 1 0) :type vec3)
     (offset 0.0 :type single-float)))

(define-transfer plane plane-normal plane-offset)

(defmethod print-object ((primitive plane) stream)
  (print-unreadable-object (primitive stream :type T :identity T)
    (format stream "~a ~f" (normal primitive) (offset primitive))))

(defmethod compute-bsize ((primitive plane))
  (cond ((v= +vx3+ (vabs (plane-normal primitive)))
         (vec3 1.0 most-positive-single-float most-positive-single-float))
        ((v= +vy3+ (vabs (plane-normal primitive)))
         (vec3 most-positive-single-float 1.0 most-positive-single-float))
        ((v= +vz3+ (vabs (plane-normal primitive)))
         (vec3 most-positive-single-float most-positive-single-float 1.0))
        (T ;; The plane is slightly tilted, so its bsize is infinite.
         (vec3 most-positive-single-float most-positive-single-float most-positive-single-float))))

(defmethod compute-radius ((primitive plane))
  most-positive-single-float)

(define-support-function plane (dir next)
  (let ((denom (v. (plane-normal primitive) dir)))
    (if (<= denom 0.000001)
        (!v* next dir (plane-offset primitive))
        (!v* next dir (/ (plane-offset primitive) denom)))))

(define-primitive-type (half-space plane)
    ())

(defmethod compute-bsize ((primitive half-space))
  (vec3 most-positive-single-float))

(define-support-function half-space (dir next)
  ;; TODO: implement
  (implement!))

;; NOTE: the box is centred at 0,0,0 and the bsize is the half-size along each axis.
(define-primitive-type box
    ((bsize (vec3 1 1 1) :type vec3)))

(define-transfer box box-bsize)

(defmethod print-object ((primitive box) stream)
  (print-unreadable-object (primitive stream :type T :identity T)
    (format stream "~a" (bsize primitive))))

(defmethod compute-bsize ((primitive box))
  (vcopy (box-bsize primitive)))

(defmethod compute-radius ((primitive box))
  (vlength (box-bsize primitive)))

(defmethod sample-volume ((primitive box) &optional vec)
  (sampling:box (box-bsize primitive) vec))

(define-support-function box (dir next)
  (let ((bsize (box-bsize primitive)))
    (vsetf next
           (if (< 0 (vx3 dir)) (vx3 bsize) (- (vx3 bsize)))
           (if (< 0 (vy3 dir)) (vy3 bsize) (- (vy3 bsize)))
           (if (< 0 (vz3 dir)) (vz3 bsize) (- (vz3 bsize))))))

;; Frustums are just boxes skewed by a linear transform. We provide these shorthands
;; here to allow easier construction of frustum testing primitives.
(defun make-frustum-box (left right bottom top near far)
  (let ((transform (mfrustum left right bottom top near far)))
    (make-box :local-transform transform
              :transform (mcopy transform)
              :bsize (vec (* 0.5 (abs (- right left)))
                          (* 0.5 (abs (- top bottom)))
                          (* 0.5 (abs (- far near)))))))

(defun make-perspective-box (fovy aspect near far)
  (let* ((fh (* (the single-float (tan (* (/ fovy 360.0) F-PI))) near))
         (fw (* fh aspect)))
    (make-frustum-box (- fw) fw (- fh) fh near far)))

;; NOTE: the cylinder is centred at 0,0,0 and points Y-up. the "height" is the half-height.
(define-primitive-type cylinder
    ((radius 1.0 :type single-float)
     (height 1.0 :type single-float)))

(define-transfer cylinder cylinder-radius cylinder-height)

(defmethod print-object ((primitive cylinder) stream)
  (print-unreadable-object (primitive stream :type T :identity T)
    (format stream "~f ~f" (radius primitive) (height primitive))))

(defmethod compute-bsize ((primitive cylinder))
  (vec3 (cylinder-radius primitive)
        (cylinder-height primitive)
        (cylinder-radius primitive)))

(defmethod compute-radius ((primitive cylinder))
  (sqrt (+ (expt (cylinder-radius primitive) 2)
           (expt (cylinder-height primitive) 2))))

(defmethod sample-volume ((primitive cylinder) &optional vec)
  (sampling:cylinder (cylinder-radius primitive) (cylinder-height primitive) +vy+ vec))

(define-support-function cylinder (dir next)
  (vsetf next (vx dir) 0 (vz dir))
  (nv* (nvunit* next) (cylinder-radius primitive))
  (if (< 0 (vy dir))
      (incf (vy next) (cylinder-height primitive))
      (decf (vy next) (cylinder-height primitive))))

;; NOTE: the pill is centred at 0,0,0, and points Y-up. the "height" is the half-height
;;       and does not include the caps, meaning the total height of the pill is 2r+2h.
(define-primitive-type pill
    ((radius 1.0 :type single-float)
     (height 1.0 :type single-float)))

(define-transfer pill pill-radius pill-height)

(defmethod print-object ((primitive pill) stream)
  (print-unreadable-object (primitive stream :type T :identity T)
    (format stream "~f ~f" (radius primitive) (height primitive))))

(defmethod compute-bsize ((primitive pill))
  (vec3 (pill-radius primitive)
        (+ (pill-radius primitive) (pill-height primitive))
        (pill-radius primitive)))

(defmethod compute-radius ((primitive pill))
  (+ (pill-height primitive) (pill-radius primitive)))

(defmethod sample-volume ((primitive pill) &optional vec)
  (sampling:pill (pill-radius primitive) (pill-height primitive) +vy+ vec))

(define-support-function pill (dir next)
  (nv* (nvunit* (v<- next dir)) (pill-radius primitive))
  (let ((bias (pill-height primitive)))
    (if (< 0 (vy dir))
        (incf (vy next) bias)
        (decf (vy next) bias))))

(define-primitive-type triangle
    ((a (vec3 -1 0 -1) :type vec3)
     (b (vec3 +1 0 -1) :type vec3)
     (c (vec3 +0 0 +1) :type vec3)))

(define-transfer triangle triangle-a triangle-b triangle-c)

(defmethod print-object ((primitive triangle) stream)
  (print-unreadable-object (primitive stream :type T :identity T)
    (format stream "~a ~a ~a" (a primitive) (b primitive) (c primitive))))

(defmethod compute-bsize ((primitive triangle))
  (let ((vmin (vec3 most-positive-single-float))
        (vmax (vec3 most-negative-single-float)))
    (declare (dynamic-extent vmin))
    (flet ((test (vec)
             (nvmin vmin vec)
             (nvmax vmax vec)))
      (test (triangle-a primitive))
      (test (triangle-b primitive))
      (test (triangle-c primitive))
      (nv* (nv- vmax vmin) 0.5))))

(defmethod compute-radius ((primitive triangle))
  (sqrt (max (vsqrlength (triangle-a primitive))
             (vsqrlength (triangle-b primitive))
             (vsqrlength (triangle-c primitive)))))

(defmethod sample-volume ((primitive triangle) &optional vec)
  (sampling:triangle (triangle-a primitive) (triangle-b primitive) (triangle-c primitive) vec))

(define-support-function triangle (dir next)
  (let ((furthest most-negative-single-float))
    (flet ((test (vert)
             (let ((dist (v. vert dir)))
               (when (< furthest dist)
                 (setf furthest dist)
                 (v<- next vert)))))
      (test (triangle-a primitive))
      (test (triangle-b primitive))
      (test (triangle-c primitive)))))

(define-primitive-type general-mesh
    (;; NOTE: Packed vertex positions as X Y Z triplets
     ;; [ X0 Y0 Z0 X1 Y1 Z1 X2 Y2 Z2 X3 Y3 Z3 ... ]
     (vertices (make-array 0 :element-type 'single-float) :type (simple-array single-float (*)))
     ;; NOTE: Vertex indices pointing into the vertex array / 3
     ;; [ 0 1 2 2 3 0 ... ]
     (faces (make-array 0 :element-type '(unsigned-byte 16)) :type (simple-array (unsigned-byte 16) (*))))
  (let ((offset (recenter-vertices (general-mesh-vertices primitive))))
    (!m* (primitive-local-transform primitive)
         offset
         (primitive-local-transform primitive))))

(define-transfer general-mesh general-mesh-vertices general-mesh-faces)

(defmethod print-object ((primitive general-mesh) stream)
  (print-unreadable-object (primitive stream :type T :identity T)
    (format stream "~d tris" (truncate (length (faces primitive)) 3))))

(defun recenter-vertices (vertices)
  (let ((center (org.shirakumo.fraf.manifolds:bounding-box vertices)))
    (org.shirakumo.fraf.manifolds:transform-mesh vertices (mtranslation (v- center)))
    (mtranslation center)))

(defmethod compute-bsize ((primitive general-mesh))
  (let ((vmin (vec3 most-positive-single-float))
        (vmax (vec3 most-negative-single-float))
        (tmp (vec3))
        (vertices (general-mesh-vertices primitive)))
    (declare (dynamic-extent vmin tmp))
    (loop for i from 0 below (length vertices) by 3
          do (vsetf tmp
                    (aref vertices (+ i 0))
                    (aref vertices (+ i 1))
                    (aref vertices (+ i 2)))
             (nvmin vmin tmp)
             (nvmax vmax tmp))
    (nv* (v- vmax vmin) 0.5)))

(defmethod compute-radius ((primitive general-mesh))
  ;; NOTE: because we cannot move the location of the fitting sphere to be
  ;;       different from the location of the primitive, this radius is not
  ;;       necessarily the ideal radius.
  (sqrt (loop with vertices = (general-mesh-vertices primitive)
              for i from 0 below (length vertices) by 3
              maximize (+ (expt (aref vertices (+ i 0)) 2)
                          (expt (aref vertices (+ i 1)) 2)
                          (expt (aref vertices (+ i 2)) 2)))))

(define-primitive-type (convex-mesh general-mesh)
    ()
  (let ((offset (recenter-vertices (general-mesh-vertices primitive))))
    (!m* (primitive-local-transform primitive)
         offset
         (primitive-local-transform primitive))))

(defmethod sample-volume ((primitive convex-mesh) &optional vec)
  (sampling:convex-mesh (convex-mesh-vertices primitive) (convex-mesh-faces primitive) vec))

(define-support-function convex-mesh (dir next)
  (let ((verts (convex-mesh-vertices primitive))
        (vert (vec3))
        (furthest most-negative-single-float))
    (declare (dynamic-extent vert))
    (declare (optimize speed (safety 0)))
    ;; FIXME: this is O(n)
    (loop for i from 0 below (length verts) by 3
          do (setf (vx vert) (aref verts (+ i 0)))
             (setf (vy vert) (aref verts (+ i 1)))
             (setf (vz vert) (aref verts (+ i 2)))
             (let ((dist (v. vert dir)))
               (when (< furthest dist)
                 (setf furthest dist)
                 (v<- next vert))))))

(define-primitive-type (optimized-convex-mesh convex-mesh)
    ((adjacency-list (make-array 0) :type simple-vector))
  ;; First normalize the mesh to ensure that we have no duplicated vertices or separated
  ;; meshes or anything.
  (multiple-value-bind (verts faces) (org.shirakumo.fraf.quickhull:convex-hull (convex-mesh-vertices primitive))
    (setf (convex-mesh-vertices primitive) verts)
    (setf (convex-mesh-faces primitive) (simplify faces '(unsigned-byte 16))))
  ;; Recenter it like the other mesh types do.
  (let ((offset (recenter-vertices (general-mesh-vertices primitive))))
    (!m* (primitive-local-transform primitive)
         offset
         (primitive-local-transform primitive)))
  ;; Precompute the adjacency list. As a further optimisation we already pre-multiply
  ;; the adjacents to be vertex array indices rather than vertex numbers, and turn it
  ;; into a simple-array for more compact storage.
  (let ((adjacent (org.shirakumo.fraf.manifolds:vertex-adjacency-list (convex-mesh-faces primitive))))
    (dotimes (i (length adjacent))
      (setf (aref adjacent i)
            (map '(simple-array (unsigned-byte 16) (*))
                 (lambda (x) (* 3 x)) (aref adjacent i))))
    (setf (optimized-convex-mesh-adjacency-list primitive) adjacent)))

(define-transfer optimized-convex-mesh optimized-convex-mesh-adjacency-list)

(define-support-function optimized-convex-mesh (dir next)
  (let* ((verts (convex-mesh-vertices primitive))
         (adjacents (optimized-convex-mesh-adjacency-list primitive))
         (furthest most-negative-single-float)
         (vert (vec3))
         (vertex 0)
         (iterations 0))
    (declare (dynamic-extent vert))
    (declare (type (unsigned-byte 16) vertex iterations))
    (flet ((try-vertex (i)
             (setf (vx vert) (aref verts (+ i 0)))
             (setf (vy vert) (aref verts (+ i 1)))
             (setf (vz vert) (aref verts (+ i 2)))
             (let ((dist (v. vert dir)))
               (when (< furthest dist)
                 (setf vertex i)
                 (setf furthest dist)
                 (v<- next vert)))))
      (try-vertex vertex)
      (tagbody
       next
         ;; KLUDGE: Hill climbing can get stuck in a coplanar local minimum. To catch this we
         ;;         cap the number of iterations and fall back to the O(n) method. It'll be
         ;;         super slow at that point, but at least we'll terminate with a correct
         ;;         result
         (when (= 256 (incf iterations))
           (dbg "HILL CLIMBING STUCK")
           (call-next-method)
           (go done))
         (loop for i of-type (unsigned-byte 16) across
               (the (simple-array (unsigned-byte 16) (*)) (aref adjacents (truncate vertex 3)))
               do (when (try-vertex i)
                    (go next)))
       done))))

(defmacro with-mesh-construction ((constructor &optional (finalizer 'finalize)) &body body)
  (let ((vertices (gensym "VERTICES"))
        (faces (gensym "FACES"))
        (face-table (gensym "FACE-TABLE")))
    `(let ((,vertices (make-array 0 :element-type 'single-float :adjustable T))
           (,faces (make-array 0 :element-type '(unsigned-byte 16) :adjustable T :fill-pointer T))
           (,face-table (make-hash-table :test 'equal))
           (i 0))
       (flet ((,constructor (x y z)
                (let* ((c (cons (cons x y) z))
                       (e (gethash c ,face-table)))
                  (cond (e
                         (vector-push-extend e ,faces))
                        (T
                         (vector-push-extend i ,faces)
                         (let ((j (* 3 i)))
                           (when (< (length ,vertices) (+ j 3))
                             (adjust-array ,vertices (+ j 3)))
                           (setf (aref ,vertices (+ j 0)) (float x 0f0))
                           (setf (aref ,vertices (+ j 1)) (float y 0f0))
                           (setf (aref ,vertices (+ j 2)) (float z 0f0)))
                         (setf (gethash c ,face-table) i)
                         (incf i)))))
              (,finalizer ()
                (values (make-array (length ,vertices) :element-type 'single-float :initial-contents ,vertices)
                        (make-array (length ,faces) :element-type '(unsigned-byte 16) :initial-contents ,faces))))
         ,@body))))

(defmethod coerce-object ((primitive primitive) (type (eql 'general-mesh)) &rest args &key &allow-other-keys)
  (apply #'coerce-object primitive 'convex-mesh args))

(defmethod coerce-object ((primitive sphere) (type (eql 'convex-mesh)) &key (segments 32))
  (with-mesh-construction (v)
    (let ((lat (float segments 0f0))
          (lng (float segments 0f0))
          (size (sphere-radius primitive)))
      (loop for i from lat downto 1
            for lat0 = (* F-PI (- (/ (1- i) lat) 0.5))
            for lat1 = (* F-PI (- (/ i lat) 0.5))
            for z0 = (sin lat0)
            for zr0 = (cos lat0)
            for z1 = (sin lat1)
            for zr1 = (cos lat1)
            when (< zr0 0.0001)
              do (setf zr0 0.0)
            when (< zr1 0.0001)
              do (setf zr1 0.0)
            do (loop for j from lng downto 1
                     for l1 = (* F-2PI (/ (- j 1) lng))
                     for l2 = (* F-2PI (/ (- j 2) lng))
                     for x1 = (cos l1) for x2 = (cos l2)
                     for y1 = (sin l1) for y2 = (sin l2)
                     unless (= zr0 0)
                       do (v (* x1 zr0 size) (* y1 zr0 size) (* z0 size))
                          (v (* x1 zr1 size) (* y1 zr1 size) (* z1 size))
                          (v (* x2 zr0 size) (* y2 zr0 size) (* z0 size))
                     unless (= zr1 0)
                       do (v (* x2 zr0 size) (* y2 zr0 size) (* z0 size))
                          (v (* x1 zr1 size) (* y1 zr1 size) (* z1 size))
                          (v (* x2 zr1 size) (* y2 zr1 size) (* z1 size)))))
    (multiple-value-bind (vertices faces) (finalize)
      (make-primitive-like primitive #'make-convex-mesh :vertices vertices :faces faces))))

(defmethod coerce-object ((primitive ellipsoid) (type (eql 'convex-mesh)) &key (segments 32))
  (with-mesh-construction (v)
    (let ((lat (float segments 0f0))
          (lng (float segments 0f0))
          (size (ellipsoid-radius primitive)))
      (loop for i from lat downto 1
            for lat0 = (* F-PI (- (/ (1- i) lat) 0.5))
            for lat1 = (* F-PI (- (/ i lat) 0.5))
            for z0 = (sin lat0)
            for zr0 = (cos lat0)
            for z1 = (sin lat1)
            for zr1 = (cos lat1)
            when (< zr0 0.0001)
            do (setf zr0 0.0)
            when (< zr1 0.0001)
            do (setf zr1 0.0)
            do (loop for j from lng downto 1
                     for l1 = (* F-2PI (/ (- j 1) lng))
                     for l2 = (* F-2PI (/ (- j 2) lng))
                     for x1 = (cos l1) for x2 = (cos l2)
                     for y1 = (sin l1) for y2 = (sin l2)
                     unless (= zr0 0)
                     do (v (* x1 zr0 (vx size)) (* y1 zr0 (vy size)) (* z0 (vz size)))
                        (v (* x1 zr1 (vx size)) (* y1 zr1 (vy size)) (* z1 (vz size)))
                        (v (* x2 zr0 (vx size)) (* y2 zr0 (vy size)) (* z0 (vz size)))
                     unless (= zr1 0)
                     do (v (* x2 zr0 (vx size)) (* y2 zr0 (vy size)) (* z0 (vz size)))
                        (v (* x1 zr1 (vx size)) (* y1 zr1 (vy size)) (* z1 (vz size)))
                        (v (* x2 zr1 (vx size)) (* y2 zr1 (vy size)) (* z1 (vz size))))))
    (multiple-value-bind (vertices faces) (finalize)
      (make-primitive-like primitive #'make-convex-mesh :vertices vertices :faces faces))))

(defmethod coerce-object ((primitive plane) (type (eql 'convex-mesh)) &key)
  (with-mesh-construction (v)
    (let* ((n (plane-normal primitive))
           (o (plane-offset primitive))
           (q (qtowards +vy3+ n))
           (a (vec -5 0 +5))
           (b (vec +5 0 +5))
           (c (vec +5 0 -5))
           (d (vec -5 0 -5)))
      (nv+* (!q* a q a) n o)
      (nv+* (!q* b q b) n o)
      (nv+* (!q* c q c) n o)
      (nv+* (!q* d q d) n o)
      (v (vx a) (vy a) (vz a)) (v (vx b) (vy b) (vz b)) (v (vx c) (vy c) (vz c))
      (v (vx c) (vy c) (vz c)) (v (vx d) (vy d) (vz d)) (v (vx a) (vy a) (vz a))
      ;; Make it double-faced.
      (v (vx a) (vy a) (vz a)) (v (vx c) (vy c) (vz c)) (v (vx b) (vy b) (vz b))
      (v (vx c) (vy c) (vz c)) (v (vx a) (vy a) (vz a)) (v (vx d) (vy d) (vz d)))
    (multiple-value-bind (vertices faces) (finalize)
      (make-primitive-like primitive #'make-convex-mesh :vertices vertices :faces faces))))

(defmethod coerce-object ((primitive box) (type (eql 'convex-mesh)) &key)
  (with-mesh-construction (v)
    (let ((w (vx (box-bsize primitive)))
          (h (vy (box-bsize primitive)))
          (d (vz (box-bsize primitive))))
      (v (+ w) (+ h) (- d)) (v (- w) (+ h) (- d)) (v (- w) (+ h) (+ d))
      (v (- w) (+ h) (+ d)) (v (+ w) (+ h) (+ d)) (v (+ w) (+ h) (- d))
      (v (+ w) (- h) (+ d)) (v (- w) (- h) (+ d)) (v (- w) (- h) (- d))
      (v (- w) (- h) (- d)) (v (+ w) (- h) (- d)) (v (+ w) (- h) (+ d))
      (v (+ w) (+ h) (+ d)) (v (- w) (+ h) (+ d)) (v (- w) (- h) (+ d))
      (v (- w) (- h) (+ d)) (v (+ w) (- h) (+ d)) (v (+ w) (+ h) (+ d))
      (v (+ w) (- h) (- d)) (v (- w) (- h) (- d)) (v (- w) (+ h) (- d))
      (v (- w) (+ h) (- d)) (v (+ w) (+ h) (- d)) (v (+ w) (- h) (- d))
      (v (- w) (+ h) (+ d)) (v (- w) (+ h) (- d)) (v (- w) (- h) (- d))
      (v (- w) (- h) (- d)) (v (- w) (- h) (+ d)) (v (- w) (+ h) (+ d))
      (v (+ w) (+ h) (- d)) (v (+ w) (+ h) (+ d)) (v (+ w) (- h) (+ d))
      (v (+ w) (- h) (+ d)) (v (+ w) (- h) (- d)) (v (+ w) (+ h) (- d)))
    (multiple-value-bind (vertices faces) (finalize)
      (make-primitive-like primitive #'make-convex-mesh :vertices vertices :faces faces))))

(defmethod coerce-object ((primitive cylinder) (type (eql 'convex-mesh)) &key (segments 32))
  (with-mesh-construction (v)
    (let ((s (cylinder-radius primitive))
          (h (cylinder-height primitive)))
      (loop with step = (/ F-2PI segments)
            for i1 = (- step) then i2
            for i2 from 0 to F-2PI by step
            do ;; Bottom disc
            (v (* s (cos i2)) (- h) (* s (sin i2)))
            (v 0.0            (- h) 0.0)
            (v (* s (cos i1)) (- h) (* s (sin i1)))
            ;; Top Disc
            (v 0.0            (+ h) 0.0)
            (v (* s (cos i2)) (+ h) (* s (sin i2)))
            (v (* s (cos i1)) (+ h) (* s (sin i1)))
            ;; Wall
            (v (* s (cos i2)) (- h) (* s (sin i2)))
            (v (* s (cos i1)) (- h) (* s (sin i1)))
            (v (* s (cos i2)) (+ h) (* s (sin i2)))
            (v (* s (cos i1)) (+ h) (* s (sin i1)))
            (v (* s (cos i2)) (+ h) (* s (sin i2)))
            (v (* s (cos i1)) (- h) (* s (sin i1)))))
    (multiple-value-bind (vertices faces) (finalize)
      (make-primitive-like primitive #'make-convex-mesh :vertices vertices :faces faces))))

(defmethod coerce-object ((primitive pill) (type (eql 'convex-mesh)) &key (segments 32))
  (with-mesh-construction (v)
    (let ((s (pill-radius primitive))
          (h (pill-height primitive))
          (lat (float segments 0f0))
          (lng (float segments 0f0)))
      (loop with step = (/ F-2PI segments)
            for i1 = (- step) then i2
            for i2 from 0 to F-2PI by step
            do ;; Wall
            (v (* s (cos i2)) (- h) (* s (sin i2)))
            (v (* s (cos i1)) (- h) (* s (sin i1)))
            (v (* s (cos i2)) (+ h) (* s (sin i2)))
            (v (* s (cos i1)) (+ h) (* s (sin i1)))
            (v (* s (cos i2)) (+ h) (* s (sin i2)))
            (v (* s (cos i1)) (- h) (* s (sin i1))))
      (flet ((cap (h lng-start lng-end)
               (loop for i from lat downto 1
                     for lat0 = (* F-PI (- (/ (1- i) lat) 0.5))
                     for lat1 = (* F-PI (- (/ i lat) 0.5))
                     for z0 = (sin lat0)
                     for zr0 = (cos lat0)
                     for z1 = (sin lat1)
                     for zr1 = (cos lat1)
                     do (loop for j from lng-start downto lng-end
                              for l1 = (* F-2PI (/ (- j 1) lng))
                              for l2 = (* F-2PI (/ (- j 2) lng))
                              for x1 = (cos l1) for x2 = (cos l2)
                              for y1 = (sin l1) for y2 = (sin l2)
                              do (v (* x1 zr0 s) (+ h (* y1 zr0 s)) (* z0 s))
                                 (v (* x1 zr1 s) (+ h (* y1 zr1 s)) (* z1 s))
                                 (v (* x2 zr0 s) (+ h (* y2 zr0 s)) (* z0 s))
                                 (v (* x2 zr0 s) (+ h (* y2 zr0 s)) (* z0 s))
                                 (v (* x1 zr1 s) (+ h (* y1 zr1 s)) (* z1 s))
                                 (v (* x2 zr1 s) (+ h (* y2 zr1 s)) (* z1 s))))))
        (cap (+ h) (1+ (truncate lng 2)) 2)
        (cap (- h) (1+ lng) (+ (truncate lng 2) 2))))
    (multiple-value-bind (vertices faces) (finalize)
      (make-primitive-like primitive #'make-convex-mesh :vertices vertices :faces faces))))

(defmethod coerce-object ((primitive triangle) (type (eql 'convex-mesh)) &key)
  (with-mesh-construction (v)
    (let ((a (triangle-a primitive))
          (b (triangle-b primitive))
          (c (triangle-c primitive)))
      (v (vx a) (vy a) (vz a))
      (v (vx b) (vy b) (vz b))
      (v (vx c) (vy c) (vz c))
      ;; Make it double-faced.
      (v (vx b) (vy b) (vz b))
      (v (vx a) (vy a) (vz a))
      (v (vx c) (vy c) (vz c)))
    (multiple-value-bind (vertices faces) (finalize)
      (make-primitive-like primitive #'make-convex-mesh :vertices vertices :faces faces))))

(defmethod coerce-object ((primitive general-mesh) (type (eql 'sphere)) &key)
  (let ((vertices (general-mesh-vertices primitive))
        (max 0.0))
    (loop for i from 0 below (length vertices) by 3
          for dist = (+ (expt (aref vertices (+ i 0)) 2)
                        (expt (aref vertices (+ i 1)) 2)
                        (expt (aref vertices (+ i 2)) 2))
          do (setf max (max max dist)))
    (make-primitive-like primitive #'make-sphere :radius (sqrt max))))

(defmethod coerce-object ((primitive general-mesh) (type (eql 'ellipsoid)) &key)
  (let ((vertices (general-mesh-vertices primitive))
        (max (vec3)))
    (loop for i from 0 below (length vertices) by 3
          do (setf (vx max) (max (vx max) (abs (aref vertices (+ i 0)))))
             (setf (vy max) (max (vy max) (abs (aref vertices (+ i 1)))))
             (setf (vz max) (max (vz max) (abs (aref vertices (+ i 2))))))
    (make-primitive-like primitive #'make-ellipsoid :radius max)))

(defmethod coerce-object ((primitive general-mesh) (type (eql 'box)) &key)
  (let ((vertices (general-mesh-vertices primitive))
        (max (vec 0 0 0)))
    ;; TODO: This does not try to adjust the rotation of the resulting primitive to fit better.
    ;;       ideally we'd first try to find the ideal orientation along which to fit the bounding
    ;;       box, then determine the size along that orientation, and adjust the resulting
    ;;       primitive's transforms
    (loop for i from 0 below (length vertices) by 3
          do (setf (vx max) (max (vx max) (abs (aref vertices (+ i 0)))))
             (setf (vy max) (max (vy max) (abs (aref vertices (+ i 1)))))
             (setf (vz max) (max (vz max) (abs (aref vertices (+ i 2))))))
    (make-primitive-like primitive #'make-box :bsize max)))

(defmethod coerce-object ((primitive general-mesh) (type (eql 'cylinder)) &key)
  (let ((vertices (general-mesh-vertices primitive))
        (height 0.0) (radius 0.0))
    ;; TODO: This does not try to adjust the rotation of the resulting primitive to fit better.
    ;;       ideally we'd first try to find the ideal orientation along which to fit the bounding
    ;;       cylinder, then determine the size along that orientation, and adjust the resulting
    ;;       primitive's transforms
    (loop for i from 0 below (length vertices) by 3
          do (setf height (max height (abs (aref vertices (+ i 1)))))
             (setf radius (max radius (abs (aref vertices (+ i 0)))))
             (setf radius (max radius (abs (aref vertices (+ i 2))))))
    (make-primitive-like primitive #'make-cylinder :radius radius :height height)))

(defmethod coerce-object ((primitive general-mesh) (type (eql 'pill)) &key)
  (implement!))

(defmethod coerce-object ((primitive general-mesh) (type (eql 'convex-mesh)) &key)
  (multiple-value-bind (vertices faces)
      (org.shirakumo.fraf.quickhull:convex-hull (general-mesh-vertices primitive))
    (make-primitive-like primitive #'make-convex-mesh :vertices vertices :faces faces)))

(defmethod make-vertex-array ((primitive primitive) vao)
  (let* ((mesh (coerce-object primitive 'general-mesh))
         (vbo (make-instance 'vertex-buffer :buffer-data (general-mesh-vertices mesh)))
         (ebo (make-instance 'vertex-buffer :buffer-data (general-mesh-faces mesh)
                                            :buffer-type :element-array-buffer
                                            :element-type :unsigned-short)))
    (ensure-instance vao 'vertex-array :index-buffer ebo :bindings `((,vbo :size 3)))))

(defmethod coerce-object ((primitive primitive) (type (eql 'mesh-data)) &rest args &key &allow-other-keys)
  (apply #'coerce-object (make-vertex-array primitive NIL) 'mesh-data args))

(defmethod coerce-object ((mesh mesh-data) (type (eql 'primitive)) &rest args &key &allow-other-keys)
  (apply #'make-general-mesh
         :vertices (reordered-vertex-data mesh '(location))
         :faces (simplify (faces mesh) '(unsigned-byte 16))
         args))

(defmethod coerce-object ((primitive convex-mesh) (type (eql 'optimized-convex-mesh)) &rest args &key &allow-other-keys)
  (apply #'make-optimized-convex-mesh
         :vertices (convex-mesh-vertices primitive)
         :faces (convex-mesh-faces primitive)
         args))

(defmethod replace-vertex-data (target (primitive primitive) &rest args &key &allow-other-keys)
  (apply #'replace-vertex-data target (coerce-object primitive 'mesh-data) args))

(defun convexify (primitives)
  (let ((new (make-array 0 :adjustable T :fill-pointer T)))
    (loop for primitive across primitives
          do (etypecase primitive
               ((and general-mesh (not convex-mesh))
                (let ((hulls (org.shirakumo.fraf.convex-covering:decompose
                              (general-mesh-vertices primitive)
                              (general-mesh-faces primitive)
                              :tolerance (expt 10 -2.5))))
                  (loop for hull across hulls
                        for mesh = (make-convex-mesh :vertices (org.shirakumo.fraf.convex-covering:vertices hull)
                                                     :faces (simplify (org.shirakumo.fraf.convex-covering:faces hull) '(unsigned-byte 16))
                                                     :material (primitive-material primitive)
                                                     :local-transform (mcopy (primitive-local-transform primitive)))
                        do (vector-push-extend mesh new))))
               (primitive
                (vector-push-extend primitive new))))
    (simplify new)))
