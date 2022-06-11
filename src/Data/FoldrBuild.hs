{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies #-}

module Data.FoldrBuild where

import GHC.Exts (TYPE, IsList(..), oneShot)

newtype Stream (a :: TYPE r) = Stream { unStream :: forall r. (a -> r -> r) -> r -> r }

instance Foldable Stream where
  foldr k = \z s -> unStream s k z
  {-# INLINE foldr #-}

toS :: Foldable f => f a -> Stream a
toS xs = Stream $ \k z -> foldr k z xs
{-# INLINE[0] toS #-}

toL :: (Stream a) -> [a]
toL (Stream s) = s (:) []
{-# INLINE[0] toL #-}

{-# RULES "toL/toS" forall xs. toL (toS xs) = xs #-}
{-# RULES "toS/toL" forall s. toS (toL s) = s #-}

test :: [Int] -> [Int]
test xs = toL (toS xs)

data L a = N | C a (L a)
instance Foldable L where
  foldr k z = go
    where
      go N = z
      go (C x xs) = k x (go xs)

test' :: L Int -> L Int
test' xs = (\s -> unStream s C N) (toS xs)

instance IsList (Stream a) where
  type Item (Stream a) = a
  fromList = toS
  {-# INLINE fromList #-}
  toList = toL
  {-# INLINE toList #-}
