

{-
This file is an absolute mess.  The whole point of this module is to keep our implementation as theoretically pure as possible.  
Abadi and Plotkin required a set of typed function symbols \Sigma(_,_) and an eval function eval :: \Sigma(A,B) \x Values_A \to Values_B.
They moreover require that for each function symbol f \in \Sigma(A,B) there is another function symbol f_R : \Sigma(A\x B,A).  However if \Sigma is 
non-empty then it's at least countably infinite.  

The trick we use here is to generate \Sigma from a simpler \Sigma.  We may input a finite set of function symbols \Sigma we generate ROP \Sigma from it.  
It is generated inductively by being the smallest set containing \Sigma and a new symbol R(f) for any function symbol in ROP \Sigma.  Then we close the loop.
Suppose we have a starting \Sigma, and a function that produces ordinary TraceTerms from elements of \Sigma that have type A\x B \to A  in context.  
The idea is that if these ordinary TraceTerms are taken to be the term representing the reverse derivative of the symbol f, then we can evaluate 
the trace terms using a full, ordinary evaluation.  Thus we can evaluate all the symbols of the form R(f) with f \in \Sigma.  However we need to extend this 
to symbols of the form R(R(f)), R(R(R(f))), etc.  To do so, we use the fact that we can symbolically differentiate trace terms.  So given R(R(h)) where h is possibly R(...R(g)...)
we first obtain a trace term from R(h) by induction, and then we symbolically differentiate this trace term, and then finally, we evaluate the resulting trace term.

To summarize 
   eval_R(f,b) = eval(f,b)  is the ordinary eval whenever f \in \Sigma 
   eval_R(R(f),b) = eval-trace(fr(f),b)   where f \in \Sigma and fr(f) is our specified way of creating TraceTerms from function symbols. 
   eval_R(R(R(h)),b) = eval-trace(rdh,b)   where first rh is the trace term generated by induction and then rdh is the trace term obtained from symbolic differentiation.

We call a starting Sigma, together with a function fr that delivers TraceTerms from Sigma and an evaluation funtion on base elements of Sigma a PreoperationalStructure.  

The whole point of this module is that we extend this a PreoperationalStructure on Sigma to an OperationalStructure on ROP Sigma.  An operational structure has exactly what is required by Abadi and Plotkin.
  * an evaluation function on all symbols 
  * For each function symbol f a new function symbol R(f) with the required type.

-}
module OperationalStructure (PreOperationalStructure (..),OperationalStructure (..),convertPOP,SigmaR1(..),R1(..),Pred1(..),instanceOperationalStruct,instanceOpStruct1) where

import SDPLTerms
import ST
import Err 
import Data.Monoid
import SymbolicDifferentiation
import TraceEval
import R1Signature


import NotationalSums

import qualified Data.Map as M

import Control.Monad.Trans
import TraceState



-- | This module contains the interface for building an operational structure

data PreOperationalStructure s p a = POS {
    -- | ev_{T,U} : \Sigma(T,U) \x v_T \to v_U
    evop :: s -> (ClosedVal a) -> Err (ClosedVal a)
    -- | bev_T : \Pred(T) \x v_T \to val_{bool}
    , bevpred :: p -> (ClosedVal a) -> Err BVal
    , gettyop :: (s -> (LType,LType))
    -- | The idea of fr is that given an f it returns a trace term corresponding to v.R[f](a). 
    -- | However, the trace term will have free variables in it because it will be formed in 
    -- | context.  The idea is then that we have (a,v) \proves fr(f)  is a trace term.  Then 
    -- | Evaluation is eval(R[f],b) = trace-val(let (a,v) = b in fr(f)).
    , fR :: s -> String -> Trace s a
}

(.>) :: a -> (a -> b) ->  b 
x .> a = a x


opr ::  (s -> String -> Trace s a) -> (s -> String -> (String,Trace s a))
opr  fRR opn varname = (varname, fRR opn varname)



data OperationalStructure s p a = OS {
    ev :: s -> (ClosedVal a) -> Err (ClosedVal a),
    bev :: p -> (ClosedVal a) -> Err BVal,
    rr :: s -> s,
    opty :: s -> (LType,LType)
}

{-
Now we need to tie the knot.  We need to define an operational structure over the extended sigma = ROP sigma from a preoperational structure.
It will have 
    bev = bevpred 
    rr = R
    ev = eval as constructed below

-}
-- convertPOP :: (Show s,Show a,Monoid a) => PreOperationalStructure s p a -> OperationalStructure (ROP s) p a 
convertPOP :: (Show s,Show p,Show a,Monoid a) => PreOperationalStructure s p a -> OperationalStructure (ROP s) p a 
convertPOP struct = OS {
    ev = extendedEval struct,
    bev = bevpred struct,
    rr = bumpfByR,
    opty = \name -> 
        (
            case name of 
                Orig sym inty outty -> (inty,outty)
                R sym inty outty -> (inty,outty)
        )
}




-- still needed? -- maybe just for testing purposes
evalTrace :: (Show s,Show a,Monoid a) => PreOperationalStructure s p a -> String -> Int -> M.Map String (ClosedVal a) -> Trace s a -> Err (ClosedVal a)
evalTrace struct seedName0 fresh state term = runSTVal (evalTraceStateful struct term) (TS {locals = state, seedName = seedName0,freshName = fresh })

-- Some tests
egEvTraceTerm1 = TLet "x" Real (TConst (R1 3)) (TOp Sin (TVar "x"))
egEvTraceTerm1Evald = evalTrace instanceOpStruct1 "z" 0 M.empty egEvTraceTerm1
egBiggerEvalTerm = do 
        b5 <- makeSumTrace (Prod Real Real) (TPair Real Real (TVar "x") (TVar "y")) (TPair Real Real (TVar "z") (TVar "w"))
        let b4 = TLet "w" Real (TConst (R1 9)) b5 
        let b3 = TLet "z" Real (TConst (R1 2.1)) b4 
        let b2 = TLet "y" Real (TConst (R1 4)) b3 
        let b1 = TLet "x" Real (TConst (R1 3)) b2 
        return b1

egBiggerEvalTermEvaldSt = do 
    t <- egBiggerEvalTerm
    evalTraceStateful instanceOpStruct1 t
egBiggerEvalTermEvald = runSTVal egBiggerEvalTermEvaldSt (TS {locals = M.empty, seedName = "zz",freshName = 0 })

evalTraceStateful :: (Show a,Show s,Monoid a) => PreOperationalStructure s p a -> (Trace s a) -> ST (TState a) Err (ClosedVal a)
evalTraceStateful struct t = do
    -- wowee <- s 
    -- return $ trace ("Trace evaluating: " ++ show t ++ " Yields: " ++ show wowee) wowee
    --     where s = 
    case t of
        TVar x -> getVar x
        TConst a -> return $ CConst a
        TSum a b -> do 
            a' <- evalTraceStateful struct a 
            b' <- evalTraceStateful struct b 
            lift $ a' <>? b'
        TOp f m -> do 
            n <- evalTraceStateful struct m 
            lift $ (struct.>evop) f n
        TLet x _ n m -> do 
            n' <- evalTraceStateful struct n
            locs <- getLocals 
            setLocals $ M.insert x n' locs 
            m' <- evalTraceStateful struct m
            setLocals locs 
            return m'
        TNil -> return CNil 
        TPair tya tyb a b -> do 
            a' <- evalTraceStateful struct a 
            b' <- evalTraceStateful struct b 
            return $ CPair tya tyb a' b'
        TFst tya tyb a -> do 
            a' <- evalTraceStateful struct a 
            case a' of 
                CPair _ _  u v -> return u 
                _ -> lift $ Fail "Type error: TFst was applied to an object that did not evaluate to a pair" 
        TSnd tyb tya a -> do 
            a' <- evalTraceStateful struct a 
            case a' of 
                CPair _ _ u v -> return v
                _ -> lift $ Fail $ "Type error: TSnd was applied to an object that did not evaluate to a pair " ++ show a





abstev :: (Show s, Show p, Show a,Monad m,Monoid a) => PreOperationalStructure s p a -> (ROP s) -> ST (TState a) m (String,Trace s a)
abstev struct opname = do 
--   freshName <- freshVar -- freshName = (u,v)
  -- Then intent here is that freshName always
  freshName <- freshVar 
  case opname of 
    (Orig f _ _) -> return (freshName,TOp f (TVar freshName))
    -- (R (Orig f _ _)_ _) -> return $ opr (struct .> fR) f $ trace ("Abstev: " ++ show opname ++ " Yields: " ++ show (opr (struct .> fR) f freshName)) freshName
    (R (Orig f _ _) _ _) -> return $ opr (struct.>fR) f freshName 
    (R g@(R h tyu tyv) _ _) -> do 
      u <- freshVar 
      v <- freshVar 
      (z,m) <- abstev struct g 
      m' <- symbolicDiffStPre z tyu struct m (VVar u) (VVar v)
    --   symbolicDiffSt :: (Monad m,Monoid a) => String -> LType -> (s -> s) -> Trace s a -> Val a -> Val a -> ST (TState a) m (Trace s a)
      let n = TLet u tyu (TFst tyu tyv (TVar freshName)) (TLet v tyv (TSnd tyu tyv (TVar freshName)) m')
      return (freshName,n)
    --   return $ trace ("Abstev: " ++ show opname ++ " Yields: " ++ "(" ++ freshName ++ "," ++ show n ++")") (freshName,n)



-- symbolicDiffStPre :: (Monad m,Monoid a) => String -> LType -> PreOperationalStructure s p a -> Trace s a -> Val a -> Val a -> ST (TState a) m (Trace s a)
symbolicDiffStPre :: (Show s, Show p, Show a,Monad m,Monoid a) => String -> LType -> PreOperationalStructure s p a -> Trace s a -> Val a -> Val a -> ST (TState a) m (Trace s a)
symbolicDiffStPre x typ struct m a w = 
    case m of 
    -- case trace ("SymDiffPre: " ++ x ++ show m ++ "("++ show a ++ ")." ++ show w ) m of
        TVar y -> return $ if x == y then injValToTrace w else injValToTrace $ makeZeroVal typ
        TConst a -> return $ injValToTrace $ makeZeroVal typ 
        -- Recall that by typechecking, only real constants have TSum available. 
        TSum d e -> do 
            wda <- symbolicDiffStPre x typ struct d a w 
            wea <- symbolicDiffStPre x typ struct e a w 
            makeSumTrace typ wda wea 
        TOp f d -> do 
            -- x has type typ
            -- form R op
            let (tyu,tyv) = (struct.>gettyop) f
            let f_r@(R _ tyrfdom _) = bumpfByR (Orig f tyu tyv )
            -- form (z,f_r(fst(z),snd(z)))
            -- note: z : tyrfdom = tyu x tyv because f : tyu -> tyv
            (z,n) <- abstev struct f_r 
            y <- freshVar 
            -- form w.f_r(d) as let z = (TPair d w) in n   where n is f_r(fst(z),snd(z)) from the above
            let wfrd = TLet z tyrfdom (TPair tyu tyv d ( injValToTrace w )) n
            -- get h = R(x.d)(a,y) 
            -- need to do this on a single datatype.  It would make the whole damn thing so much cleaner.  Because all these injections would go away, and it would make the whole evaluation extension thing simple.
            h <- symbolicDiffStPre x typ struct d a (VVar y)
            -- return let x = a in let y = (let z = (d,w) in n) in h [remember let z = (d,w) in n is wfrd]
            return $ TLet x typ (injValToTrace a) $ TLet y tyu wfrd h
            -- return $ let sssss = TLet x typ (injValToTrace a) $ TLet y tyu wfrd h in trace ("We formed: " ++ show sssss) sssss

        TLet y s d e -> do 
            -- ybar has type s
            -- y has type s
            -- x has type typ
            -- only x is free in d
            -- x,y are both free in e.  We're differentiating with respect to x and with respect to the change caused by the y variable that d was in
            ybar <- freshVar 
            -- form w.R(x.e)(a)
            wrxea <- symbolicDiffStPre x typ struct e a w 
            -- form w.R(y.e)(y) 
            wryey <- symbolicDiffStPre y s struct e (VVar y) w
            -- form ybar.R(x.d)(a) 
            ybarrxda <- symbolicDiffStPre x typ struct d a (VVar ybar)
            -- form let ybar:S = w.R(y.e)(y) in ybar.R(x.d)(a) 
            let letyrr = TLet ybar s wryey ybarrxda
            -- form the term wrxea +_typ letyrr 
            suminres <- makeSumTrace typ wrxea letyrr
            return $ TLet x typ (injValToTrace a) $ TLet y s d suminres
        TNil -> return $ injValToTrace $ makeZeroVal typ 
        -- R<f,g> = (1\x \pi_0)R[f] + (1\x \pi_1)R[g]
        -- remember we do let z = m, x = fst(z),y=snd(z) in d 
        -- instead of let x = fsw(m),y=snd(m) for efficiency reasons
        -- the latter computes m twice.  I.e. we are forcing a bit of sharing.
        TPair tyu tys d e  -> do 
            yz <- freshVar  -- yz : tyu \x tys 
            y <- freshVar -- y : tyu 
            z <- freshVar -- z : tys 
            --form (1\x \pi_0)R[d]
            yrxda <- symbolicDiffStPre x typ struct d a (VVar y)
            -- form (1\x \pi_1)R[e]
            zrxea <- symbolicDiffStPre x typ struct e a (VVar z)
            -- form their sum 
            theirsum <- makeSumTrace typ yrxda zrxea
            -- form the term 
            -- let yz = w, y=fst(yz),z=snd(yz) in yrxda + zrxea
            return $ TLet yz (Prod tyu tys) (injValToTrace w) $ TLet y tyu (TFst tyu tys (TVar yz)) $ TLet z tys (TSnd tyu tys (TVar yz)) theirsum
        -- R[f \pi_0] = (1\x \iota_0)R[f]
        TFst tyu tys d -> do 
            -- form pair (w,0)
            let zero_s = makeZeroVal tys 
            y <- freshVar 
            -- form (1\x \iota_0)R[d]
            wzerorxda <- symbolicDiffStPre x typ struct d a (VPair tyu tys w zero_s)
            -- return let x:T =a,y:UxS = d in wzerorxda
            return $ TLet x typ (injValToTrace a) $ TLet y (Prod tyu tys) d wzerorxda
        TSnd tyu tys d -> do 
            -- form pair (0,w)
            let zero_u = makeZeroVal tyu 
            y <- freshVar 
            zerowrxda <- symbolicDiffStPre x typ struct d a (VPair tyu tys zero_u w)
            return $ TLet x typ (injValToTrace a) $ TLet y (Prod tyu tys) d zerowrxda
        
    
        


        
bumpfByR :: ROP s -> ROP s 
bumpfByR f = case f of 
    Orig g a b-> R f (Prod a b) a 
    R g a b -> R f (Prod a b) a

-- This is not term evaluation.  This is just the extension of ev from the operational structure.
-- evalStateful :: (Show s,Show a,Monoid a) => PreOperationalStructure s p a -> (ROP s) -> (ClosedVal a) -> ST (TState a) Err (ClosedVal a)
evalStateful :: (Show s,Show p,Show a,Monoid a) => PreOperationalStructure s p a -> (ROP s) -> (ClosedVal a) -> ST (TState a) Err (ClosedVal a)
evalStateful struct f v = case f of 
  Orig g _ _ -> lift $ (struct.>evop) g v
  (R h _ _) -> do 
    (name,rhAbst) <- abstev struct f 
    -- the nature of abst ensures that name is unique. 
    locs <-  getLocals
    setLocals $ M.insert name v locs
    eval_f <- evalTraceStateful struct rhAbst 
    -- remove name from the map, it's not longer required.  In fact we could have evaluated in a purely fresh context
    -- however, there's no need to reset the context because of our assumptions, rhAbst may contain assignments, but they will all be 
    -- locally restricted (i.e. they will all be used during the execution, and evaluation of lets removes variables it sets after evaluation)
    -- Since eval of ROP symbols results in ordinary terms with no ROPs we're safe.  We need to check that ROP s can only be introduced by 
    -- symbolic differentiation, and is always removed.  The type system ensures all ROPs are removed.
    setLocals locs 
    return $  eval_f

-- extendedEval :: (Show s,Show a,Monoid a) => PreOperationalStructure s p a -> (ROP s) -> (ClosedVal a) -> Err (ClosedVal a)
extendedEval :: (Show s,Show p,Show a,Monoid a) => PreOperationalStructure s p a -> (ROP s) -> (ClosedVal a) -> Err (ClosedVal a)
extendedEval struct f v = runSTVal (evalStateful struct f v) (TS {locals=M.empty,seedName="x",freshName=0})

-- some example evaluations that *should* work... 
egExtEvalTerm1 :: ROP SigmaR1
egExtEvalTerm1 = Orig Sin Real Real 
egExtEvalTerm1Evald = extendedEval instanceOpStruct1 egExtEvalTerm1 (CConst (R1 3))
egExtEvalTerm2 = R (Orig Sin Real Real) (Prod Real Real) Real
egExtEvalTerm2Evald = extendedEval instanceOpStruct1 egExtEvalTerm2 (CPair Real Real (CConst (R1 3)) (CConst (R1 1)))
egExtEvalTerm3 = bumpfByR egExtEvalTerm2
egExtEvalTerm3Evald = extendedEval instanceOpStruct1 egExtEvalTerm3 myvalue 
    where 
        myvalue = CPair (Prod Real Real) Real mypt myvec 
        mypt = CPair Real Real myx myy 
        myvec = CConst (R1 1)
        myx = CConst (R1 3)
        myy = CConst (R1 5)
egExtEvalTerm4 :: ROP SigmaR1 
egExtEvalTerm4 = Orig Times (Prod Real Real) Real 
egExtEvalTerm4Evald = extendedEval instanceOpStruct1 egExtEvalTerm4 (CPair Real Real (CConst (R1 3)) (CConst (R1 4)))
egExtEvalTerm5 = bumpfByR egExtEvalTerm4 
egExtEvalTerm5Evald = extendedEval instanceOpStruct1  egExtEvalTerm5 myvalue 
    where 
        myvalue = CPair (Prod Real Real) Real mypt myvec 
        mypt = CPair Real Real myx myy 
        myvec = CConst (R1 1)
        myx = CConst (R1 3)
        myy = CConst (R1 5)
egExtEvalTerm6 = bumpfByR egExtEvalTerm5 
egExtEvalTerm6Evald = extendedEval instanceOpStruct1 egExtEvalTerm6 myvalue 
    where
        rr = Prod Real Real 
        rrr = Prod rr Real 
        rrrrr = Prod rrr rr 
        de = CPair Real Real (CConst (R1 2)) (CConst (R1 3))
        ab = CPair Real Real (CConst (R1 4)) (CConst (R1 5))
        abc = CPair rr Real ab (CConst (R1 6))
        abcde = CPair rrr rr abc de
        myvalue = abcde


-- example implementation 


instanceOperationalStruct = convertPOP instanceOpStruct1

instanceOpStruct1 = POS {
    evop = \s val -> 
        ( 
            case (s,val) of
                (Sin,CConst (R1 r)) -> Ok $ CConst (R1 (sin r))
                (Cos,CConst (R1 r)) -> Ok $ CConst (R1 (cos r))
                (Neg,CConst (R1 r)) -> Ok $ CConst (R1 (-r))
                (Times, CPair Real Real (CConst (R1 a)) (CConst (R1 b))) -> Ok $ CConst  (R1 (a*b))
                _ -> Fail "Only Sin,Cos,Times are defined and require everything to be typed correctly.  If you passed typechecking and used one of these operators, please report a bug."
        ),
    bevpred = \s bval ->
        (
            case (s,bval) of
                -- below is the classical definition. 
                -- (LessThan, CPair Real Real (CConst (R1 a)) (CConst (R1 b))) -> if a < b then Ok BTrue else Ok BFalse
                -- below is the "more correct" definition -- a < b should be undefined when a == b.  
                -- In our interpretation we will take it to poke holes in this way that we maintain 
                -- disjoint predicateness: a < b | a > b versus a < b | a >= b.  We don't actually have a >= b.
                -- Thus another way to put this is that in our semantics, we must always have a predicate 
                -- and its intended negation be formal etale.
                (LessThan, CPair Real Real (CConst (R1 a)) (CConst (R1 b))) -> case compare a b of 
                    LT -> Ok BTrue 
                    EQ -> Fail "comparison is not defined when a == b"
                    GT -> Ok BFalse 
                _ -> Fail "Only less than is defined, and requires being well typed.  If you passed typechecking and used < please report a bug."
        ),
    fR = \s name -> 
        (
            case s of 
                Sin -> 
                    let 
                        x = TFst Real Real (TVar name)
                        y = TSnd Real Real (TVar name)
                        cosx = TOp Cos x 
                    in
                        TOp Times (TPair Real Real cosx y)
                Cos -> 
                    let 
                        x = TFst Real Real (TVar name)
                        y = TSnd Real Real (TVar name)
                        sinx = TOp Sin x 
                        min1 = TConst  (R1 (-1))
                        nsinx = TOp Times (TPair Real Real min1 sinx)
                        nsinxy = TOp Times (TPair Real Real nsinx y)
                    in 
                        nsinxy
                Neg -> 
                    let 
                        x = TFst Real Real (TVar name)
                        y = TSnd Real Real (TVar name)
                        min1 = TConst (R1 (-1))
                        miny = TOp Times (TPair Real Real min1 y)
                    in 
                        miny
                Times ->
                    let 
                        ab = TFst (Prod Real Real) Real (TVar name)
                        r = TSnd (Prod Real Real) Real (TVar name)
                        a = TFst Real Real ab 
                        b = TSnd Real Real ab 
                        br = TOp Times (TPair Real Real b r)
                        ar = TOp Times (TPair Real Real a r)
                    in 
                        TPair Real Real br ar
        ),
    gettyop = \s -> 
        (
            case s of 
                Sin -> (Real,Real)
                Cos -> (Real,Real)
                Neg -> (Real,Real)
                Times -> (Prod Real Real, Real)
        )
}

