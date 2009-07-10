{-# LANGUAGE FlexibleContexts, TypeFamilies #-}

-- |Embedded array processing language: user-visible language
--
--  Copyright (c) 2009 Manuel M T Chakravarty, Gabriele Keller, Sean Lee
--
--  License: BSD3
--
--- Description ---------------------------------------------------------------
--
-- We use the dictionary view of overloaded operations (such as arithmetic and
-- bit manipulation) to reify such expressions.  With non-overloaded
-- operations (such as, the logical connectives) and partially overloaded
-- operations (such as comparisons), we use the standard operator names with a
-- '*' attached.  We keep the standard alphanumeric names as they can be
-- easily qualified.

module Data.Array.Accelerate.Language (

  -- * Array processing computation monad
  AP, APstate,          -- re-exporting from 'Smart'

  -- * Expressions
  Exp, exp,             -- re-exporting from 'Smart'

  -- * Array introduction
  use, unit,

  -- * Shape manipulation
  reshape,

  -- * Collective array operations
  replicate, zip, map, zipWith, filter, scan, fold, permute, backpermute,

  -- * Instances of Bounded, Enum, Eq, Ord, Bits, Num, Real, Floating,
  --   Fractional, RealFrac, RealFloat

  -- * Methods of H98 classes that we need to redefine as their signatures
  --   change 
  (==*), (/=*), (<*), (<=*), (>*), (>=*), max, min,

  -- * Standard functions that we need to redefine as their signatures change
  (&&*), (||*), not

) where

-- avoid clashes with Prelude functions
import Prelude   hiding (replicate, zip, map, zipWith, filter, max, min, not, 
                         exp)
import qualified Prelude

-- standard libraries
import Data.Bits

-- friends
import Data.Array.Accelerate.Type
import Data.Array.Accelerate.Array.Representation
import Data.Array.Accelerate.Array.Sugar
import Data.Array.Accelerate.AST                  hiding (Exp, OpenExp(..), Arr)
import Data.Array.Accelerate.Smart
import Data.Array.Accelerate.Pretty


infixr 2 ||*
infixr 3 &&*
infix  4 ==*, /=*, <*, <=*, >*, >=*
infixl 9 !


-- |Collective operations
-- ----------------------

use :: (Ix dim, Elem e) => Array dim e -> AP (Arr dim e)
use array = wrapComp tupleType (Use array)

unit :: IsTuple e => Exp e -> AP (Scalar e)
unit e = wrapComp tupleType (Unit (convertExp e))

reshape :: IsTuple e => Exp dim -> Arr dim' e -> AP (Arr dim e)
reshape e arr = wrapComp tupleType (Reshape (convertExp e) arr) 

replicate :: IsTuple e => Index dim' dim -> Arr dim e -> AP (Arr dim' e)
replicate ix arr = wrapComp tupleType (Replicate ix arr)
  -- FIXME: need nice syntax for generalised indicies

(!) :: IsTuple e => Arr dim e -> Index dim dim' -> AP (Arr dim' e)
arr ! ix = wrapComp tupleType (Index arr ix)

zip :: IsTuple (a, b) => Arr dim a -> Arr dim b -> AP (Arr dim (a, b))
zip arr1 arr2 = wrapComp tupleType (Zip arr1 arr2)

map :: (IsTuple a, IsTuple b) 
    => (Exp a -> Exp b) -> Arr dim a -> AP (Arr dim b)
map f arr = wrapComp tupleType (Map (convertFun1 f) arr)

zipWith :: (IsTuple (a, b), IsTuple c)
        => (Exp a -> Exp b -> Exp c) -> Arr dim a -> Arr dim b -> AP (Arr dim c)
zipWith f arr1 arr2 
  = do
      let f' = \xy -> f (Fst xy) (Snd xy)
      arr' <- genArr tupleType
      pushComp $ arr' `CompBinding` (Zip arr1 arr2)
      arr <- genArr tupleType
      pushComp $ arr `CompBinding` (Map (convertFun1 f') arr')
      return arr

filter :: IsTuple a => (Exp a -> Exp Bool) -> Arr DIM1 a -> AP (Arr DIM1 a)
filter p arr = wrapComp tupleType (Filter (convertFun1 p) arr)
  -- FIXME: we want the argument of the mapped function to be a tuple, too

scan :: IsTuple a 
     => (Exp a -> Exp a -> Exp a) -> Exp a -> Arr DIM1 a 
     -> AP (Scalar a, Arr DIM1 a)
scan f e arr = wrapComp2 tupleType tupleType $
                 (Scan (convertFun2 f) (convertExp e) arr)

fold :: IsTuple a 
     => (Exp a -> Exp a -> Exp a) -> Exp a -> Arr DIM1 a -> AP (Scalar a)
fold f e arr
  = do
      (r, _) <- scan f e arr
      return r

permute :: (IsTuple a, IsTuple dim, IsTuple dim')
        => (Exp a -> Exp a -> Exp a) -> Arr dim' a -> (Exp dim -> Exp dim') 
        -> Arr dim a -> AP (Arr dim' a)
permute f dftArr perm arr 
  = wrapComp tupleType $ Permute (convertFun2 f) dftArr (convertFun1 perm) arr

backpermute :: (IsTuple a , IsTuple dim, IsTuple dim')
            => Exp dim' -> (Exp dim' -> Exp dim) -> Arr dim a -> AP (Arr dim' a)
backpermute newDim perm arr 
  = wrapComp tupleType $ Backpermute (convertExp newDim) (convertFun1 perm) arr


-- |Instances of all relevant H98 classes
-- --------------------------------------

instance IsBounded t => Bounded (Exp t) where
  minBound = mkMinBound
  maxBound = mkMaxBound

instance IsScalar t => Enum (Exp t)
--  succ = mkSucc
--  pred = mkPred
  -- FIXME: ops

instance IsScalar t => Prelude.Eq (Exp t)
  -- FIXME: instance makes no sense with standard signatures

instance IsScalar t => Prelude.Ord (Exp t)
  -- FIXME: instance makes no sense with standard signatures

instance (IsNum t, IsIntegral t) => Bits (Exp t) where
  (.&.)      = mkBAnd
  (.|.)      = mkBOr
  xor        = mkBXor
  complement = mkBNot
  -- FIXME: argh, the rest have fixed types in their signatures

instance (Elem t, IsNum t) => Num (Exp t) where
  (+)         = mkAdd
  (-)         = mkSub
  (*)         = mkMul
  negate      = mkNeg
  abs         = mkAbs
  signum      = mkSig
  fromInteger = exp . fromInteger

instance IsNum t => Real (Exp t)
  -- FIXME: Why did we include this class?  We won't need `toRational' until
  --   we support rational numbers in AP computations.

instance IsIntegral t => Integral (Exp t) where
  quot = mkQuot
  rem  = mkRem
  div  = mkIDiv
  mod  = mkMod
--  quotRem =
--  divMod  =
--  toInteger =  -- makes no sense

instance IsFloating t => Floating (Exp t) where
  pi  = mkPi
  -- FIXME: add other ops

instance (Elem t, IsFloating t) => Fractional (Exp t) where
  (/)          = mkFDiv
  recip        = mkRecip
  fromRational = exp . fromRational
  -- FIXME: add other ops

instance IsFloating t => RealFrac (Exp t)
  -- FIXME: add ops

instance IsFloating t => RealFloat (Exp t)
  -- FIXME: add ops


-- |Methods from H98 classes, where we need other signatures
-- ---------------------------------------------------------

(==*) :: IsScalar t => Exp t -> Exp t -> Exp Bool
(==*) = mkEq

(/=*) :: IsScalar t => Exp t -> Exp t -> Exp Bool
(/=*) = mkNEq

-- compare :: a -> a -> Ordering  -- we have no enumerations at the moment
-- compare = ...

(<*) :: IsScalar t => Exp t -> Exp t -> Exp Bool
(<*)  = mkLt

(>=*) :: IsScalar t => Exp t -> Exp t -> Exp Bool
(>=*) = mkGtEq

(>*) :: IsScalar t => Exp t -> Exp t -> Exp Bool
(>*)  = mkGt

(<=*) :: IsScalar t => Exp t -> Exp t -> Exp Bool
(<=*) = mkLtEq

max :: IsScalar t => Exp t -> Exp t -> Exp t
max = mkMax

min :: IsScalar t => Exp t -> Exp t -> Exp t
min = mkMin


-- |Non-overloaded standard functions, where we need other signatures
-- ------------------------------------------------------------------

(&&*) :: Exp Bool -> Exp Bool -> Exp Bool
(&&*) = mkLAnd

(||*) :: Exp Bool -> Exp Bool -> Exp Bool
(||*) = mkLOr

not :: Exp Bool -> Exp Bool
not = mkLNot

