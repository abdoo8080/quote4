import Lean
import Qq.ForLean.ReduceEval
import Qq.Reflect
import Qq.Typ
open Lean Meta Std

namespace Qq

namespace Impl

def evalBinderInfoData (e : Expr) : MetaM BinderInfo :=
  if e.isAppOfArity ``Expr.mkDataForBinder 7 then
    reduceEval (e.getArg! 6)
  else
    throwFailedToEval e

def evalNonDepData (e : Expr) : MetaM Bool :=
  if e.isAppOfArity ``Expr.mkDataForLet 7 then
    reduceEval (e.getArg! 6)
  else
    throwFailedToEval e

structure UnquoteState where
  -- maps quoted expressions (of type Level) in the old context to level parameter names in the new context
  levelSubst : HashMap Expr Level := {}

  -- maps quoted expressions (of type Expr) in the old context to expressions in the new context
  exprSubst : HashMap Expr Expr := {}

  -- new unquoted local context
  unquoted := LocalContext.empty

  -- maps free variables in the new context to expressions in the old context (of type Expr)
  exprBackSubst : HashMap Expr Expr := {}

  -- maps free variables in the new context to levels in the old context (of type Level)
  levelBackSubst : HashMap Level Expr := {}

  levelNames : List Name := []

abbrev UnquoteM := StateT UnquoteState MetaM

def mkAbstractedLevelName (e : Expr) : MetaM Name :=
  e.getAppFn.constName?.getD `udummy

partial def unquoteLevel (e : Expr) : UnquoteM Level := do
  let e ← whnf e
  match (← get).levelSubst.find? e with
    | some l => return l
    | _ => ()
  if e.isAppOfArity ``Level.zero 1 then levelZero
  else if e.isAppOfArity ``Level.succ 2 then mkLevelSucc (← unquoteLevel (e.getArg! 0))
  else if e.isAppOfArity ``Level.max 3 then mkLevelMax (← unquoteLevel (e.getArg! 0)) (← unquoteLevel (e.getArg! 1))
  else if e.isAppOfArity ``Level.imax 3 then mkLevelIMax (← unquoteLevel (e.getArg! 0)) (← unquoteLevel (e.getArg! 1))
  else if e.isAppOfArity ``Level.param 2 then mkLevelParam (← reduceEval (e.getArg! 0))
  else if e.isAppOfArity ``Level.mvar 2 then mkLevelMVar (← reduceEval (e.getArg! 0))
  else
    let name ← mkAbstractedLevelName e
    let l := mkLevelParam name
    modify fun s => { s with
      levelSubst := s.levelSubst.insert e l
      levelBackSubst := s.levelBackSubst.insert l e
    }
    l

partial def unquoteLevelList (e : Expr) : UnquoteM (List Level) := do
  let e ← whnf e
  if e.isAppOfArity ``List.nil 1 then
    []
  else if e.isAppOfArity ``List.cons 3 then
    (← unquoteLevel (e.getArg! 1)) :: (← unquoteLevelList (e.getArg! 2))
  else
    throwFailedToEval e

def mkAbstractedName (e : Expr) : MetaM Name :=
  e.getAppFn.constName?.getD `dummy

partial def unquoteExpr (e : Expr) : UnquoteM Expr := do
  if e.isAppOf ``reflect then return e.getArg! 2
  let e ← whnf e
  match e with
    | Expr.proj ``QQ 0 a _ =>
      match (← get).exprSubst.find? a with
        | some e => return e
        | _ =>
          let ta ← inferType a
          let ta ← whnf ta
          if !ta.isAppOfArity ``QQ 1 then throwError "unquoteExpr: {ta}"
          let ty ← unquoteExpr (ta.getArg! 0)
          let fvarId ← mkFreshId
          let name ← mkAbstractedName a
          let fv := mkFVar fvarId
          modify fun s => { s with
            unquoted := s.unquoted.mkLocalDecl fvarId name ty
            exprSubst := s.exprSubst.insert a fv
            exprBackSubst := s.exprBackSubst.insert fv e
          }
          return fv
    | _ => ()
  let Expr.const c _ _ ← pure e.getAppFn | throwError "unquoteExpr: {e}"
  let nargs := e.getAppNumArgs
  match c, nargs with
    | ``Expr.bvar, 2 => mkBVar (← reduceEval (e.getArg! 0))
    | ``Expr.fvar, 2 => mkFVar (← reduceEval (e.getArg! 0))
    | ``Expr.mvar, 2 => mkMVar (← reduceEval (e.getArg! 0))
    | ``Expr.sort, 2 => mkSort (← unquoteLevel (e.getArg! 0))
    | ``Expr.const, 3 => mkConst (← reduceEval (e.getArg! 0)) (← unquoteLevelList (e.getArg! 1))
    | ``Expr.app, 3 => mkApp (← unquoteExpr (e.getArg! 0)) (← unquoteExpr (e.getArg! 1))
    | ``Expr.lam, 4 =>
      mkLambda (← reduceEval (e.getArg! 0)) (← evalBinderInfoData (e.getArg! 3))
        (← unquoteExpr (e.getArg! 1))
        (← unquoteExpr (e.getArg! 2))
    | ``Expr.forallE, 4 =>
      mkForall (← reduceEval (e.getArg! 0)) (← evalBinderInfoData (e.getArg! 3))
        (← unquoteExpr (e.getArg! 1))
        (← unquoteExpr (e.getArg! 2))
    | ``Expr.letE, 5 =>
      mkLet (← reduceEval (e.getArg! 0)) (← unquoteExpr (e.getArg! 1)) (← unquoteExpr (e.getArg! 2))
        (← unquoteExpr (e.getArg! 3)) (← evalNonDepData (e.getArg! 4))
    | ``Expr.lit, 2 => mkLit (← reduceEval (e.getArg! 0))
    | ``Expr.proj, 4 =>
      mkProj (← reduceEval (e.getArg! 0)) (← reduceEval (e.getArg! 1)) (← unquoteExpr (e.getArg! 2))
    | _, _ => throwError "unquoteExpr: {e}"

def unquoteLCtx : UnquoteM Unit := do
  for ldecl in (← getLCtx) do
    let fv := ldecl.toExpr
    let ty := ldecl.type
    let whnfTy ← whnf ty
    if whnfTy.isAppOf ``QQ then
      let qTy := whnfTy.appArg!
      let newTy ← unquoteExpr qTy
      modify fun s => { s with
        unquoted := s.unquoted.addDecl $
          LocalDecl.cdecl ldecl.index ldecl.fvarId ldecl.userName newTy ldecl.binderInfo
        exprBackSubst := s.exprBackSubst.insert fv (mkApp2 (mkConst ``QQ.quoted) qTy fv)
        exprSubst := s.exprSubst.insert fv fv
      }
    else if whnfTy.isAppOf ``Level then
      modify fun s => { s with
        levelNames := ldecl.userName :: s.levelNames
        levelSubst := s.levelSubst.insert fv (mkLevelParam ldecl.userName)
      }
    else
      let Level.succ u _ ← getLevel ty | ()
      let LOption.some inst ← trySynthInstance (mkApp (mkConst ``Reflect [u]) ty) | ()
      modify fun s => { s with
        unquoted := s.unquoted.addDecl ldecl
        exprBackSubst := s.exprBackSubst.insert fv (mkApp3 (mkConst ``reflect [u]) ty inst fv)
        exprSubst := s.exprSubst.insert fv fv
      }

def determineLocalInstances (lctx : LocalContext) : MetaM LocalInstances := do
  let mut localInsts : LocalInstances := {}
  for ldecl in lctx do
    match (← isClass? ldecl.type) with
      | some c => localInsts := localInsts.push { className := c, fvar := ldecl.toExpr }
      | none => ()
  localInsts

def isLevelFVar (n : Name) : MetaM (Option Expr) := do
  match (← getLCtx).findFromUserName? n with
    | none => none
    | some decl =>
      if ← isDefEq decl.type (mkConst ``Level) then
        some decl.toExpr
      else
        none

abbrev QuoteM := ReaderT UnquoteState MetaM

def quoteLevel : Level → QuoteM Expr
  | Level.zero _ => mkConst ``levelZero
  | Level.succ u _ => do mkApp (mkConst ``mkLevelSucc) (← quoteLevel u)
  | l@(Level.mvar n _) => throwError "level mvars not supported {l}"
  | Level.max a b _ => do mkApp2 (mkConst ``mkLevelMax) (← quoteLevel a) (← quoteLevel b)
  | Level.imax a b _ => do mkApp2 (mkConst ``mkLevelIMax) (← quoteLevel a) (← quoteLevel b)
  | l@(Level.param n _) => do
    match (← read).levelBackSubst.find? l with
      | some e => e
      | none =>
        match ← isLevelFVar n with
          | some fv => fv
          | none =>
            throwError "universe parameter {n} not of type Level"

def quoteLevelList : List Level → QuoteM Expr
  | [] => mkApp (mkConst ``List.nil [levelZero]) (mkConst ``Level)
  | l::ls => do
    mkApp3 (mkConst ``List.cons [levelZero]) (mkConst ``Level)
      (← quoteLevel l) (← quoteLevelList ls)

def quoteExpr : Expr → QuoteM Expr
  | Expr.bvar i _ => mkApp (mkConst ``mkBVar) (reflect i)
  | e@(Expr.fvar i _) => do
    let some r ← (← read).exprBackSubst.find? e | throwError "unknown free variable {e}"
    r
  | e@(Expr.mvar i _) => throwError "resulting term contains metavariable {e}"
  | Expr.sort u _ => do mkApp (mkConst ``mkSort) (← quoteLevel u)
  | Expr.const n ls _ => do mkApp2 (mkConst ``mkConst) (reflect n) (← quoteLevelList ls)
  | Expr.app a b _ => do mkApp2 (mkConst ``mkApp) (← quoteExpr a) (← quoteExpr b)
  | Expr.lam n t b d => do
    mkApp4 (mkConst ``mkLambda) (reflect n) (reflect d.binderInfo) (← quoteExpr t) (← quoteExpr b)
  | Expr.forallE n t b d => do
    mkApp4 (mkConst ``mkForall) (reflect n) (reflect d.binderInfo) (← quoteExpr t) (← quoteExpr b)
  | Expr.letE n t v b d => do
    mkApp5 (mkConst ``mkLet) (reflect n) (← quoteExpr t) (← quoteExpr v) (← quoteExpr b) (reflect d.nonDepLet)
  | Expr.lit l _ => mkApp (mkConst ``mkLit) (reflect l)
  | Expr.proj n i e _ => do mkApp3 (mkConst ``mkProj) (reflect n) (reflect i) (← quoteExpr e)
  | e => throwError "quoteExpr todo {e}"

def unquoteMVars (mvars : Array MVarId) : UnquoteM (HashMap MVarId Expr × HashMap MVarId (QuoteM Expr)) := do
  let mut exprMVarSubst : HashMap MVarId Expr := HashMap.empty
  let mut mvarSynth : HashMap MVarId (QuoteM Expr) := {}

  unquoteLCtx

  let lctx ← getLCtx
  for mvar in mvars do
    let mdecl ← (← getMCtx).getDecl mvar
    if !(lctx.isSubPrefixOf mdecl.lctx && mdecl.lctx.isSubPrefixOf lctx) then
      throwError "incompatible metavariable {mvar}\n{MessageData.ofGoal mvar}"

    let ty ← whnf mdecl.type
    let ty ← instantiateMVars ty
    if ty.isAppOf ``QQ then
      let et := ty.getArg! 0
      let newET ← unquoteExpr et
      let newLCtx := (← get).unquoted
      let newLocalInsts ← determineLocalInstances newLCtx
      let exprBackSubst := (← get).exprBackSubst
      let newMVar ← mkFreshExprMVarAt newLCtx newLocalInsts newET
      modify fun s => { s with exprSubst := s.exprSubst.insert (mkMVar mvar) newMVar }
      exprMVarSubst := exprMVarSubst.insert mvar newMVar
      mvarSynth := mvarSynth.insert mvar do
        mkApp2 (mkConst ``QQ.qq) et (← quoteExpr (← instantiateMVars newMVar))
    else if ty.isSort then
      let u ← mkFreshLevelMVar
      let newLCtx := (← get).unquoted
      let newLocalInsts ← determineLocalInstances newLCtx
      let exprBackSubst := (← get).exprBackSubst
      let newMVar ← mkFreshExprMVarAt newLCtx newLocalInsts (mkSort u)
      modify fun s => { s with exprSubst := s.exprSubst.insert (mkMVar mvar) newMVar }
      exprMVarSubst := exprMVarSubst.insert mvar newMVar
      mvarSynth := mvarSynth.insert mvar do
        mkApp (mkConst ``QQ) (← quoteExpr (← instantiateMVars newMVar))
    else if ty.isAppOf ``Level then
      let newMVar ← mkFreshLevelMVar
      modify fun s => { s with levelSubst := s.levelSubst.insert (mkMVar mvar) newMVar }
      mvarSynth := mvarSynth.insert mvar do
        quoteLevel (← instantiateLevelMVars newMVar)
    else
      throwError "unsupported type {ty}"

  (exprMVarSubst, mvarSynth)

def lctxHasMVar : MetaM Bool := do
  (← getLCtx).anyM fun decl => do (← instantiateLocalDeclMVars decl).hasExprMVar

end Impl

open Lean.Elab Lean.Elab.Tactic Lean.Elab.Term Impl

def Impl.macro (t : Syntax) (expectedType : Expr) : TermElabM Expr := do
  let lastId := (← mkFreshExprMVar expectedType).mvarId!
  let mvars := (← getMVars expectedType).push lastId
  let ((exprMVarSubst, mvarSynth), s) ← (unquoteMVars mvars).run {}

  let lastId := (exprMVarSubst.find! mvars.back).mvarId!
  let lastDecl ← Lean.Elab.Term.getMVarDecl lastId

  withLevelNames s.levelNames do
    resettingSynthInstanceCache do
      withLCtx lastDecl.lctx lastDecl.localInstances do
        let t ← Lean.Elab.Term.elabTerm t lastDecl.type
        let t ← ensureHasType lastDecl.type t
        synthesizeSyntheticMVars false
        if (← logUnassignedUsingErrorInfos (← getMVars t)) then
          throwAbortTerm
        assignExprMVar lastId t

    for newLevelName in (← getLevelNames) do
      if s.levelNames.contains newLevelName || (← isLevelFVar newLevelName).isSome then
        ()
      else if (← read).autoBoundImplicit then
        throwAutoBoundImplicitLocal newLevelName
      else
        throwError "unbound level param {newLevelName}"

  for mvar in mvars do
    let some synth ← mvarSynth.find? mvar | ()
    let mvar := mkMVar mvar
    let (true) ← isDefEq mvar (← synth s) | throwError "cannot assign metavariable {mvar}"

  instantiateMVars (mkMVar mvars.back)

scoped elab (name := Syntax_q) "q(" t:term ")" : term <= expectedType => do
  let expectedType ← instantiateMVars expectedType
  if expectedType.hasExprMVar then tryPostpone
  ensureHasType expectedType $ ← commitIfDidNotPostpone do
    let mut expectedType ← whnf expectedType
    if !expectedType.isAppOfArity ``QQ 1 then
      let u ← mkFreshExprMVar (mkConst ``Level)
      let u' := mkApp (mkConst ``mkSort) u
      let t ← mkFreshExprMVar (mkApp (mkConst ``QQ) u')
      expectedType := mkApp (mkConst ``QQ) (mkApp2 (mkConst ``QQ.quoted) u' t)
    Impl.macro t expectedType

scoped elab (name := Syntax_Q) "Q(" t:term ")" : term <= expectedType => do
  let expectedType ← instantiateMVars expectedType
  let (true) ← isDefEq expectedType (mkSort (mkLevelSucc levelZero)) |
    throwError "Q(.) has type Type, expected type is{indentExpr expectedType}"
  commitIfDidNotPostpone do Impl.macro t expectedType


/-
support `Q((← foo) ∨ False)`
-/

scoped syntax "Type" "(" "←" term ")" : term
scoped syntax "Sort" "(" "←" term ")" : term

private partial def expandLiftMethod : Syntax → StateT (Array $ Syntax × Syntax × Syntax) MacroM Syntax
  | stx@`(Q($x)) => stx
  | stx@`(q($x)) => stx
  | `(← $term) =>
    withFreshMacroScope do
      push (← `(a)) (← `(QQ _)) (← expandLiftMethod term)
      `(a)
  | `(Type (← $term)) =>
    withFreshMacroScope do
      push (← `(u)) (← `(Level)) (← expandLiftMethod term)
      `(Type u)
  | `(Sort (← $term)) =>
    withFreshMacroScope do
      push (← `(u)) (← `(Level)) (← expandLiftMethod term)
      `(Sort u)
  | stx => match stx with
    | Syntax.node k args => do Syntax.node k (← args.mapM expandLiftMethod)
    | stx => stx

  where
    push i t l : StateT (Array $ Syntax × Syntax × Syntax) MacroM Unit :=
      modify fun s => s.push (i, t, l)

macro_rules
  | `(Q($t)) => do
    let (t, lifts) ← expandLiftMethod t #[]
    if lifts.isEmpty then Macro.throwUnsupported
    let mut t ← `(Q($t))
    for (a, ty, lift) in lifts do
      t ← `(let $a:ident : $ty := $lift; $t)
    t
  | `(q($t)) => do
    let (t, lifts) ← expandLiftMethod t #[]
    if lifts.isEmpty then Macro.throwUnsupported
    let mut t ← `(q($t))
    for (a, ty, lift) in lifts do
      t ← `(let $a:ident : $ty := $lift; $t)
    t
