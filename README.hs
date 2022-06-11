# Foldr-build

Long-term goal: Deprecation of list fusion by exposing the underlying
foldr/build streaming library (with functions such as
[`mapFB`](https://hackage.haskell.org/package/base-4.16.1.0/docs/src/GHC-Base.html#mapFB))
in `base`.

## Why would we do that?

People rely on list fusion in their programs. I think they shouldn't, because
it's pretty brittle across modules.

Consider
```hs
main = print $ sum [0..2022::Int]
```

If you look at the simplified Core (`-O -ddump-simpl`), you'll see that the list pipeline `sum [0..2022::Int]` optimises to a tight non-allocating loop `Int# -> Int#`

```
Rec {
-- RHS size: {terms: 23, types: 14, coercions: 0, joins: 0/0}
Main.$wgo9 [InlPrag=NOUSERINLINE[2], Occ=LoopBreaker]
  :: GHC.Prim.Int# -> GHC.Prim.Int# -> String
[GblId, Arity=2, Str=<S,1*U><L,U>, Unf=OtherCon []]
Main.$wgo9
  = \ (w_s2AZ :: GHC.Prim.Int#) (ww_s2B3 :: GHC.Prim.Int#) ->
      case w_s2AZ of wild_X1E {
        __DEFAULT ->
          Main.$wgo9
            (GHC.Prim.+# wild_X1E 1#) (GHC.Prim.+# ww_s2B3 wild_X1E);
        2022# ->
          case GHC.Show.$witos
                 (GHC.Prim.+# ww_s2B3 2022#) (GHC.Types.[] @Char)
          of
          { (# ww2_a1Uu, ww3_a1Uv #) ->
          GHC.Types.: @Char ww2_a1Uu ww3_a1Uv
          }
      }
end Rec }
```

Great!

Here is a pretty easy ways to break it: Put the producer in a different module.

```hs
module Producer where

source :: [Int]
source = [0..2022]
```

```hs
import Producer

main = print $ sum source
```

Now GHC hesitates to fuse the consumer `sum` with the producer `source`

```
Rec {
-- RHS size: {terms: 22, types: 21, coercions: 0, joins: 0/0}
Main.$wgo1 [InlPrag=NOUSERINLINE[2], Occ=LoopBreaker]
  :: [Int] -> GHC.Prim.Int# -> String
[GblId, Arity=2, Str=<S,1*U><L,U>, Unf=OtherCon []]
Main.$wgo1
  = \ (w_s2FN :: [Int]) (ww_s2FR :: GHC.Prim.Int#) ->
      case w_s2FN of {
        [] ->
          case GHC.Show.$witos ww_s2FR (GHC.Types.[] @Char) of
          { (# ww2_a1YJ, ww3_a1YK #) ->
          GHC.Types.: @Char ww2_a1YJ ww3_a1YK
          };
        : y_a1XI ys_a1XJ ->
          case y_a1XI of { GHC.Types.I# y1_a1Xx ->
          Main.$wgo1 ys_a1XJ (GHC.Prim.+# ww_s2FR y1_a1Xx)
          }
      }
end Rec }
...
Main.main2 = Main.$wgo1 source 0#
```

**Why is that?** It's because list fusion relies on intricate interplay of
rewriting list expressions (in "Phase 2" of the Simplifier) to so-called *fusion helpers* operating on a church
encoding (like `mapFB`) that enables fusion, and then converting
the residual helpers back to list literals (in "Phase 1").
See the `Note [The rules for map]` for the example of
[`mapFB`](https://hackage.haskell.org/package/base-4.16.1.0/docs/src/GHC-Base.html#mapFB).
By the time the unfolding (that we'll try to inline in the consumer module) is
finalised, *we'll already have wirtten back to lists*! There's no way to get the
fusion-builder back, and thus we don't get to fuse in the consumer module.

## What to do about it?

Simple: expose an API based purely on fusion helpers (combinators such as
`mapFB` working on the church encoding) for the performance-aware user.
Provide explicit conversion functions to and from lists, perhaps through the
`IsList` type class. Also come up with a better name than `FoldrBuild` or fusion
helper; perhaps `Push` (kudos to Andras Kovacz). Example:

```hs
module Data.Stream.Push where

newtype Stream a = Stream { unStream :: forall r. (a -> r -> r) -> r -> r }

sumS :: Stream Int -> Int
sumS (Stream s) = s (+) 0

enumFromToS :: Int -> Int -> Stream Int
enumFromToS from to = Stream (\k z -> foldr k z [from..to])
```
```hs
module Producer where

import Data.Stream.Push

source :: Stream Int
source = enumFromToS 0 2022
```
```hs
module Main where

import Data.Stream.Push
import Producer

main = print $ sumS source
```

and this optimises to the tight loop again!

LET'S DO THIS
