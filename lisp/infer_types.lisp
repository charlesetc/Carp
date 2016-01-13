
;; The type env is bindings from variable names to types or variables, i.e. {:x :int, :y "t10"}
(defn type-env-extend (type-env args)
  (let [new-env (copy type-env)]
    (do (reduce (fn (_ pair) (dict-set! new-env (nth pair 0) (nth pair 1)))
                nil
                (map2 list (map :name args) (map :type args)))
        new-env)))

(defn is-self-recursive? (type-env app-f-name)
  (let [x (get-maybe type-env app-f-name)]
    (do
      ;;(println (str "app-f: " app-f-name ", x: " x))
      (= x :self))))

(defn get-type-of-symbol (type-env sym)
  (let [lookup (get-maybe type-env sym)]
    (if (= () lookup)
      (let [global-lookup (eval sym)]
        (type global-lookup))
      lookup)))

(defn math-op? (op)
  (contains? '(+ - * /) op))

(defn generate-constraints-internal (constraints ast type-env)
  (do
    ;;(println "gen constrs: \n" ast)
    (match (get ast :node)

           :function (let [extended-type-env (type-env-extend type-env (get ast :args))
                           extended-type-env-2 (let [fn-name (get-maybe ast :name)]
                                                 (if (string? fn-name)
                                                   (assoc extended-type-env fn-name :self)
                                                   extended-type-env))
                           new-constraints (generate-constraints-internal constraints (:body ast) extended-type-env-2)
                           func-ret-constr {:a (get-in ast '(:type 2)) ;; the return type of the arrow type
                                            :b (get-in ast '(:body :type))
                                            :doc (str "func-ret-constr")}
                           func-arg-constrs (map2 (fn (a b) {:a a :b b :doc "func-arg"})
                                                  (map :type (:args ast))
                                                  (get-in ast '(:type 1)))]
                       (concat func-arg-constrs (cons func-ret-constr new-constraints)))

           :app (let [ret-constr {:a  (get ast :type) :b (get-in ast '(:head :type 2)) :doc "ret-constr for :app"}
                      arg-constrs (map2 (fn (a b) {:a a :b b :doc "app-arg"}) (get-in ast '(:head :type 1)) (map :type (:tail ast)))
                      func-constrs (let [app-f-sym (get-in ast '(:head :value))
                                         app-f-name (str app-f-sym)
                                         app-f (eval app-f-sym)]
                                    (if (foreign? app-f)
                                      (list {:a (get-in ast '(:head :type)) :b (signature app-f) :doc "func-app"})
                                      (if (is-self-recursive? type-env app-f-name)
                                        () ;; no constraints needed when the function is calling itself
                                        (do (println (str "Calling non-baked function: " app-f-name " of type " (type app-f-sym) "\nWill bake it now!"))
                                            (bake-internal (new-builder) app-f-name (code (eval app-f-name)) '())
                                            (println (str "Baking done, will resume job."))
                                            (list {:a (get-in ast '(:head :type)) :b (signature (eval app-f-name)) :doc "freshly baked func-app"}))
                                      )))
                      tail-constrs (reduce (fn (constrs tail-form) (generate-constraints-internal constrs tail-form type-env))
                                           '() (:tail ast))
                      new-constraints (concat tail-constrs func-constrs (cons ret-constr arg-constrs))]
                  (concat new-constraints constraints))

           :literal (let [val (:value ast)]
                      (if (symbol? val) ;; if it's a symbol it's a lookup
                        (cons {:a (get ast :type)
                               :b (get-type-of-symbol type-env val)
                               :doc (str "lit-constr, lookup " val)} constraints)
                        constraints)) ;; other literals don't need constraints, just return unchanged constraints

           :binop (let [x0 (generate-constraints-internal constraints (get ast :a) type-env)
		        x1 (generate-constraints-internal x0 (get ast :b) type-env)
		        ;;tvar (gen-typevar)
                        ;;left-arg-constr {:a tvar :b (get-in ast '(:a :type)) :doc "left-arg-constr"}
                        ;;right-arg-constr {:a tvar :b (get-in ast '(:b :type)) :doc "right-arg-constr"}
			;;ret-constr {:a tvar :b (:type ast)}
                        same-arg-type-constr {:a (get-in ast '(:a :type)) :b (get-in ast '(:b :type)) :doc "same-arg-type-constr"}
                        maybe-constr (if (math-op? (:op ast))
                                       (list {:a (get-in ast '(:a :type)) :b (:type ast)})
                                       ())
			]
                    ;;(concat x1 (list left-arg-constr right-arg-constr ret-constr)))
                    (concat maybe-constr (cons same-arg-type-constr x1)))

           :if (let [x0 (generate-constraints-internal constraints (get ast :a) type-env)
                     x1 (generate-constraints-internal x0 (get ast :b) type-env)
                     x2 (generate-constraints-internal x1 (get ast :expr) type-env)
                     left-result-constr {:a (get-in ast '(:a :type)) :b (:type ast)}
                     right-result-constr {:a (get-in ast '(:b :type)) :b (:type ast)}
                     expr-must-be-bool {:a :bool :b (get-in ast '(:expr :type))}]
                 (concat x2 (list
                             expr-must-be-bool
                             left-result-constr
                             right-result-constr)))

           :do (let [x0 (reduce (fn (constrs form) (generate-constraints-internal constrs form type-env))
                                constraints (:forms ast))
                     ;;_ (log "count: " (count x0))
                     n (count (:forms ast))
                     ret-constr {:a (:type ast) :b (get-in ast (list :forms (- n 1) :type)) :doc "do-ret-constr"}]
                 (cons ret-constr x0))

           :let (let [bindings (:bindings ast)
                      extended-type-env (reduce (fn (e b) (assoc e (:name b) (get-in b '(:value :type)))) type-env bindings)
                      ;;_ (println "Extended type env: " extended-type-env)
                      let-constr {:a (:type ast) :b (get-in ast '(:body :type)) :doc "let-constr"}
                      bindings-constr (mapcat (fn (binding) (let [bind-constr {:a (:type binding) :b (get-in binding '(:value :type))}
                                                                  value-constrs (generate-constraints-internal constraints (:value binding) type-env)]
                                                              (cons bind-constr value-constrs)))
                                              bindings)
                      body-constrs (generate-constraints-internal constraints (:body ast) extended-type-env)]
                  (cons let-constr (concat bindings-constr body-constrs)))

           :while (let [x0 (generate-constraints-internal constraints (get ast :body) type-env)
                        x1 (generate-constraints-internal x0 (get ast :expr) type-env)
                        body-result-constr {:a (get-in ast '(:body :type)) :b (:type ast)}
                        expr-must-be-bool {:a :bool :b (get-in ast '(:expr :type))}]
                    (concat x1 (list expr-must-be-bool )))

           :null constraints
           
           _ constraints
           )))

(defn generate-constraints (ast)
  (let [constraints '()]
    (generate-constraints-internal constraints ast {})))

(def gencon generate-constraints)



(defn lookup (substs b)
  (let [val (get-maybe substs b)]
    (if (= () val)
      b
      (if (= b val)
          val
          (if (= :string (type val))
            (lookup substs val) ; keep looking
            val)) ; found the actual type
      )))


;; Replacement function for replacing "from the right" in an associative map2
;; Example usage:
;; (replace-subst-from-right {:a :b, :c :d} :d :e)
;; =>
;; {:c :e, 
;;  :a :b}

(defn maybe-replace-binding (key value replace-this with-this)
  (if (= replace-this value)
    {:key key :value with-this}
    {:key key :value value}))

(defn replace-subst-from-right (substs existing b)
  (reduce (fn (new-substs pair) (assoc new-substs (:key pair) (:value pair)))
          {}
          (map2 (fn (k v) (maybe-replace-binding k v existing b)) (keys substs) (values substs))))

(def log-substs false)

(defn typevar? (x) (string? x))

(defn extend-substitutions (substs a b)
  (do (when log-substs (println (str "\n" substs)))
      (when log-substs (println (str "\nEXTEND " a " " b)))
      (let [existing (get-maybe substs a)]
        (if (= () existing)
          (do (when log-substs (println (str "New substitution: " a " = " b)))
              (assoc substs a (lookup substs b)))
          (do (when log-substs (println (str "Found existing substitution for " a ", it was = " existing)))
              (let [replacement (lookup substs b)]
                (do
                  (when log-substs (println (str "Replacement: " replacement)))
                  (if (unify existing replacement)
                    (do (when log-substs (println "OK, replacement is the same."))
                        substs)
                    (if (typevar? replacement)
                      (if (typevar? (lookup substs a))
                        (do (when log-substs (println "Replace from right"))
                            (replace-subst-from-right substs existing replacement))
                        (do (when log-substs (println "Ignore this one"))
                            substs))
                      (if (typevar? existing)
                        (do (when log-substs (println "Replace existing typevar from right"))
                            (replace-subst-from-right substs existing replacement))
                        (error (str "Type checking failed, can't unify " replacement " with " existing))))))))))))

;; \nSubstitutions:\n" substs

(defn unify (a b)
  (if (and (list? a) (list? b))
    (all? true? (map2 unify a b))
    (if (= :any a)
      true
      (if (= :any b)
        true
        (= a b))))) ;; else clause

(defn solve-list (substs a-list b-list)
  (match (list a-list b-list)
         (() ()) substs
         ((a & as) (b & bs)) (solve (solve substs a b) as bs)
         _ (error (str "Lists not matching: " a-list " - vs - " b-list ", substs: \n" substs))))

(defn solve (substs a b)
  (if (and (list? a) (list? b))
    (solve-list substs a b)
    (if (string? a)
      (extend-substitutions substs a b)
      substs)))

(defn solve-contraint-internal (substs constraint)
  (let [a (:a constraint)
        b (:b constraint)]
    (solve (solve substs a b) b a))) ; Solving from both directions!

;; Returns a substitution map from type variables to actual types
(defn solve-constraints (constraints)
  (reduce solve-contraint-internal {} constraints))



(defn make-type-list (substs typevars)
  (map (fn (t) (if (string? t) (get-type substs t)
                   (if (list? t)
                     (make-type-list substs t)
                     t)))
       typevars))

(defn get-type (substs typevar)
  (if (list? typevar)
    (make-type-list substs typevar)
    (let [maybe-type (get-maybe substs typevar)]
      (if (= maybe-type ())
        typevar ;; lookup failed, there is no substitution for this type variable (= it's generic)
        maybe-type))))

(defn assign-types-to-list (asts substs)
  (map (fn (x) (assign-types x substs)) asts))

(defn assign-types-to-binding (b substs)
  (let [x0 (assoc b :type (get-type substs (:type b)))
        x1 (assoc x0 :value (assign-types (:value b) substs))]
    x1))

(defn assign-types (ast substs)
  (match (:node ast)
         :function (let [a (assoc ast :type (get-type substs (:type ast)))
                         b (assoc a :body (assign-types (:body ast) substs))
                         c (assoc b :args (assign-types-to-list (:args ast) substs))]
                     c)

         :app (let [app-ret-type (get-type substs (:type ast))]
                (assoc (assoc (assoc ast :type app-ret-type)
                              :head (assign-types (:head ast) substs))
                       :tail (map (fn (x) (assign-types x substs)) (:tail ast))))

         :literal (assoc ast :type (get-type substs (:type ast)))

         :arg (assoc ast :type (get-type substs (:type ast)))

         :binop (let [x0 (assoc ast :type (get-type substs (:type ast)))
                      x1 (assoc x0 :a (assign-types (:a ast) substs))
                      x2 (assoc x1 :b (assign-types (:b ast) substs))]
                  x2)

         :if (let [x0 (assoc ast :type (get-type substs (:type ast)))
                   x1 (assoc x0 :a (assign-types (:a ast) substs))
                   x2 (assoc x1 :b (assign-types (:b ast) substs))
                   x3 (assoc x2 :expr (assign-types (:expr ast) substs))]
               x3)

         :do (let [x0 (assoc ast :forms (map (fn (x) (assign-types x substs)) (:forms ast)))
                   x1 (assoc x0 :type (get-type substs (:type ast)))]
               x1)

         :let (let [x0 (assoc ast :bindings (map (fn (b) (assign-types-to-binding b substs)) (:bindings ast)))
                    x1 (assoc x0 :body (assign-types (:body x0) substs))
                    x2 (assoc x1 :type (get-type substs (:type ast)))]
                x2)
         
         :while (let [x0 (assoc ast :type (get-type substs (:type ast)))
                      x1 (assoc x0 :body (assign-types (:body ast) substs))
                      x2 (assoc x1 :expr (assign-types (:expr ast) substs))]
               x2)

         :null ast

	 :c-code (assoc ast :type (get-type substs (:type ast)))

         _ (error (str "Can't assign types to ast node " ast))))

;; x1 (assoc-in x0 '(:body :type) (get-type substs (get-in x0 '(:body :type))))

(defn infer-types (ast)
  (let [constraints (generate-constraints ast)
        substs (solve-constraints constraints)
        ast-typed (assign-types ast substs)]
    ast-typed))
