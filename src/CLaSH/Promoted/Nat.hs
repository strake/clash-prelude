{-|
Copyright  :  (C) 2013-2016, University of Twente
License    :  BSD2 (see the file LICENSE)
Maintainer :  Christiaan Baaij <christiaan.baaij@gmail.com>
-}

{-# LANGUAGE CPP                 #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators       #-}

{-# LANGUAGE Trustworthy #-}

{-# OPTIONS_GHC -fplugin GHC.TypeLits.Normalise #-}
{-# OPTIONS_HADDOCK show-extensions #-}

#include "primitive.h"

module CLaSH.Promoted.Nat
  ( SNat (..), snat, withSNat, snatToInteger, addSNat, subSNat, mulSNat, powSNat
  , UNat (..), toUNat, addUNat, multUNat, powUNat
  )
where

import Data.Proxy      (Proxy (..))
import Data.Reflection (reifyNat)
import GHC.TypeLits    (KnownNat, Nat, type (+), type (-), type (*), type (^),
                        natVal)
import Unsafe.Coerce   (unsafeCoerce)

-- | Singleton value for a type-level natural number 'n'
--
-- * "CLaSH.Promoted.Nat.Literals" contains a list of predefined 'SNat' literals
-- * "CLaSH.Promoted.Nat.TH" has functions to easily create large ranges of new
--   'SNat' literals
data SNat (n :: Nat) = KnownNat n => SNat (Proxy n)

instance Show (SNat n) where
  show (SNat p) = 'd' : show (natVal p)

{-# INLINE snat #-}
-- | Create a singleton literal for a type-level natural number
snat :: KnownNat n => SNat n
snat = SNat Proxy

{-# INLINE withSNat #-}
-- | Supply a function with a singleton natural 'n' according to the context
withSNat :: KnownNat n => (SNat n -> a) -> a
withSNat f = f (SNat Proxy)

{-# INLINE snatToInteger #-}
-- | Reify the type-level 'Nat' @n@ to it's term-level 'Integer' representation.
snatToInteger :: SNat n -> Integer
snatToInteger (SNat p) = natVal p

-- | Unary representation of a type-level natural
--
-- __NB__: Not synthesisable
data UNat :: Nat -> * where
  UZero :: UNat 0
  USucc :: UNat n -> UNat (n + 1)

-- | Convert a singleton natural number to its unary representation
--
-- __NB__: Not synthesisable
toUNat :: SNat n -> UNat n
toUNat (SNat p) = fromI (natVal p)
  where
    fromI :: Integer -> UNat m
    fromI 0 = unsafeCoerce UZero
    fromI n = unsafeCoerce (USucc (fromI (n - 1)))

-- | Add two unary singleton natural numbers
--
-- __NB__: Not synthesisable
addUNat :: UNat n -> UNat m -> UNat (n + m)
addUNat UZero     y     = y
addUNat x         UZero = x
addUNat (USucc x) y     = USucc (addUNat x y)

-- | Multiply two unary singleton natural numbers
--
-- __NB__: Not synthesisable
multUNat :: UNat n -> UNat m -> UNat (n * m)
multUNat UZero      _     = UZero
multUNat _          UZero = UZero
multUNat (USucc x) y      = addUNat y (multUNat x y)

-- | Power of two unary singleton natural numbers
--
-- __NB__: Not synthesisable
powUNat :: UNat n -> UNat m -> UNat (n ^ m)
powUNat _ UZero     = USucc UZero
powUNat x (USucc y) = multUNat x (powUNat x y)

-- | Add two singleton natural numbers
addSNat :: SNat a -> SNat b -> SNat (a+b)
addSNat x y = reifyNat (snatToInteger x + snatToInteger y) (unsafeCoerce . SNat)
{-# PRIMITIVE_I addSNat #-}

-- | Subtract two singleton natural numbers
subSNat :: SNat a -> SNat b -> SNat (a-b)
subSNat x y = reifyNat (snatToInteger x - snatToInteger y) (unsafeCoerce . SNat)
{-# PRIMITIVE_I subSNat #-}

-- | Multiply two singleton natural numbers
mulSNat :: SNat a -> SNat b -> SNat (a*b)
mulSNat x y = reifyNat (snatToInteger x * snatToInteger y) (unsafeCoerce . SNat)
{-# PRIMITIVE_I mulSNat #-}

-- | Power of two singleton natural numbers
powSNat :: SNat a -> SNat b -> SNat (a^b)
powSNat x y = reifyNat (snatToInteger x ^ snatToInteger y) (unsafeCoerce . SNat)
{-# PRIMITIVE_I powSNat #-}
