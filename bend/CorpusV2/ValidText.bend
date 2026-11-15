import Base
import ../Units.bend as U

# R7's fixed validation set (docs/r7/PLAN.md, change 8).  The user, 11-14: "A fixed validation set kept out of
# the corpus.  R6's readings during training come from whichever shard it's on, so they tell us nothing."
#
# A source file is held out, with every session of its units, its copy in the filler and every authors' law
# that names it, when the FNV-1a hash of its key, mod 256, is under K (VALID_K, 2 by default: about 0.8% of
# the files).  The key is the id without its source's class (`curated:`, `repo:`, `a2bgh44:`, ...: up to a
# `:` before the first `/`), with a fork's `~BRANCH` after the repository's name dropped, cut at the first `#`
# (a unit's `#NAME@LINE` and the session's shape after it, a filler copy's `#cN`).  So a session, its unit,
# the file in the filler and a law's FILE#NAME all have one key, and a file is held out whole: no session of
# a held-out file is trained on, and none of its text is in the filler.
#
# Pure; the stream split is Valid.bend's.  Every def starts with `vd.`: a Bend program's defs share one
# namespace across its imports.

def vd.head.is(+xs: List<&2, U32>, +c: U32) -> Bool:
  match xs:
    case h <> t:
      U32.is_eq(h, c)
    case Nil{}:
      False{}

# the bytes before the first c (all of them when there is none)
def vd.upto.go(xs: List<&2, U32>, +c: U32, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> +t False{}:
      h <> vd.upto.go(t, c, vd.head.is(t, c))
    case _ _:
      Nil{}

def vd.upto(+xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  vd.upto.go(xs, c, vd.head.is(xs, c))

# the bytes after the first c (none when there is none)
def vd.after.go(xs: List<&2, U32>, +c: U32, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> t True{}:
      t
    case h <> +t False{}:
      vd.after.go(t, c, vd.head.is(t, c))
    case _ _:
      Nil{}

def vd.after(+xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  vd.after.go(xs, c, vd.head.is(xs, c))

# the id without its class: what follows a `:` that comes before the first `/`
def vd.unclass(+id: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, U.has(vd.upto(id, 47), 58), vd.after(id, 58), id)

# a fork's repository as its own: `OWNER__REPO~BRANCH/...` as `OWNER__REPO/...`
def vd.unfork(+p: List<&2, U32>) -> List<&2, U32>:
  +seg = vd.upto(p, 47)
  Bool.pick(List<&2, U32>, U.has(seg, 126), U.append(vd.upto(seg, 126), List.drop(&2, U32, p, U.len(seg))), p)

# a file's key
def vd.key(+id: List<&2, U32>) -> List<&2, U32>:
  vd.upto(vd.unfork(vd.unclass(id)), 35)

# FNV-1a, 32 bits
def vd.fnv.go(xs: List<&2, U32>, +h: U32) -> U32:
  match xs:
    case Nil{}:
      h
    case c <> t:
      vd.fnv.go(t, U32.mul(U32.xor(h, c), 16777619))

def vd.fnv(xs: List<&2, U32>) -> U32:
  vd.fnv.go(xs, 2166136261)

# whether the id's file is held out, K of 256
def vd.held(+k: U32, +id: List<&2, U32>) -> Bool:
  U32.is_lt(U32.and(vd.fnv(vd.key(id)), 255), k)

# Laws ------------------------------------------------------------------------------------------

# a session, its unit, the file in the filler (and its copy) and a law's FILE#NAME: one key
law vd.key.same:
  {(vd.key(U.b("repo:ab__cd~b-fix_1/src/f.bend#g.h@31/mugen-direct-helper-2")), vd.key(U.b("curated:ab__cd/src/f.bend")),
    vd.key(U.b("ab__cd/src/f.bend#g.h")), vd.key(U.b("curated:ab__cd/src/f.bend#c2")), vd.key(U.b("a2bgh44:mods/A/B.bend#B.f@15/mugen-fill")))
   == (U.b("ab__cd/src/f.bend"), U.b("ab__cd/src/f.bend"), U.b("ab__cd/src/f.bend"), U.b("ab__cd/src/f.bend"), U.b("mods/A/B.bend"))
   : List<&2, U32> & List<&2, U32> & List<&2, U32> & List<&2, U32> & List<&2, U32>}

def vd.key.same():
  {==}

# a `:` after the first `/` is the path's, not a class
law vd.key.colon:
  {vd.key(U.b("own:x/a:b.bend#f@1")) == U.b("x/a:b.bend") : List<&2, U32>}

def vd.key.colon():
  {==}

# FNV-1a's offset basis, and its hash of "a" (0xe40c292c)
law vd.fnv.known:
  {(vd.fnv(Nil{}), vd.fnv(U.b("a"))) == (2166136261, 3826002220) : U32 & U32}

def vd.fnv.known():
  {==}

# K 0 holds nothing out and K 256 everything
law vd.held.ends:
  {(vd.held(0, U.b("curated:ab__cd/src/f.bend#g@1")), vd.held(256, U.b("curated:ab__cd/src/f.bend#g@1"))) == (False{}, True{}) : Bool & Bool}

def vd.held.ends():
  {==}
