(library
  (harlan front typecheck)
  (export typecheck free-regions-type)
  (import
    (rnrs)
    (only (chezscheme) make-parameter parameterize
          pretty-print printf trace-define trace-let)
    (elegant-weapons match)
    (elegant-weapons helpers)
    (elegant-weapons sets)
    (harlan compile-opts)
    (util color))

  (define (typecheck m)
    (let-values (((m s) (infer-module m)))
      (ground-module `(module . ,m) s)))

  (define-record-type tvar (fields name))
  (define-record-type rvar (fields name))

  (define type-tag (gensym 'type))
  
  ;; Walks type and region variables in a substitution
  (define (walk x s)
    (let ((x^ (assq x s)))
      ;; TODO: We will probably need to check for cycles.
      (if x^
          (let ((x^ (cdr x^)))
            (cond 
              ((or (tvar? x^) (rvar? x^))
               (walk x^ s))
              ((eq? x^ 'Numeric)
               x)
              (else x^)))
          x)))
              
  (define (walk-type t s)
    (match t
      (,t (guard (symbol? t)) t)
      ((vec ,r ,[t]) `(vec ,(walk r s) ,t))
      ((ptr ,[t]) `(ptr ,t))
      (((,[t*] ...) -> ,[t]) `((,t* ...) -> ,t))
      (,x (guard (tvar? x))
          (let ((x^ (walk x s)))
            (if (equal? x x^)
                x
                (walk-type x^ s))))))
  
  ;; Unifies types a and b. s is an a-list containing substitutions
  ;; for both type and region variables. If the unification is
  ;; successful, this function returns a new substitution. Otherwise,
  ;; this functions returns #f.
  (define (unify-types a b s)
    (match `(,(walk-type a s) ,(walk-type b s))
      ;; Obviously equal types unify.
      ((,a ,b) (guard (equal? a b)) s)
      
      ((int Numeric)
       (if (tvar? b)
           `((,b . int) . ,s)
           s))
      ((float Numeric)
       (if (tvar? b)
           `((,b . float) . ,s)
           s))
      ((u64 Numeric)
       (if (tvar? b)
           `((,b . u64) . ,s)
           s))
      ;;((Numeric float) (guard (tvar? a)) `((,a . float) . ,s))

      ((,a ,b) (guard (tvar? a)) `((,a . ,b) . ,s))
      ((,a ,b) (guard (tvar? b)) `((,b . ,a) . ,s))      
      (((vec ,ra ,a) (vec ,rb ,b))
       (let ((s (unify-types a b s)))
         (and s (if (eq? ra rb)
                    s
                    `((,ra . ,rb) . ,s)))))
      ((((,a* ...) -> ,a) ((,b* ...) -> ,b))
       (let loop ((a* a*)
                  (b* b*))
         (match `(,a* ,b*)
           ((() ()) (unify-types a b s))
           (((,a ,a* ...) (,b ,b* ...))
            (let ((s (loop a* b*)))
              (and s (unify-types a b s))))
           (,else #f))))
      (,else #f)))

  (define (type-error e expected found)
    (error 'typecheck
           "Could not unify types"
           e expected found))

  (define (return e t)
    (lambda (_ r s)
      (values e t s)))

  (define (bind m seq)
    (lambda (e^ r s)
      (let-values (((e t s) (m e^ r s)))
        ((seq e t) e^ r s))))

  (define (unify a b seq)
    (lambda (e r s)
      (let ((s (unify-types a b s)))
        ;;(printf "Unifying ~a and ~a => ~a\n" a b s)
        (if s
            ((seq) e r s)
            (type-error e a b)))))

  (define (== a b)
    (unify a b (lambda () (return #f a))))
    
  (define (require-type e env t)
    (let ((tv (make-tvar (gensym 'tv))))
      (do* (((e t^) (infer-expr e env))
            ((_ __)  (== tv t))
            ((_ __)  (== tv t^)))
           (return e tv))))

  (define (unify-return-type t seq)
    (lambda (e r s)
      ((unify r t seq) e r s)))

  (define-syntax with-current-expr
    (syntax-rules ()
      ((_ e b)
       (lambda (e^ r s)
         (b e r s)))))
  
  ;; you can use this with bind too!
  (define (infer-expr* e* env)
    (if (null? e*)
        (return '() '())
        (let ((e (car e*))
              (e* (cdr e*)))
          (bind
           (infer-expr* e* env)
           (lambda (e* t*)
             (bind (infer-expr e env)
                   (lambda (e t)
                     (return `(,e . ,e*)
                             `(,t . ,t*)))))))))

  (define (require-all e* env t)
    (if (null? e*)
        (return '() t)
        (let ((e (car e*))
              (e* (cdr e*)))
          (do* (((e* t) (require-all e* env t))
                ((e  t) (require-type e env t)))
               (return `(,e . ,e*) t)))))
           
  
  (define-syntax do*
    (syntax-rules ()
      ((_ (((x ...) e) ((x* ...) e*) ...) b)
       (bind e (lambda (x ...)
                 (do* (((x* ...) e*) ...) b))))
      ((_ () b) b)))

  (define (infer-expr e env)
    ;(display `(,e :: ,env)) (newline)
    (with-current-expr
     e
     (match e
       ((int ,n)
        (return `(int ,n) 'int))
       ((float ,f)
        (return `(float ,f) 'float))
       ((num ,n)
        (let ((t (make-tvar (gensym 'num))))
          (do* (((_ t) (== t 'Numeric)))
               (return `(num ,n) t))))
       ((char ,c) (return `(char ,c) 'char))
       ((bool ,b)
        (return `(bool ,b) 'bool))
       ((str ,s)
        (return `(str ,s) 'str))
       ((var ,x)
        (let ((t (lookup x env)))
          (return `(var ,t ,x) t)))
       ((int->float ,e)
        (do* (((e _) (require-type e env 'int)))
             (return `(int->float ,e) 'float)))
       ((return)
        (unify-return-type
         'void
         ;; Returning a free type variable is better so we can return
         ;; from any context, but that gives us problems with free
         ;; type variables at the end.
         (lambda () (return `(return) 'void))))
       ((return ,e)
        (bind (infer-expr e env)
              (lambda (e t)
                (unify-return-type
                 t
                 (lambda ()
                   (return `(return ,e) t))))))
       ((print ,e)
        (do* (((e t) (infer-expr e env)))
             (return `(print ,t ,e) 'void)))
       ((print ,e ,f)
        (do* (((e t) (infer-expr e env))
              ((f _) (require-type f env '(ptr ofstream))))
             (return `(print ,t ,e ,f) 'void)))
       ((println ,e)
        (do* (((e t) (infer-expr e env)))
             (return `(println ,t ,e) 'void)))
       ((iota ,e)
        (do* (((e t) (require-type e env 'int)))
             (let ((r (make-rvar (gensym 'r))))
               (return `(iota-r ,r ,e)
                       `(vec ,r int)))))
       ((iota-r ,r ,e)
        (do* (((e t) (require-type e env 'int)))
             (return `(iota-r ,r ,e)
                     `(vec ,r int))))
       ((vector ,e* ...)
        (let ((t (make-tvar (gensym 'tvec)))
              (r (make-rvar (gensym 'rv))))
          (do* (((e* t) (require-all e* env t)))
               (return `(vector (vec ,r ,t) ,e* ...) `(vec ,r ,t)))))
       ((vector-r ,r ,e* ...)
        (let ((t (make-tvar (gensym 'tvec))))
          (do* (((e* t) (require-all e* env t)))
               (return `(vector (vec ,r ,t) ,e* ...) `(vec ,r ,t)))))
       ((make-vector ,len ,val)
        (do* (((len _) (require-type len env 'int))
              ((val t) (infer-expr val env)))
             (let ((t `(vec ,(make-rvar (gensym 'rmake-vector)) ,t)))
               (return `(make-vector ,t ,len ,val) t))))
       ((length ,v)
        (let ((t (make-tvar (gensym 'tveclength)))
              (r (make-rvar (gensym 'rvl))))
          (do* (((v _) (require-type v env `(vec ,r ,t))))
               (return `(length ,v) 'int))))
       ((vector-ref ,v ,i)
        (let ((t (make-tvar (gensym 'tvecref)))
              (r (make-rvar (gensym 'rvref))))
          (do* (((v _) (require-type v env `(vec ,r ,t)))
                ((i _) (require-type i env 'int)))
               (return `(vector-ref ,t ,v ,i) t))))
       ((,+ ,a ,b) (guard (binop? +))
        (do* (((a t) (infer-expr a env))
              ((b t) (require-type b env t))
              ((_ __) (== t 'Numeric)))
             (return `(,+ ,t ,a ,b) t)))
       ((= ,a ,b)
        (do* (((a t) (infer-expr a env))
              ((b t) (require-type b env t)))
             (return `(= ,t ,a ,b) 'bool)))
       ((,< ,a ,b)
        (guard (relop? <))
        (do* (((a t) (infer-expr a env))
              ((b t) (require-type b env t))
              ((_ __) (== t 'Numeric)))
             (return `(,< bool ,a ,b) 'bool)))
       ((assert ,e)
        (do* (((e t) (require-type e env 'bool)))
             (return `(assert ,e) t)))
       ((set! ,x ,e)
        (do* (((x t) (infer-expr x env))
              ((e t) (require-type e env t)))
             (return `(set! ,x ,e) 'void)))
       ((begin ,s* ... ,e)
        (do* (((s* _) (infer-expr* s* env))
              ((e t) (infer-expr e env)))
             (return `(begin ,s* ... ,e) t)))
       ((if ,test ,c ,a)
        (do* (((test tt) (require-type test env 'bool))
              ((c t) (infer-expr c env))
              ((a t) (require-type a env t)))
             (return `(if ,test ,c ,a) t)))
       ((if ,test ,c)
        (do* (((test tt) (require-type test env 'bool))
              ((c t) (require-type c env 'void)))
             (return `(if ,test ,c) t)))
       ((let ((,x ,e) ...) ,body)
        (do* (((e t*) (infer-expr* e env))
              ((body t) (infer-expr body (append (map cons x t*) env))))
             (return `(let ((,x ,t* ,e) ...) ,body) t)))
       ((let-region (,r* ...) ,b)
        (do* (((b t) (infer-expr b env)))
             (return `(let-region (,r* ...) ,b) t)))
       ((for (,x ,start ,end ,step) ,body)
        (do* (((start _) (require-type start env 'int))
              ((end   _) (require-type end   env 'int))
              ((step  _) (require-type step  env 'int))
              ((body  t) (infer-expr body `((,x . int) . ,env))))
             (return `(for (,x ,start ,end ,step) ,body) t)))
       ((while ,t ,b)
        (do* (((t _) (require-type t env 'bool))
              ((b _) (infer-expr b env)))
             (return `(while ,t ,b) 'void)))
       ((reduce + ,e)
        (let ((r (make-rvar (gensym 'r)))
              (t (make-tvar (gensym 'reduce-t))))
          (do* (((_ __) (== t 'Numeric))
                ((e t)  (require-type e env `(vec ,r ,t))))
               (return `(reduce ,t + ,e) 'int))))
       ((kernel ((,x ,e) ...) ,b)
        (do* (((e t*) (let loop ((e e))
                       (if (null? e)
                           (return '() '())
                           (let ((e* (cdr e))
                                 (e (car e))
                                 (t (make-tvar (gensym 'kt)))
                                 (r (make-rvar (gensym 'rkt))))
                             (do* (((e* t*) (loop e*))
                                   ((e _) (require-type e env `(vec ,r ,t))))
                                  (return (cons e e*)
                                          (cons (list r t) t*)))))))
              ((b t) (infer-expr b (append
                                    (map (lambda (x t) (cons x (cadr t))) x t*)
                                    env))))
             (let ((r (make-rvar (gensym 'rk))))
               (return `(kernel-r (vec ,r ,t) ,r
                          (((,x ,(map cadr t*))
                            (,e (vec . ,t*))) ...)
                          ,b)
                       `(vec ,r ,t)))))
       ((kernel-r ,r ((,x ,e) ...) ,b)
        (do* (((e t*) (let loop ((e e))
                        (if (null? e)
                            (return '() '())
                            (let ((e* (cdr e))
                                  (e (car e))
                                  (t (make-tvar (gensym 'kt)))
                                  (r (make-rvar (gensym 'rkt))))
                              (do* (((e* t*) (loop e*))
                                    ((e _) (require-type e env `(vec ,r ,t))))
                                   (return (cons e e*)
                                           (cons (list r t) t*)))))))
              ((b t) (infer-expr b (append
                                    (map (lambda (x t) (cons x (cadr t))) x t*)
                                    env))))
             (return `(kernel-r (vec ,r ,t) ,r
                                (((,x ,(map cadr t*))
                                  (,e (vec . ,t*))) ...)
                                ,b)
                     `(vec ,r ,t))))
       ((call ,f ,e* ...) (guard (ident? f))
        (let ((t  (make-tvar (gensym 'rt)))
              (ft (lookup f env)))
          (do* (((e* t*) (infer-expr* e* env))
                ((_  __) (require-type `(var ,f) env `(,t* -> ,t))))
               (return `(call (var (,t* -> ,t) ,f) ,e* ...) t))))
       ((do ,e)
        (do* (((e t) (infer-expr e env)))
             (return `(do ,e) t)))
       ((match ,e
          ((,tag ,x* ...) ,e*) ...)
        ;; This might be a little tricky, depending on how much
        ;; information we have to start with. If the type of e is
        ;; known at this point, it's easy. However, if we don't know
        ;; if yet (for example, the value was passed in as a
        ;; parameter), we might have to infer the type based on the
        ;; constructors given.
        (match (lookup-type-tags tag env)
          ((,te . ,typedef)
           (do* (((e _) (require-type e env te))
                 ((e* t)
                  (let check-arms ((tag tag)
                                   (x* x*)
                                   (e* e*)
                                   (typedef typedef))
                    (match `(,tag ,x* ,e*)
                      (((,tag . ,tag*) (,x* . ,x**) (,e* . ,e**))
                       (let-values (((constructor rest)
                                     (partition (lambda (x)
                                                  (eq? (car x) tag))
                                                typedef)))
                         (match constructor
                           (((,_ ,t* ...))
                            (do* (((e**^ t) (check-arms tag* x** e** rest))
                                  ((e^ _) (require-type e* (append
                                                            (map cons x* t*)
                                                            env)
                                                        t)))
                                 (return (cons e^ e**^) t))))))
                      ((() () ()) (return '() (make-tvar (gensym 'tmatch))))))))
                (return `(match ,t ,e ((,tag ,x* ...) ,e*) ...) t)))))
        )))
  
  (define infer-body infer-expr)

  (define (make-top-level-env decls)
    (append
     (apply append
            (map (lambda (d)
                   (match d
                     ((fn ,name (,[make-tvar -> var*] ...) ,body)
                      `((,name . ((,var* ...) -> ,(make-tvar name)))))
                     ((define-datatype ,t
                        (,c ,t* ...) ...)
                      `((,type-tag ,t (,c ,t* ...) ...)
                        (,c (,t* ...) -> ,(map (lambda (_) t) c)) ...))
                     ((extern ,name . ,t)
                      (list (cons name t)))))
                decls))
     ;; Add some primitives
     '((sqrt (float) -> float))))

  (define (infer-module m)
    (match m
      ((module . ,decls)
       (let ((env (make-top-level-env decls)))
         (infer-decls decls env)))))

  (define (infer-decls decls env)
    (match decls
      (() (values '() '()))
      ((,d . ,d*)
       (let-values (((d* s) (infer-decls d* env)))
         (let-values (((d s) (infer-decl d env s)))
           (values (cons d d*) s))))))

  (define (infer-decl d env s)
    (match d
      ((extern . ,whatever)
       (values `(extern . ,whatever) s))
      ((define-datatype . ,whatever)
       (values `(define-datatype . ,whatever) s))
      ((fn ,name (,var* ...) ,body)
       ;; find the function definition in the environment, bring the
       ;; parameters into scope.
       (match (lookup name env)
         (((,t* ...) -> ,t)
          (let-values (((b t s)
                        ((infer-body body (append (map cons var* t*) env))
                         body t s)))
            (values
             `(fn ,name (,var* ...) ((,t* ...) -> ,t) ,b)
             s)))))))

  (define (lookup x e)
    (cdr (assq x e)))

  (define (lookup-type t e)
    (match e
      (((,tag ,name . ,t) . e^)
       (guard (and (eq? tag type-tag) (eq? name t)))
       t)
      ((,e . ,e^)
       (lookup-type t e^))
      (() (error 'lookup-type "Type not found" t))))

  (define (lookup-type-tags tags e)
    (match e
       (()
        (error 'lookup-type-tags "Could not find type from constructors" tags))
       (((,tag ,name (,tag* . ,t) ...) . ,rest)
        (guard (and (eq? tag type-tag)
                    (set-equal? tags tag*)))
        `(,name (,tag* . ,t) ...))
       ((,e . ,e*) (lookup-type-tags tags e*))))
  
  (define (ground-module m s)
    (if (verbose) (begin (pretty-print m) (newline) (display s) (newline)))
    
    (match m
      ((module ,[(lambda (d) (ground-decl d s)) -> decl*] ...)
       `(module ,decl* ...))))

  (define (ground-decl d s)
    (match d
      ((extern . ,whatever) `(extern . ,whatever))
      ((define-datatype . ,whatever) `(define-datatype . ,whatever))
      ((fn ,name (,var ...)
           ,[(lambda (t) (ground-type t s)) -> t]
           ,[(lambda (e) (ground-expr e s)) -> body])
       (let* ((region-params (free-regions-type t))
              (body-regions (free-regions-expr body))
              (local-regions (difference body-regions region-params)))
       `(fn ,name (,var ...) ,t (let-region ,local-regions ,body))))))

  (define (region-name r)
    (if (rvar? r)
        (rvar-name r)
        r))
  
  (define (ground-type t s)
    (let ((t (walk-type t s)))
      (if (tvar? t)
          (let ((t^ (assq t s)))
            (if t^
                (case (cdr t^)
                  ;; We have a free variable that's constrained as
                  ;; Numeric, so ground it as an integer.
                  ((Numeric) 'int))
                (error 'ground-type "free type variable" t)))
          (match t
            (,prim (guard (symbol? prim)) prim)
            ((vec ,r ,t) `(vec ,(region-name r) ,(ground-type t s)))
            ((ptr ,t) `(ptr ,(ground-type t s)))
            (((,[(lambda (t) (ground-type t s)) -> t*] ...) -> ,t)
             `((,t* ...) -> ,(ground-type t s)))
            (,else (error 'ground-type "unsupported type" else))))))

  (define (ground-expr e s)
    (let ((ground-type (lambda (t) (ground-type t s))))
      (match e
        ((int ,n) `(int ,n))
        ((float ,f) `(float ,f))
        ;; This next line is cheating, but it should get us through
        ;; the rest of the compiler.
        ((num ,n) `(int ,n))
        ((char ,c) `(char ,c))
        ((str ,s) `(str ,s))
        ((bool ,b) `(bool ,b))
        ((var ,[ground-type -> t] ,x) `(var ,t ,x))
        ((int->float ,[e]) `(int->float ,e))
        ((,op ,[ground-type -> t] ,[e1] ,[e2])
         (guard (or (relop? op) (binop? op)))
         `(,op ,t ,e1 ,e2))
        ((print ,[ground-type -> t] ,[e]) `(print ,t ,e))
        ((print ,[ground-type -> t] ,[e] ,[f]) `(print ,t ,e ,f))
        ((println ,[ground-type -> t] ,[e]) `(println ,t ,e))
        ((assert ,[e]) `(assert ,e))
        ((iota-r ,r ,[e]) `(iota-r ,(region-name (walk r s)) ,e))
        ((iota ,[e]) `(iota ,e))
        ((make-vector ,[ground-type -> t] ,[len] ,[val])
         `(make-vector ,t ,len ,val))
        ((let ((,x ,[ground-type -> t] ,[e]) ...) ,[b])
         `(let ((,x ,t ,e) ...) ,b))
        ((for (,x ,[start] ,[end] ,[step]) ,[body])
         `(for (,x ,start ,end ,step) ,body))
        ((while ,[t] ,[b]) `(while ,t ,b))
        ((vector ,[ground-type -> t] ,[e*] ...)
         `(vector ,t ,e* ...))
        ((length ,[e]) `(length ,e))
        ((vector-ref ,[ground-type -> t] ,[v] ,[i])
         `(vector-ref ,t ,v ,i))
        ((kernel-r ,[ground-type -> t] ,r
           (((,x ,[ground-type -> ta*]) (,[e] ,[ground-type -> ta**])) ...)
           ,[b])
         `(kernel-r ,t ,(region-name (walk r s))
                    (((,x ,ta*) (,e ,ta**)) ...) ,b))
        ((reduce ,[ground-type -> t] + ,[e]) `(reduce ,t + ,e))
        ((set! ,[x] ,[e]) `(set! ,x ,e))
        ((begin ,[e*] ...) `(begin ,e* ...))
        ((if ,[t] ,[c] ,[a]) `(if ,t ,c ,a))
        ((if ,[t] ,[c]) `(if ,t ,c))
        ((return) `(return))
        ((return ,[e]) `(return ,e))
        ((call ,[f] ,[e*] ...) `(call ,f ,e* ...))
        ((do ,[e]) `(do ,e))
        ((let-region (,r* ...) ,[e]) `(let-region (,r* ...) ,e))
        ((match ,[ground-type -> t] ,[e]
                ((,tag . ,x) ,[e*]) ...)
         `(match ,t ,e ((,tag . ,x) ,e*) ...))
        )))

  (define-match free-regions-expr
    ((var ,[free-regions-type -> t] ,x) t)
    ((int ,n) '())
    ((float ,f) '())
    ((char ,c) '())
    ((bool ,b) '())
    ((str ,s) '())
    ((int->float ,[e]) e)
    ((assert ,[e]) e)
    ((print ,[free-regions-type -> t] ,[e]) (union t e))
    ((print ,[free-regions-type -> t] ,[e] ,[f]) (union t e f))
    ((println ,[free-regions-type -> t] ,[e]) (union t e))
    ((,op ,[free-regions-type -> t] ,[rhs] ,[lhs])
     (guard (or (binop? op) (relop? op)))
     (union t lhs rhs))
    ((vector ,[free-regions-type -> t] ,[e*] ...)
     (union t (apply union e*)))
    ((length ,[e]) e)
    ((vector-ref ,[free-regions-type -> t] ,[x] ,[i]) (union t x i))
    ((iota-r ,r ,[e]) (set-add e r))
    ((make-vector ,[free-regions-type -> t] ,[len] ,[val])
     (union t len val))
    ((kernel-r ,[free-regions-type -> t] ,r
       (((,x ,[free-regions-type -> t*]) (,xs ,[free-regions-type -> ts*])) ...)
       ,[b])
     (set-add (union b t (apply union (append t* ts*))) r))
    ((reduce ,[free-regions-type -> t] ,op ,[e]) (union t e))
    ((set! ,[x] ,[e]) (union x e))
    ((begin ,[e*] ...) (apply union e*))
    ((let ((,x ,[free-regions-type -> t] ,[e]) ...) ,[b])
     (union b (apply union (append t e))))
    ((for (,x ,[start] ,[end] ,[step]) ,[body])
     (union start end step body))
    ((while ,[t] ,[e]) (union t e))
    ((if ,[t] ,[c] ,[a]) (union t c a))
    ((if ,[t] ,[c]) (union t c))
    ((call ,[e*] ...) (apply union e*))
    ((do ,[e]) e)
    ((let-region (,r* ...) ,[e])
     (difference e r*))
    ((match ,[free-regions-type -> t] ,[e]
            (,p ,[e*]) ...)
     (apply union `(,t ,e . ,e*)))
    ((return) '())
    ((return ,[e]) e))

  (define-match free-regions-type
    ((vec ,r ,[t]) (set-add t r))
    (((,[t*] ...) -> ,[t]) (union t (apply union t*)))
    ((ptr ,[t]) t)
    (() '())
    (,else (guard (symbol? else)) '()))
)
