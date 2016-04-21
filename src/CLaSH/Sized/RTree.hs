{-|
Copyright  :  (C) 2016, University of Twente
License    :  BSD2 (see the file LICENSE)
Maintainer :  Christiaan Baaij <christiaan.baaij@gmail.com>
-}

{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE GADTs                #-}
{-# LANGUAGE KindSignatures       #-}
{-# LANGUAGE PatternSynonyms      #-}
{-# LANGUAGE RankNTypes           #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE TupleSections        #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE TypeOperators        #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ViewPatterns         #-}

{-# LANGUAGE Trustworthy #-}

{-# OPTIONS_GHC -fplugin GHC.TypeLits.Normalise #-}

module CLaSH.Sized.RTree
  ( -- * 'RTree' data type
    RTree (LR, BR)
    -- * Construction
  , treplicate
  , trepeat
    -- * Accessors
    -- ** Indexing
  , indexTree
  , tindices
    -- * Modifying trees
  , replaceTree
    -- * Element-wise operations
    -- ** Mapping
  , tmap
  , tzipWith
    -- ** Zipping
  , tzip
    -- ** Unzipping
  , tunzip
    -- * Folding
  , tfold
    -- ** Specialised folds
  , tdfold
    -- * Conversions
  , v2t
  , t2v
  )
where

import Control.Applicative         (liftA2)
import qualified Control.Lens      as Lens
-- import Data.Singletons.Prelude     (Apply, TyFun, type ($))
import Data.Proxy                  (Proxy (..))
import GHC.TypeLits                (KnownNat, Nat, type (+), type (^), type (*))
import qualified Prelude           as P
import Prelude                     hiding ((++), (!!))

import CLaSH.Class.BitPack         (BitPack (..))
import CLaSH.Promoted.Defun        (TyFun,Apply,type (@@))
import CLaSH.Promoted.Nat          (SNat (..), UNat (..), powSNat, snatToInteger,
                                    subSNat, toUNat)
import CLaSH.Promoted.Nat.Literals (d1, d2)
import CLaSH.Sized.Index           (Index)
import CLaSH.Sized.Vector          (Vec (..), (!!), (++), dtfold, replace)

{- $setup
>>> :set -XDataKinds
>>> :set -XTypeFamilies
>>> :set -XTypeOperators
>>> :set -XTemplateHaskell
>>> :set -XFlexibleContexts
>>> :set -fplugin GHC.TypeLits.Normalise
>>> :set -XUndecidableInstances
>>> import CLaSH.Prelude
>>> data IIndex (f :: TyFun Nat *) :: *
>>> type instance Apply IIndex l = Index ((2^l)+1)
>>> :{
let populationCount' :: (KnownNat k, KnownNat (2^k)) => BitVector (2^k) -> Index ((2^k)+1)
    populationCount' bv = tdfold (Proxy :: Proxy IIndex)
                                 fromIntegral
                                 (\_ x y -> plus x y)
                                 (v2t (bv2v bv))
:}
-}

-- | Perfect depth binary tree.
--
-- * Only has elements at the leaf of the tree
-- * A tree of depth /d/ has /2^d/ elements.
data RTree :: Nat -> * -> * where
  LR_ :: a -> RTree 0 a
  BR_ :: RTree d a -> RTree d a -> RTree (d+1) a

textract :: RTree 0 a -> a
textract (LR_ x) = x
{-# NOINLINE textract #-}

tsplit :: RTree (d+1) a -> (RTree d a,RTree d a)
tsplit (BR_ l r) = (l,r)
{-# NOINLINE tsplit #-}

-- | Leaf of a perfect depth tree
--
-- >>> LR 1
-- 1
-- >>> let x = LR 1
-- >>> :t x
-- x :: Num a => RTree 0 a
--
-- Can be used as a pattern:
--
-- >>> let f (LR a) (LR b) = a + b
-- >>> :t f
-- f :: Num a => RTree 0 a -> RTree 0 a -> a
-- >>> f (LR 1) (LR 2)
-- 3
pattern LR :: a -> RTree 0 a
pattern LR x <- (textract -> x)
  where
    LR x = LR_ x

-- | Branch of a perfect depth tree
--
-- >>> BR (LR 1) (LR 2)
-- <1,2>
-- >>> let x = BR (LR 1) (LR 2)
-- >>> :t x
-- x :: Num a => RTree 1 a
--
-- Case be used a pattern:
--
-- >>> let f (BR (LR a) (LR b)) = LR (a + b)
-- >>> :t f
-- f :: Num a => RTree 1 a -> RTree 0 a
-- >>> f (BR (LR 1) (LR 2))
-- 3
pattern BR :: RTree d a -> RTree d a -> RTree (d+1) a
pattern BR l r <- ((\t -> (tsplit t)) -> (l,r))
  where
    BR l r = BR_ l r

instance Show a => Show (RTree n a) where
  show (LR_ a)   = show a
  show (BR_ l r) = '<':show l P.++ (',':show r) P.++ ">"

instance KnownNat d => Functor (RTree d) where
  fmap = tmap

instance KnownNat d => Applicative (RTree d) where
  pure  = trepeat
  (<*>) = tzipWith ($)

instance KnownNat d => Foldable (RTree d) where
  foldMap f = tfold f mappend

data TraversableTree (g :: * -> *) (a :: *) (f :: TyFun Nat *) :: *
type instance Apply (TraversableTree f a) d = f (RTree d a)

instance KnownNat d => Traversable (RTree d) where
  traverse f = tdfold (Proxy :: Proxy (TraversableTree f b))
                      (fmap LR . f)
                      (const (liftA2 BR))

instance (KnownNat (2^d), KnownNat d, KnownNat (BitSize a), BitPack a) =>
  BitPack (RTree d a) where
  type BitSize (RTree d a) = (2^d) * (BitSize a)
  pack   = pack . t2v
  unpack = v2t . unpack

type instance Lens.Index   (RTree d a) = Int
type instance Lens.IxValue (RTree d a) = a
instance (KnownNat d, KnownNat (2^d)) => Lens.Ixed (RTree d a) where
  ix i f t = replaceTree i <$> f (indexTree t i) <*> pure t

-- | A /dependently/ typed fold over trees.
--
-- As an example of when you might want to use 'dtfold' we will build a
-- population counter: a circuit that counts the number of bits set to '1' in
-- a 'BitVector'. Given a vector of /n/ bits, we only need we need a data type
-- that can represent the number /n/: 'Index' @(n+1)@. 'Index' @k@ has a range
-- of @[0 .. k-1]@ (using @ceil(log2(k))@ bits), hence we need 'Index' @n+1@.
-- As an initial attempt we will use 'tfold', because it gives a nice (@log2(n)@)
-- tree-structure of adders:
--
-- @
-- populationCount :: (KnownNat (2^d), KnownNat d, KnownNat (2^d+1))
--                 => BitVector (2^d) -> Index (2^d+1)
-- populationCount = tfold fromIntegral (+) . v2t . bv2v
-- @
--
-- The \"problem\" with this description is that all adders have the same
-- bit-width, i.e. all adders are of the type:
--
-- @
-- (+) :: 'Index' (2^d+1) -> 'Index' (2^d+1) -> 'Index' (2^d+1).
-- @
--
-- This is a \"problem\" because we could have a more efficient structure:
-- one where each layer of adders is /precisely/ wide enough to count the number
-- of bits at that layer. That is, at height /d/ we want the adder to be of
-- type:
--
-- @
-- 'Index' ((2^d)+1) -> 'Index' ((2^d)+1) -> 'Index' ((2^(d+1))+1)
-- @
--
-- We have such an adder in the form of the 'CLaSH.Class.Num.plus' function, as
-- defined in the instance 'CLaSH.Class.Num.ExtendingNum' instance of 'Index'.
-- However, we cannot simply use 'fold' to create a tree-structure of
-- 'CLaSH.Class.Num.plus'es:
--
-- >>> :{
-- let populationCount' :: (KnownNat (2^d), KnownNat d, KnownNat (2^d+1))
--                      => BitVector (2^d) -> Index (2^d+1)
--     populationCount' = tfold fromIntegral plus . v2t . bv2v
-- :}
-- <BLANKLINE>
-- <interactive>:...
--     • Couldn't match type ‘(((2 ^ d) + 1) + ((2 ^ d) + 1)) - 1’
--                      with ‘(2 ^ d) + 1’
--       Expected type: Index ((2 ^ d) + 1)
--                      -> Index ((2 ^ d) + 1) -> Index ((2 ^ d) + 1)
--         Actual type: Index ((2 ^ d) + 1)
--                      -> Index ((2 ^ d) + 1)
--                      -> AResult (Index ((2 ^ d) + 1)) (Index ((2 ^ d) + 1))
--     • In the second argument of ‘tfold’, namely ‘plus’
--       In the first argument of ‘(.)’, namely ‘tfold fromIntegral plus’
--       In the expression: tfold fromIntegral plus . v2t . bv2v
--     • Relevant bindings include
--         populationCount' :: BitVector (2 ^ d) -> Index ((2 ^ d) + 1)
--           (bound at ...)
--
-- because 'tfold' expects a function of type \"@b -> b -> b@\", i.e. a function
-- where the arguments and result all have exactly the same type.
--
-- In order to accommodate the type of our 'CLaSH.Class.Num.plus', where the
-- result is larger than the arguments, we must use a dependently typed fold in
-- the the form of 'dtfold':
--
-- @
-- {\-\# LANGUAGE UndecidableInstances \#-\}
-- import CLaSH.Promoted.Defun
-- import Data.Proxy
--
-- data IIndex (f :: 'TyFun' Nat *) :: *
-- type instance 'Apply' IIndex l = 'Index' ((2^l)+1)
--
-- populationCount' :: (KnownNat k, KnownNat (2^k))
--                  => BitVector (2^k) -> Index ((2^k)+1)
-- populationCount' bv = 'tdfold' (Proxy :: Proxy IIndex)
--                              fromIntegral
--                              (\\_ x y -> 'CLaSH.Class.Num.plus' x y)
--                              ('v2t' ('CLaSH.Sized.Vector.bv2v' bv))
-- @
--
-- And we can test that it works:
--
-- >>> :t populationCount' (7 :: BitVector 16)
-- populationCount' (7 :: BitVector 16) :: Index 17
-- >>> populationCount' (7 :: BitVector 16)
-- 3
tdfold :: forall p k a . KnownNat k
       => Proxy (p :: TyFun Nat * -> *) -- ^ The /motive/
       -> (a -> (p @@ 0)) -- ^ Function to apply to the elements on the leafs
       -> (forall l . SNat l -> (p @@ l) -> (p @@ l) -> (p @@ (l+1)))
       -- ^ Function to fold the branches with.
       --
       -- __NB:__ @SNat l@ is the depth of the two sub-branches.
       -> RTree k a -- ^ Tree to fold over.
       -> (p @@ k)
tdfold _ f g = go SNat
  where
    go :: SNat m -> RTree m a -> (p @@ m)
    go _  (LR_ a)   = f a
    go sn (BR_ l r) = let sn' = sn `subSNat` d1
                      in  g sn' (go sn' l) (go sn' r)
{-# NOINLINE tdfold #-}

data TfoldTree (a :: *) (f :: TyFun Nat *) :: *
type instance Apply (TfoldTree a) d = a

-- | Reduce a tree to a single element
tfold :: KnownNat d
      => (a -> b) -- ^ Function to apply to the leaves
      -> (b -> b -> b) -- ^ Function to combine the results of the reduction
                       -- of two branches
      -> RTree d a -- ^ Tree to fold reduce
      -> b
tfold f g = tdfold (Proxy :: Proxy (TfoldTree b)) f (const g)

-- | \"'treplicate' @d a@\" returns a tree of depth /d/, and has /2^d/ copies
-- of /a/.
--
-- >>> treplicate (SNat :: SNat 3) 6
-- <<<6,6>,<6,6>>,<<6,6>,<6,6>>>
-- >>> treplicate d3 6
-- <<<6,6>,<6,6>>,<<6,6>,<6,6>>>
treplicate :: forall d a . SNat d -> a -> RTree d a
treplicate sn a = go (toUNat sn)
  where
    go :: UNat n -> RTree n a
    go UZero      = LR a
    go (USucc un) = BR (go un) (go un)
{-# NOINLINE treplicate #-}

-- | \"'trepeat' @a@\" creates a tree with as many copies of /a/ as demanded by
-- the context.
--
-- >>> trepeat 6 :: RTree 2 Int
-- <<6,6>,<6,6>>
trepeat :: KnownNat d => a -> RTree d a
trepeat = treplicate SNat

data MapTree (a :: *) (f :: TyFun Nat *) :: *
type instance Apply (MapTree a) d = RTree d a

-- | \"'tmap' @f t@\" is the tree obtained by apply /f/ to each element of /t/,
-- i.e.,
--
-- > tmap f (BR (LR a) (LR b)) == BR (LR (f a)) (LR (f b))
tmap :: KnownNat d => (a -> b) -> RTree d a -> RTree d b
tmap f = tdfold (Proxy :: Proxy (MapTree b)) (LR . f) (\_ l r -> BR l r)

-- | Generate a tree of indices, where the depth of the tree is determined by
-- the context.
--
-- >>> tindices :: RTree 3 (Index 8)
-- <<<0,1>,<2,3>>,<<4,5>,<6,7>>>
tindices :: (KnownNat d, KnownNat (2^d)) => RTree d (Index (2^d))
tindices =
  tdfold (Proxy :: Proxy (MapTree (Index (2^d)))) LR
         (\s@SNat l r -> BR l (tmap (+(fromInteger (snatToInteger (d2 `powSNat` s)))) r))
         (treplicate SNat 0)

data V2TTree (a :: *) (f :: TyFun Nat *) :: *
type instance Apply (V2TTree a) d = RTree d a

-- | Convert a vector with /2^d/ elements to a tree of depth /d/.
--
-- >>> (1:>2:>3:>4:>Nil)
-- <1,2,3,4>
-- >>> v2t (1:>2:>3:>4:>Nil)
-- <<1,2>,<3,4>>
v2t :: KnownNat d => Vec (2^d) a -> RTree d a
v2t = dtfold (Proxy :: Proxy (V2TTree a)) LR (const BR)

data T2VTree (a :: *) (f :: TyFun Nat *) :: *
type instance Apply (T2VTree a) d = Vec (2^d) a

-- | Convert a tree of depth /d/ to a vector of /2^d/ elements
--
-- >>> (BR (BR (LR 1) (LR 2)) (BR (LR 3) (LR 4)))
-- <<1,2>,<3,4>>
-- >>> t2v (BR (BR (LR 1) (LR 2)) (BR (LR 3) (LR 4)))
-- <1,2,3,4>
t2v :: KnownNat d => RTree d a -> Vec (2^d) a
t2v = tdfold (Proxy :: Proxy (T2VTree a)) (:> Nil) (\_ l r -> l ++ r)

-- | \"'indexTree' @t n@\" returns the /n/'th element of /t/.
--
-- The bottom-left leaf had index /0/, and the bottom-right leaf has index
-- /2^d-1/, where /d/ is the depth of the tree
--
-- >>> indexTree (BR (BR (LR 1) (LR 2)) (BR (LR 3) (LR 4))) 0
-- 1
-- >>> indexTree (BR (BR (LR 1) (LR 2)) (BR (LR 3) (LR 4))) 2
-- 3
-- >>> indexTree (BR (BR (LR 1) (LR 2)) (BR (LR 3) (LR 4))) 14
-- *** Exception: CLaSH.Sized.Vector.(!!): index 14 is larger than maximum index 3
-- ...
indexTree :: (KnownNat d, KnownNat (2^d), Enum i) => RTree d a -> i -> a
indexTree t i = (t2v t) !! i

-- | \"'replaceTree' @n a t@\" returns the tree /t/ where the /n/'th element is
-- replaced by /a/.
--
-- The bottom-left leaf had index /0/, and the bottom-right leaf has index
-- /2^d-1/, where /d/ is the depth of the tree
--
-- >>> replaceTree 0 5 (BR (BR (LR 1) (LR 2)) (BR (LR 3) (LR 4)))
-- <<5,2>,<3,4>>
-- >>> replaceTree 2 7 (BR (BR (LR 1) (LR 2)) (BR (LR 3) (LR 4)))
-- <<1,2>,<7,4>>
-- >>> replaceTree 9 6 (BR (BR (LR 1) (LR 2)) (BR (LR 3) (LR 4)))
-- <<1,2>,<3,*** Exception: CLaSH.Sized.Vector.replace: index 9 is larger than maximum index 3
-- ...
replaceTree :: (KnownNat d, KnownNat (2^d), Enum i) => i -> a -> RTree d a -> RTree d a
replaceTree i a = v2t . replace i a . t2v

data ZipWithTree (b :: *) (c :: *) (f :: TyFun Nat *) :: *
type instance Apply (ZipWithTree b c) d = RTree d b -> RTree d c

-- | 'tzipWith' generalises 'tzip' by zipping with the function given as the
-- first argument, instead of a tupling function. For example, "tzipWith (+)"
-- applied to two trees produces the tree of corresponding sums.
--
-- > tzipWith f (BR (LR a1) (LR b1)) (BR (LR a2) (LR b2)) == BR (LR (f a1 a2)) (LR (f b1 b2))
tzipWith :: forall a b c d . KnownNat d => (a -> b -> c) -> RTree d a -> RTree d b -> RTree d c
tzipWith f = tdfold (Proxy :: Proxy (ZipWithTree b c)) lr br
  where
    lr :: a -> RTree 0 b -> RTree 0 c
    lr a (LR b) = LR (f a b)
    lr _ _      = error "impossible"

    br :: SNat l
       -> (RTree l b -> RTree l c)
       -> (RTree l b -> RTree l c)
       -> RTree (l+1) b
       -> RTree (l+1) c
    br _ fl fr (BR l r) = BR (fl l) (fr r)
    br _ _  _  _        = error "impossible"

-- | 'tzip' takes two trees and returns a tree of corresponding pairs.
tzip :: KnownNat d => RTree d a -> RTree d b -> RTree d (a,b)
tzip = tzipWith (,)

data UnzipTree (a :: *) (b :: *) (f :: TyFun Nat *) :: *
type instance Apply (UnzipTree a b) d = (RTree d a, RTree d b)

-- | 'tunzip' transforms a tree of pairs into a tree of first components and a
-- tree of second components.
tunzip :: KnownNat d => RTree d (a,b) -> (RTree d a,RTree d b)
tunzip = tdfold (Proxy :: Proxy (UnzipTree a b)) lr br
  where
    lr   (a,b) = (LR a,LR b)

    br _ (l1,r1) (l2,r2) = (BR l1 l2, BR r1 r2)
