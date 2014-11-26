module Elmz.Moore where

import Either(..)

data Moore i o = Moore (i -> Bool) o (i -> Moore i o)

extract : Moore i o -> o
extract (Moore _ o _) = o

step : Moore i o -> (i -> Moore i o)
step (Moore _ _ k) = k

steady : Moore i o -> i -> Bool
steady (Moore same _ _) = same

duplicate : Moore i o -> Moore i (Moore i o)
duplicate m = Moore (steady m) m (step m >> duplicate)

contramap : (i0 -> i) -> Moore i o -> Moore i0 o
contramap f (Moore same o k) = Moore (f >> same) o (f >> k >> contramap f)

map : (o -> o2) -> Moore i o -> Moore i o2
map f (Moore same o k) = Moore same (f o) (k >> map f)

unit : o -> Moore i o
unit o = Moore (always True) o (always (unit o))

map2 : (o1 -> o2 -> o3) -> Moore i o1 -> Moore i o2 -> Moore i o3
map2 f (Moore same1 o1 k1) (Moore same2 o2 k2) =
  Moore (\i -> same1 i && same2 i) (f o1 o2) (\i -> map2 f (k1 i) (k2 i))

ap : Moore i (a -> b) -> Moore i a -> Moore i b
ap = map2 (<|)

emit : o -> Moore i o -> Moore i o
emit oz (Moore same o k) = Moore same oz (k >> emit o)

pipe : Moore a b -> Moore b c -> Moore a c
pipe (Moore same1 b k1) (Moore same2 c k2) =
  let step a = k1 a `pipe` k2 b
      same a = same1 a && same2 b
  in Moore same c step

loop : Moore (a,c) (b,c) -> Moore a b
loop (Moore s (b,c) k) =
  let same a = s (a,c)
      step a = loop (k (a,c))
  in Moore same b step

foldEither : (a -> r) -> (b -> r) -> Either a b -> r
foldEither f1 f2 e = case e of
  Left a -> f1 a
  Right b -> f2 b

either : Moore a (Either x y) -> Moore x b -> Moore y b -> Moore a b
either (Moore samei xy ki) left right =
  let same a = samei a && foldEither (steady left) (steady right) xy
      st a = case xy of
        Left x -> either (ki a) (step left x) right
        Right y -> either (ki a) left (step right y)
      o = case xy of
        Left x -> extract left
        Right y -> extract right
  in Moore same o st

{-| Run the first argument until it emits `Left s`, then switch permanently to `f s`. -}
bind : Moore a (Either s b) -> (s -> Moore a b) -> Moore a b
bind (Moore same sb k) f = case sb of
  Left s -> f s
  Right b -> Moore same b (\a -> bind (k a) f)
