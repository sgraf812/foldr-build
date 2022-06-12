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

# FAQ

## Why not use INLINE pragmas? #1

> Using {-# INLINE source #-} does bring back the fusion-builder. And foldr/build fusion relies on inlining anyway; code similar to the second example could still fail to fuse if the source function would be too large to be automatically marked as inlinable. To be sure that fusion always happens you'd need to add an INLINE pragma to all functions that could potentially fuse.
>
> So what is really the problem that this package addresses? When is it better than adding INLINE pragmas to every fusible function?

Yes, foldr/build fusion relies on inlining. But as always, I want to let GHC churn away on my program without programmer intervention and omit INLINE pragmas unless I absolutely need them. With our current RULE-based approach, that simply doesn't work across modules, independent of the size of the list consumer/producer, because the default unfolding that we export is the RHS *after* optimisation, when RULEs can no longer fire. For example

```hs
module A where

myMap :: (a -> b) -> [a] -> [b]
myMap f xs = build (\k z -> foldr (f . k) z xs)
```

`myMap` may look like a good list producer/consumer. And it has a reasonably small RHS that the programmer might think "GHC will be able to inline it at use sites". And clients might *think* that `myMap` will properly fuse in their modules.

But that assumption is wrong! `myMap` will never fuse across modules. Its unfolding has a local recursive `go` function (I think). Nothing there will fuse, even if you inline it. This is a big problem!

In the past I've seen numerous non-fusing list functions inside base.
This is the most recent example: https://gitlab.haskell.org/ghc/ghc/-/issues/21344
In general, just have a look at the GHC issues labeled with fusion: https://gitlab.haskell.org/ghc/ghc/-/issues/?label_name%5B%5D=fusion

If you grep GHC's `git log` for mentions of `fusion` is also quite illuminating. One rather recent commit was https://gitlab.haskell.org/ghc/ghc/-/commit/e6585ca168ba55ca81a3e6c. The commit claims to fix list fusion for `filterOut` by defining `filterOut p = filter (not . p)`, but it lacks an INLINE pragma! So I'm not even sure if we fixed fusion here, because by the time `filterOut`'s unfolding is exported, `filter` might well have been inlined or rewritten so that it *won't* actually float anymore. (It might not because `filter` isn't saturated, so it fuses *by coincidence*. Haven't checked.)

I'm not trying to bash the commit author here, I'm just saying that it's a very real problem for competent programmers to forget to attach an INLINE, simply because we don't have all the intricacies of list fusion paged into our brains at all times.

Why is lack of fusion in `filterOut` so problematic? Because it means it destroys fusion for *all callees*! Non-fusibility is infective, which means that even if some other data structure combinator makes use of `filterOut` (perhaps one of GHC's `UniqFM`s) and does everything correctly, including an INLINE pragma for its combinator, then fusion is still broken!

[`mkVarEnv`](https://hackage.haskell.org/package/ghc-lib-parser-9.2.3.20220527/docs/src/GHC.Types.Var.Env.html#mkVarEnv) is a good example here. I don't think it fuses! But that's not due to the definition of `mkVarEnv`, which is trivial (thus will be pre-inlined unconditionally), it's due to `listToUFM` not fusing, because it's  not marked as `INLINE` and has a non-trivial RHS that calls `foldl'`. It *could* fuse, but it lacks an INLINE pragma to do so. Note that the RHS isn't particularly large and would no doubt be inlined, but the unfolding isn't useful to do fusion.

By contrast, none of these issues apply to pure foldr/build streams, because they simply rely on beta reduction and the inliner with a RHS that had been optimised to an arbitrary degree, not on "capture my RHS before phase 1 if you want to inline me to get fusion"

 Was this convincing? Would you like to see some of these arguments in the README? Which one?

Perhaps I should write a blog post about the issue.
