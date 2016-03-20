#|
 This file is a part of simple-tasks
 (c) 2016 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package #:org.shirakumo.fraf.trial)
(in-readtable :qtools)

(defparameter *key-table*
  (alexandria:alist-hash-table
   '((#x01000000 . :Escape)
     (#x01000001 . :Tab)
     (#x01000002 . :Backtab)
     (#x01000003 . :Backspace)
     (#x01000004 . :Return)
     (#x01000005 . :Enter)
     (#x01000006 . :Insert)
     (#x01000007 . :Delete)
     (#x01000008 . :Pause)
     (#x01000009 . :Print)
     (#x0100000a . :SysReq)
     (#x0100000b . :Clear)
     (#x01000010 . :Home)
     (#x01000011 . :End)
     (#x01000012 . :Left)
     (#x01000013 . :Up)
     (#x01000014 . :Right)
     (#x01000015 . :Down)
     (#x01000016 . :PageUp)
     (#x01000017 . :PageDown)
     (#x01000020 . :Shift)
     (#x01000021 . :Control)
     (#x01000022 . :Meta)
     (#x01000023 . :Alt)
     (#x01001103 . :AltGr)
     (#x01000024 . :CapsLock)
     (#x01000025 . :NumLock)
     (#x01000026 . :ScrollLock)
     (#x01000030 . :F1)
     (#x01000031 . :F2)
     (#x01000032 . :F3)
     (#x01000033 . :F4)
     (#x01000034 . :F5)
     (#x01000035 . :F6)
     (#x01000036 . :F7)
     (#x01000037 . :F8)
     (#x01000038 . :F9)
     (#x01000039 . :F10)
     (#x0100003a . :F11)
     (#x0100003b . :F12)
     (#x0100003c . :F13)
     (#x0100003d . :F14)
     (#x0100003e . :F15)
     (#x0100003f . :F16)
     (#x01000040 . :F17)
     (#x01000041 . :F18)
     (#x01000042 . :F19)
     (#x01000043 . :F20)
     (#x01000044 . :F21)
     (#x01000045 . :F22)
     (#x01000046 . :F23)
     (#x01000047 . :F24)
     (#x01000048 . :F25)
     (#x01000049 . :F26)
     (#x0100004a . :F27)
     (#x0100004b . :F28)
     (#x0100004c . :F29)
     (#x0100004d . :F30)
     (#x0100004e . :F31)
     (#x0100004f . :F32)
     (#x01000050 . :F33)
     (#x01000051 . :F34)
     (#x01000052 . :F35)
     (#x01000053 . :Super_L)
     (#x01000054 . :Super_R)
     (#x01000055 . :Menu)
     (#x01000056 . :Hyper_L)
     (#x01000057 . :Hyper_R)
     (#x01000058 . :Help)
     (#x01000059 . :Direction_L)
     (#x01000060 . :Direction_R)
     (#x00000020 . :Space)
     (#x00000021 . :Exclam)
     (#x00000022 . :QuoteDbl)
     (#x00000023 . :NumberSign)
     (#x00000024 . :Dollar)
     (#x00000025 . :Percent)
     (#x00000026 . :Ampersand)
     (#x00000027 . :Apostrophe)
     (#x00000028 . :ParenLeft)
     (#x00000029 . :ParenRight)
     (#x0000002a . :Asterisk)
     (#x0000002b . :Plus)
     (#x0000002c . :Comma)
     (#x0000002d . :Minus)
     (#x0000002e . :Period)
     (#x0000002f . :Slash)
     (#x00000030 . :0)
     (#x00000031 . :1)
     (#x00000032 . :2)
     (#x00000033 . :3)
     (#x00000034 . :4)
     (#x00000035 . :5)
     (#x00000036 . :6)
     (#x00000037 . :7)
     (#x00000038 . :8)
     (#x00000039 . :9)
     (#x0000003a . :Colon)
     (#x0000003b . :Semicolon)
     (#x0000003c . :Less)
     (#x0000003d . :Equal)
     (#x0000003e . :Greater)
     (#x0000003f . :Question)
     (#x00000040 . :At)
     (#x00000041 . :A)
     (#x00000042 . :B)
     (#x00000043 . :C)
     (#x00000044 . :D)
     (#x00000045 . :E)
     (#x00000046 . :F)
     (#x00000047 . :G)
     (#x00000048 . :H)
     (#x00000049 . :I)
     (#x0000004a . :J)
     (#x0000004b . :K)
     (#x0000004c . :L)
     (#x0000004d . :M)
     (#x0000004e . :N)
     (#x0000004f . :O)
     (#x00000050 . :P)
     (#x00000051 . :Q)
     (#x00000052 . :R)
     (#x00000053 . :S)
     (#x00000054 . :T)
     (#x00000055 . :U)
     (#x00000056 . :V)
     (#x00000057 . :W)
     (#x00000058 . :X)
     (#x00000059 . :Y)
     (#x0000005a . :Z))
   :test 'eql))

(defvar *button-table*
  (alexandria:alist-hash-table
   '((#x00000000 . :NoButton)
     (#x00000001 . :Left)
     (#x00000002 . :Right)
     (#x00000004 . :Middle)
     (#x00000008 . :X1)
     (#x00000010 . :X2))
   :test 'eql))

(defun qt-key->symbol (enum)
  (gethash (etypecase enum
             (integer enum)
             (qt::enum (qt:enum-value enum)))
           *key-table*))

(defun qt-button->symbol (enum)
  (gethash (etypecase enum
             (integer enum)
             (qt::enum (qt:enum-value enum)))
           *button-table*))

(define-event input-event (trial-event)
  ())

(define-event keyboard-event (input-event)
  ((key :initarg :key :reader key))
  (:default-initargs
   :key (error "KEY required.")))

(defmethod print-object ((event keyboard-event) stream)
  (print-unreadable-object (event stream :type T)
    (format stream "~a" (key event))))

(define-event key-press (keyboard-event)
  ())

(define-event key-release (keyboard-event)
  ())

(define-event mouse-event (input-event)
  ((button :initarg :button :reader button))
  (:default-initargs
   :button (error "BUTTON required.")))

(defmethod print-object ((event mouse-event) stream)
  (print-unreadable-object (event stream :type T)
    (format stream "~a" (button event))))

(define-event mouse-button-press (mouse-event)
  ())

(define-event mouse-button-release (mouse-event)
  ())

(define-event mouse-move (input-event)
  ((old-pos :initarg :old-pos :reader old-pos)
   (new-pos :initarg :new-pos :reader new-pos))
  (:default-initargs
   :old-pos (error "OLD-POS required.")
   :new-pos (error "NEW-POS required.")))

(defmethod print-object ((event mouse-move) stream)
  (print-unreadable-object (event stream :type T)
    (format stream "~a => ~a" (old-pos event) (new-pos event))))

(define-override (main key-press-event) (ev)
  (let ((key (qt-key->symbol (q+:key ev))))
    (when key (issue 'key-press :key key))))

(define-override (main key-release-event) (ev)
  (let ((key (qt-key->symbol (q+:key ev))))
    (when key (issue 'key-release :key key))))

(define-override (main mouse-press-event) (ev)
  (let ((button (qt-button->symbol (q+:button ev))))
    (when button (issue 'mouse-button-press :button button))))

(define-override (main mouse-release-event) (ev)
  (let ((button (qt-button->symbol (q+:button ev))))
    (when button (issue 'mouse-button-release :button button))))

(defvar *previous-mouse-position* NIL)
(define-override (main mouse-move-event) (ev)
  (let ((new (vec (q+:x (q+:pos-f ev)) (q+:y (q+:pos-f ev)) 0)))
    (issue 'mouse-move :old-pos (or *previous-mouse-position* new) :new-pos new)
    (setf *previous-mouse-position* new)))
