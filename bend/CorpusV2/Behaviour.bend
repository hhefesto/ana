import Base
import ../Sys.bend as S
import ../Clock.bend as Ck

# bend-corpus-v2 behaviour: the behaviour test (tools/corpus-v2/behaviour/
# README.txt), ana's greedy answers compiled and run against expected
# outputs.  The port of tasks.sh, run.sh and selftest.sh (2026-10-14: all
# logic in Bend), byte-identical to them on every file they wrote.  Run it
# from the repository root.
#
#   behaviour tasks [--check] [LANG...]     spec/LANG.tasks -> tasks/LANG/ and refs/LANG/
#   behaviour run CKPT|REF TAG [LANG...]    generate and check (all three languages by default)
#   behaviour selftest [LANG...]            the checks against spec/selftest.mut's known verdicts
#
# `tasks --check` writes nothing: it exits 1 when a file under tasks/ or
# refs/ is not what the spec makes (or an entry there is not in the spec).
#
# Environment (as run.sh's): TOKENS (160), ANA (run/gcroot-ana/bin/ana),
# ANA_THREADS (4), GEN_JOBS (1), JOBS (3), CHECK_ONLY, REUSE, KEEP_BUILD,
# GHC, MATHLIB, LEAN_BIN, LEAN_TIMEOUT (300), AGDA, AGDA_LIBS, AGDA_TIMEOUT
# (300); BEHAVIOUR_DIR (tools/corpus-v2/behaviour) moves the harness.  A
# variable set to the empty string counts as unset, as `${X:-d}` has it.
#
# The text tests are grep's, sed's and awk's as run.sh ran them under
# en_US.UTF-8 (GNU grep 3.12, gawk 5.4): a grep -w word is [A-Za-z0-9_] or
# a code point glibc calls alphanumeric (bhv.wtab, probed with grep -w over
# every code point on 2026-10-14); `.` and [^[:space:]] never match an
# encoding error; a grep that prints lines drops the ones holding an
# encoding error, and prints nothing from a file holding a NUL.

# Bytes ------------------------------------------------------------------------

def bhv.nl.count(xs: List<&2, U32>, +n: Nat) -> Nat:
  match xs:
    case Nil{}:
      n
    case h <> t:
      bhv.nl.count(t, Nat.add(n, Bool.pick(Nat, U32.is_eq(h, 10), 1n, 0n)))

# lines, each followed by a newline
def bhv.unlines(ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case l <> more:
      List.append(&2, U32, l, 10 <> bhv.unlines(more))

def bhv.cat(xss: List<&2, List<&2, U32>>) -> List<&2, U32>:
  List.concat(&2, U32, xss)

def bhv.elem(+x: List<&2, U32>, ys: List<&2, List<&2, U32>>) -> Bool:
  match ys:
    case Nil{}:
      False{}
    case y <> more:
      Bool.or(S.eq(x, y), bhv.elem(x, more))

def bhv.any.prefix(ls: List<&2, List<&2, U32>>, +p: List<&2, U32>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case l <> more:
      Bool.or(S.prefix(l, p), bhv.any.prefix(more, p))

def bhv.any.infix(+xs: List<&2, U32>, ps: List<&2, List<&2, U32>>) -> Bool:
  match ps:
    case Nil{}:
      False{}
    case p <> more:
      Bool.or(S.infix(xs, p), bhv.any.infix(xs, more))

def bhv.has(xs: List<&2, U32>, +c: U32) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      Bool.or(U32.is_eq(h, c), bhv.has(t, c))

def bhv.empty(+xs: List<&2, U32>) -> Bool:
  Nat.is_eq(S.len(xs), 0n)

# the bytes before the first c (all of them when there is none)
def bhv.before.go(xs: List<&2, U32>, +c: U32, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> +t False{}:
      h <> bhv.before.go(t, c, S.head.is(t, c))
    case _ _:
      Nil{}

def bhv.before(+xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  bhv.before.go(xs, c, S.head.is(xs, c))

# the bytes after the first c (none when there is no c)
def bhv.after(xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> +t:
      Bool.pick(List<&2, U32>, U32.is_eq(h, c), t, bhv.after(t, c))

def bhv.drop.last(+xs: List<&2, U32>) -> List<&2, U32>:
  List.take(&2, U32, xs, Nat.sub(S.len(xs), 1n))

# bytewise order (LC_ALL=C sort)
def bhv.hd(+xs: List<&2, U32>) -> U32:
  match xs:
    case Nil{}:
      0
    case h <> t:
      h

def bhv.hd.lt(+xs: List<&2, U32>, +ys: List<&2, U32>) -> Bool:
  U32.is_lt(bhv.hd(xs), bhv.hd(ys))

def bhv.le.go(a: List<&2, U32>, b: List<&2, U32>, lt: Bool, gt: Bool) -> Bool:
  match a b lt gt:
    case Nil{} _ _ _:
      True{}
    case _ Nil{} _ _:
      False{}
    case _ _ True{} _:
      True{}
    case _ _ False{} True{}:
      False{}
    case x <> +xt y <> +yt False{} False{}:
      bhv.le.go(xt, yt, bhv.hd.lt(xt, yt), bhv.hd.lt(yt, xt))

def bhv.le(+a: List<&2, U32>, +b: List<&2, U32>) -> Bool:
  bhv.le.go(a, b, bhv.hd.lt(a, b), bhv.hd.lt(b, a))

def bhv.le.of(a: List<&2, U32>, b: List<&2, U32>) -> Bool:
  bhv.le(a, b)

def bhv.sort(xs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  List.sort(~List<&2, U32>, ~bhv.le.of, xs)

def bhv.strs(xs: List<&2, String>) -> List<String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> more:
      x <> bhv.strs(more)

def bhv.args(xs: List<String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> more:
      x <> bhv.args(more)

def bhv.bytes.strs(xs: List<&2, List<&2, U32>>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> more:
      S.str(x) <> bhv.bytes.strs(more)

# UTF-8, as glibc's decoder reads it ------------------------------------------
#
# A byte that does not start a valid sequence (an overlong form, a
# surrogate, past U+10FFFF, a lone or missing continuation) is one encoding
# error, bhv.bad(), and the next byte starts afresh, as grep steps over one.

def bhv.bad() -> U32:
  4294967295

def bhv.bads(n: Nat) -> List<&2, U32>:
  match n:
    case 0n:
      Nil{}
    case 1n+m:
      bhv.bad() <> bhv.bads(m)

# a lead byte: 0 ASCII, 1 C2-DF, 2 E0, 3 E1-EC EE-EF, 4 ED, 5 F0, 6 F1-F3, 7 F4, 8 none
def bhv.u8.cls(+b: U32) -> Nat:
  Bool.pick(Nat, U32.is_lt(b, 128), 0n,
  Bool.pick(Nat, Bool.and(U32.is_ge(b, 194), U32.is_le(b, 223)), 1n,
  Bool.pick(Nat, U32.is_eq(b, 224), 2n,
  Bool.pick(Nat, U32.is_eq(b, 237), 4n,
  Bool.pick(Nat, Bool.and(U32.is_ge(b, 225), U32.is_le(b, 239)), 3n,
  Bool.pick(Nat, U32.is_eq(b, 240), 5n,
  Bool.pick(Nat, Bool.and(U32.is_ge(b, 241), U32.is_le(b, 243)), 6n,
  Bool.pick(Nat, U32.is_eq(b, 244), 7n, 8n))))))))

# what the next byte is to the decoder, need continuation bytes still due
# (the next in lo..hi): 0 the end, 1 the end inside a sequence, 2-10 a lead
# byte (2 + its class), 11 the last continuation, 12 a continuation with
# more due, 13 a byte that breaks the sequence
def bhv.u8.ev(xs: List<&2, U32>, need: Nat, +lo: U32, +hi: U32) -> Nat:
  match xs need:
    case Nil{} 0n:
      0n
    case Nil{} 1n+r:
      1n
    case +b <> t 0n:
      Nat.add(2n, bhv.u8.cls(b))
    case +b <> t 1n+r:
      Bool.pick(Nat, Bool.and(U32.is_ge(b, lo), U32.is_le(b, hi)), Bool.pick(Nat, Nat.is_eq(r, 0n), 11n, 12n), 13n)

def bhv.u8.add(+cp: U32, +b: U32) -> U32:
  U32.add(U32.mul(cp, 64), U32.and(b, 63))

def bhv.u8.go(fuel: Nat, ev: Nat, xs: List<&2, U32>, +need: Nat, +lo: U32, +hi: U32, +cp: U32, +k: Nat) -> List<&2, U32>:
  match fuel ev xs:
    case 0n _ _:
      Nil{}
    case 1n+f 0n _:
      Nil{}
    case 1n+f 1n _:
      bhv.bads(1n+k)
    case 1n+f 2n +b <> +t:
      b <> bhv.u8.go(f, bhv.u8.ev(t, 0n, 0, 0), t, 0n, 0, 0, 0, 0n)
    case 1n+f 3n +b <> +t:
      bhv.u8.go(f, bhv.u8.ev(t, 1n, 128, 191), t, 1n, 128, 191, U32.and(b, 31), 0n)
    case 1n+f 4n +b <> +t:
      bhv.u8.go(f, bhv.u8.ev(t, 2n, 160, 191), t, 2n, 160, 191, U32.and(b, 15), 0n)
    case 1n+f 5n +b <> +t:
      bhv.u8.go(f, bhv.u8.ev(t, 2n, 128, 191), t, 2n, 128, 191, U32.and(b, 15), 0n)
    case 1n+f 6n +b <> +t:
      bhv.u8.go(f, bhv.u8.ev(t, 2n, 128, 159), t, 2n, 128, 159, U32.and(b, 15), 0n)
    case 1n+f 7n +b <> +t:
      bhv.u8.go(f, bhv.u8.ev(t, 3n, 144, 191), t, 3n, 144, 191, U32.and(b, 7), 0n)
    case 1n+f 8n +b <> +t:
      bhv.u8.go(f, bhv.u8.ev(t, 3n, 128, 191), t, 3n, 128, 191, U32.and(b, 7), 0n)
    case 1n+f 9n +b <> +t:
      bhv.u8.go(f, bhv.u8.ev(t, 3n, 128, 143), t, 3n, 128, 143, U32.and(b, 7), 0n)
    case 1n+f 10n +b <> +t:
      bhv.bad() <> bhv.u8.go(f, bhv.u8.ev(t, 0n, 0, 0), t, 0n, 0, 0, 0, 0n)
    case 1n+f 11n +b <> +t:
      bhv.u8.add(cp, b) <> bhv.u8.go(f, bhv.u8.ev(t, 0n, 0, 0), t, 0n, 0, 0, 0, 0n)
    case 1n+f 12n +b <> +t:
      bhv.u8.go(f, bhv.u8.ev(t, Nat.sub(need, 1n), 128, 191), t, Nat.sub(need, 1n), 128, 191, bhv.u8.add(cp, b), 1n+k)
    case 1n+f 13n +b <> +t:
      List.append(&2, U32, bhv.bads(1n+k), bhv.u8.go(f, bhv.u8.ev(b <> t, 0n, 0, 0), b <> t, 0n, 0, 0, 0, 0n))
    case 1n+f _ _:
      Nil{}

# the code points of xs (bhv.bad() for an encoding error)
def bhv.u8(+xs: List<&2, U32>) -> List<&2, U32>:
  bhv.u8.go(Nat.add(Nat.mul(2n, S.len(xs)), 2n), bhv.u8.ev(xs, 0n, 0, 0), xs, 0n, 0, 0, 0, 0n)

def bhv.valid(+xs: List<&2, U32>) -> Bool:
  Bool.not(bhv.has(bhv.u8(xs), bhv.bad()))

# the length of xs's first character; 0 when xs is empty or starts with an
# encoding error or a newline (what `.` does not match)
def bhv.u8.len.of(cs: List<&2, U32>) -> Nat:
  match cs:
    case Nil{}:
      0n
    case +c <> t:
      Bool.pick(Nat, Bool.or(U32.is_eq(c, bhv.bad()), U32.is_eq(c, 10)), 0n,
        Bool.pick(Nat, U32.is_lt(c, 128), 1n, Bool.pick(Nat, U32.is_lt(c, 2048), 2n, Bool.pick(Nat, U32.is_lt(c, 65536), 3n, 4n))))

def bhv.u8.len1(+xs: List<&2, U32>) -> Nat:
  bhv.u8.len.of(bhv.u8(List.take(&2, U32, xs, 4n)))

# grep -w's word characters beyond ASCII: the code points glibc's iswalnum
# accepts in en_US.UTF-8, as hexadecimal ranges (804 of them; GNU grep 3.12
# -w over every code point, before and after the word, on 2026-10-14)
def bhv.wtab() -> String:
  "aa b5 ba c0-d6 d8-f6 f8-2c1 2c6-2d1 2e0-2e4 2ec 2ee 345 363-374 376-377 37a-37d 37f 386 388-38a " ++
  "38c 38e-3a1 3a3-3f5 3f7-481 48a-52f 531-556 559 560-588 5b0-5bd 5bf 5c1-5c2 5c4-5c5 5c7 5d0-5ea " ++
  "5ef-5f2 610-61a 620-657 659-669 66e-6d3 6d5-6dc 6e1-6e8 6ed-6fc 6ff 710-73f 74d-7b1 7c0-7ea " ++
  "7f4-7f5 7fa 800-817 81a-82c 840-858 860-86a 870-887 889-88f 897 8a0-8c9 8d4-8df 8e3-8e9 8f0-93b " ++
  "93d-94c 94e-950 955-963 966-96f 971-983 985-98c 98f-990 993-9a8 9aa-9b0 9b2 9b6-9b9 9bd-9c4 " ++
  "9c7-9c8 9cb-9cc 9ce 9d7 9dc-9dd 9df-9e3 9e6-9f1 9fc a01-a03 a05-a0a a0f-a10 a13-a28 a2a-a30 " ++
  "a32-a33 a35-a36 a38-a39 a3e-a42 a47-a48 a4b-a4c a51 a59-a5c a5e a66-a75 a81-a83 a85-a8d a8f-a91 " ++
  "a93-aa8 aaa-ab0 ab2-ab3 ab5-ab9 abd-ac5 ac7-ac9 acb-acc ad0 ae0-ae3 ae6-aef af9-afc b01-b03 " ++
  "b05-b0c b0f-b10 b13-b28 b2a-b30 b32-b33 b35-b39 b3d-b44 b47-b48 b4b-b4c b56-b57 b5c-b5d b5f-b63 " ++
  "b66-b6f b71 b82-b83 b85-b8a b8e-b90 b92-b95 b99-b9a b9c b9e-b9f ba3-ba4 ba8-baa bae-bb9 bbe-bc2 " ++
  "bc6-bc8 bca-bcc bd0 bd7 be6-bef c00-c0c c0e-c10 c12-c28 c2a-c39 c3d-c44 c46-c48 c4a-c4c c55-c56 " ++
  "c58-c5a c5c-c5d c60-c63 c66-c6f c80-c83 c85-c8c c8e-c90 c92-ca8 caa-cb3 cb5-cb9 cbd-cc4 cc6-cc8 " ++
  "cca-ccc cd5-cd6 cdc-cde ce0-ce3 ce6-cef cf1-cf3 d00-d0c d0e-d10 d12-d3a d3d-d44 d46-d48 d4a-d4c " ++
  "d4e d54-d57 d5f-d63 d66-d6f d7a-d7f d81-d83 d85-d96 d9a-db1 db3-dbb dbd dc0-dc6 dcf-dd4 dd6 " ++
  "dd8-ddf de6-def df2-df3 e01-e3a e40-e46 e4d e50-e59 e81-e82 e84 e86-e8a e8c-ea3 ea5 ea7-eb9 " ++
  "ebb-ebd ec0-ec4 ec6 ecd ed0-ed9 edc-edf f00 f20-f29 f40-f47 f49-f6c f71-f83 f88-f97 f99-fbc " ++
  "1000-1036 1038 103b-1049 1050-109d 10a0-10c5 10c7 10cd 10d0-10fa 10fc-1248 124a-124d 1250-1256 " ++
  "1258 125a-125d 1260-1288 128a-128d 1290-12b0 12b2-12b5 12b8-12be 12c0 12c2-12c5 12c8-12d6 " ++
  "12d8-1310 1312-1315 1318-135a 1380-138f 13a0-13f5 13f8-13fd 1401-166c 166f-167f 1681-169a " ++
  "16a0-16ea 16ee-16f8 1700-1713 171f-1733 1740-1753 1760-176c 176e-1770 1772-1773 1780-17b3 " ++
  "17b6-17c8 17d7 17dc 17e0-17e9 1810-1819 1820-1878 1880-18aa 18b0-18f5 1900-191e 1920-192b " ++
  "1930-1938 1946-196d 1970-1974 1980-19ab 19b0-19c9 19d0-19d9 1a00-1a1b 1a20-1a5e 1a61-1a74 " ++
  "1a80-1a89 1a90-1a99 1aa7 1abf-1ac0 1acc-1ace 1b00-1b33 1b35-1b43 1b45-1b4c 1b50-1b59 1b80-1ba9 " ++
  "1bac-1be5 1be7-1bf1 1c00-1c36 1c40-1c49 1c4d-1c7d 1c80-1c8a 1c90-1cba 1cbd-1cbf 1ce9-1cec " ++
  "1cee-1cf3 1cf5-1cf6 1cfa 1d00-1dbf 1dd3-1df4 1e00-1f15 1f18-1f1d 1f20-1f45 1f48-1f4d 1f50-1f57 " ++
  "1f59 1f5b 1f5d 1f5f-1f7d 1f80-1fb4 1fb6-1fbc 1fbe 1fc2-1fc4 1fc6-1fcc 1fd0-1fd3 1fd6-1fdb " ++
  "1fe0-1fec 1ff2-1ff4 1ff6-1ffc 2071 207f 2090-209c 2102 2107 210a-2113 2115 2119-211d 2124 2126 " ++
  "2128 212a-212d 212f-2139 213c-213f 2145-2149 214e 2160-2188 24b6-24e9 2c00-2ce4 2ceb-2cee " ++
  "2cf2-2cf3 2d00-2d25 2d27 2d2d 2d30-2d67 2d6f 2d80-2d96 2da0-2da6 2da8-2dae 2db0-2db6 2db8-2dbe " ++
  "2dc0-2dc6 2dc8-2dce 2dd0-2dd6 2dd8-2dde 2de0-2dff 2e2f 3005-3007 3021-3029 3031-3035 3038-303c " ++
  "3041-3096 309d-309f 30a1-30fa 30fc-30ff 3105-312f 3131-318e 31a0-31bf 31f0-31ff 3400-4dbf " ++
  "4e00-a48c a4d0-a4fd a500-a60c a610-a62b a640-a66e a674-a67b a67f-a6ef a717-a71f a722-a788 " ++
  "a78b-a7dc a7f1-a805 a807-a827 a840-a873 a880-a8c3 a8c5 a8d0-a8d9 a8f2-a8f7 a8fb a8fd-a92a " ++
  "a930-a952 a960-a97c a980-a9b2 a9b4-a9bf a9cf-a9d9 a9e0-a9fe aa00-aa36 aa40-aa4d aa50-aa59 " ++
  "aa60-aa76 aa7a-aabe aac0 aac2 aadb-aadd aae0-aaef aaf2-aaf5 ab01-ab06 ab09-ab0e ab11-ab16 " ++
  "ab20-ab26 ab28-ab2e ab30-ab5a ab5c-ab69 ab70-abea abf0-abf9 ac00-d7a3 d7b0-d7c6 d7cb-d7fb " ++
  "f900-fa6d fa70-fad9 fb00-fb06 fb13-fb17 fb1d-fb28 fb2a-fb36 fb38-fb3c fb3e fb40-fb41 fb43-fb44 " ++
  "fb46-fbb1 fbd3-fd3d fd50-fd8f fd92-fdc7 fdf0-fdfb fe70-fe74 fe76-fefc ff10-ff19 ff21-ff3a " ++
  "ff41-ff5a ff66-ffbe ffc2-ffc7 ffca-ffcf ffd2-ffd7 ffda-ffdc 10000-1000b 1000d-10026 10028-1003a " ++
  "1003c-1003d 1003f-1004d 10050-1005d 10080-100fa 10140-10174 10280-1029c 102a0-102d0 10300-1031f " ++
  "1032d-1034a 10350-1037a 10380-1039d 103a0-103c3 103c8-103cf 103d1-103d5 10400-1049d 104a0-104a9 " ++
  "104b0-104d3 104d8-104fb 10500-10527 10530-10563 10570-1057a 1057c-1058a 1058c-10592 10594-10595 " ++
  "10597-105a1 105a3-105b1 105b3-105b9 105bb-105bc 105c0-105f3 10600-10736 10740-10755 10760-10767 " ++
  "10780-10785 10787-107b0 107b2-107ba 10800-10805 10808 1080a-10835 10837-10838 1083c 1083f-10855 " ++
  "10860-10876 10880-1089e 108e0-108f2 108f4-108f5 10900-10915 10920-10939 10940-10959 10980-109b7 " ++
  "109be-109bf 10a00-10a03 10a05-10a06 10a0c-10a13 10a15-10a17 10a19-10a35 10a60-10a7c 10a80-10a9c " ++
  "10ac0-10ac7 10ac9-10ae4 10b00-10b35 10b40-10b55 10b60-10b72 10b80-10b91 10c00-10c48 10c80-10cb2 " ++
  "10cc0-10cf2 10d00-10d27 10d30-10d39 10d40-10d65 10d69 10d6f-10d85 10e80-10ea9 10eab-10eac " ++
  "10eb0-10eb1 10ec2-10ec7 10efa-10efc 10f00-10f1c 10f27 10f30-10f45 10f70-10f81 10fb0-10fc4 " ++
  "10fe0-10ff6 11000-11045 11066-1106f 11071-11075 11080-110b8 110c2 110d0-110e8 110f0-110f9 " ++
  "11100-11132 11136-1113f 11144-11147 11150-11172 11176 11180-111bf 111c1-111c4 111ce-111da 111dc " ++
  "11200-11211 11213-11234 11237 1123e-11241 11280-11286 11288 1128a-1128d 1128f-1129d 1129f-112a8 " ++
  "112b0-112e8 112f0-112f9 11300-11303 11305-1130c 1130f-11310 11313-11328 1132a-11330 11332-11333 " ++
  "11335-11339 1133d-11344 11347-11348 1134b-1134c 11350 11357 1135d-11363 11380-11389 1138b 1138e " ++
  "11390-113b5 113b7-113c0 113c2 113c5 113c7-113ca 113cc-113cd 113d1 113d3 11400-11441 11443-11445 " ++
  "11447-1144a 11450-11459 1145f-11461 11480-114c1 114c4-114c5 114c7 114d0-114d9 11580-115b5 " ++
  "115b8-115be 115d8-115dd 11600-1163e 11640 11644 11650-11659 11680-116b5 116b8 116c0-116c9 " ++
  "116d0-116e3 11700-1171a 1171d-1172a 11730-11739 11740-11746 11800-11838 118a0-118e9 118ff-11906 " ++
  "11909 1190c-11913 11915-11916 11918-11935 11937-11938 1193b-1193c 1193f-11942 11950-11959 " ++
  "119a0-119a7 119aa-119d7 119da-119df 119e1 119e3-119e4 11a00-11a32 11a35-11a3e 11a50-11a97 11a9d " ++
  "11ab0-11af8 11b60-11b67 11bc0-11be0 11bf0-11bf9 11c00-11c08 11c0a-11c36 11c38-11c3e 11c40 " ++
  "11c50-11c59 11c72-11c8f 11c92-11ca7 11ca9-11cb6 11d00-11d06 11d08-11d09 11d0b-11d36 11d3a " ++
  "11d3c-11d3d 11d3f-11d41 11d43 11d46-11d47 11d50-11d59 11d60-11d65 11d67-11d68 11d6a-11d8e " ++
  "11d90-11d91 11d93-11d96 11d98 11da0-11da9 11db0-11ddb 11de0-11de9 11ee0-11ef6 11f00-11f10 " ++
  "11f12-11f3a 11f3e-11f40 11f50-11f59 11fb0 12000-12399 12400-1246e 12480-12543 12f90-12ff0 " ++
  "13000-1342f 13441-13446 13460-143fa 14400-14646 16100-1612e 16130-16139 16800-16a38 16a40-16a5e " ++
  "16a60-16a69 16a70-16abe 16ac0-16ac9 16ad0-16aed 16b00-16b2f 16b40-16b43 16b50-16b59 16b63-16b77 " ++
  "16b7d-16b8f 16d40-16d6c 16d70-16d79 16e40-16e7f 16ea0-16eb8 16ebb-16ed3 16f00-16f4a 16f4f-16f87 " ++
  "16f8f-16f9f 16fe0-16fe1 16fe3 16ff0-16ff6 17000-18cd5 18cff-18d1e 18d80-18df2 1aff0-1aff3 " ++
  "1aff5-1affb 1affd-1affe 1b000-1b122 1b132 1b150-1b152 1b155 1b164-1b167 1b170-1b2fb 1bc00-1bc6a " ++
  "1bc70-1bc7c 1bc80-1bc88 1bc90-1bc99 1bc9e 1ccf0-1ccf9 1d400-1d454 1d456-1d49c 1d49e-1d49f 1d4a2 " ++
  "1d4a5-1d4a6 1d4a9-1d4ac 1d4ae-1d4b9 1d4bb 1d4bd-1d4c3 1d4c5-1d505 1d507-1d50a 1d50d-1d514 " ++
  "1d516-1d51c 1d51e-1d539 1d53b-1d53e 1d540-1d544 1d546 1d54a-1d550 1d552-1d6a5 1d6a8-1d6c0 " ++
  "1d6c2-1d6da 1d6dc-1d6fa 1d6fc-1d714 1d716-1d734 1d736-1d74e 1d750-1d76e 1d770-1d788 1d78a-1d7a8 " ++
  "1d7aa-1d7c2 1d7c4-1d7cb 1d7ce-1d7ff 1df00-1df1e 1df25-1df2a 1e000-1e006 1e008-1e018 1e01b-1e021 " ++
  "1e023-1e024 1e026-1e02a 1e030-1e06d 1e08f 1e100-1e12c 1e137-1e13d 1e140-1e149 1e14e 1e290-1e2ad " ++
  "1e2c0-1e2eb 1e2f0-1e2f9 1e4d0-1e4eb 1e4f0-1e4f9 1e5d0-1e5ed 1e5f0-1e5fa 1e6c0-1e6de 1e6e0-1e6f5 " ++
  "1e6fe-1e6ff 1e7e0-1e7e6 1e7e8-1e7eb 1e7ed-1e7ee 1e7f0-1e7fe 1e800-1e8c4 1e900-1e943 1e947 1e94b " ++
  "1e950-1e959 1ee00-1ee03 1ee05-1ee1f 1ee21-1ee22 1ee24 1ee27 1ee29-1ee32 1ee34-1ee37 1ee39 1ee3b " ++
  "1ee42 1ee47 1ee49 1ee4b 1ee4d-1ee4f 1ee51-1ee52 1ee54 1ee57 1ee59 1ee5b 1ee5d 1ee5f 1ee61-1ee62 " ++
  "1ee64 1ee67-1ee6a 1ee6c-1ee72 1ee74-1ee77 1ee79-1ee7c 1ee7e 1ee80-1ee89 1ee8b-1ee9b 1eea1-1eea3 " ++
  "1eea5-1eea9 1eeab-1eebb 1f130-1f149 1f150-1f169 1f170-1f189 1fbf0-1fbf9 20000-2a6df 2a700-2b81d " ++
  "2b820-2cead 2ceb0-2ebe0 2ebf0-2ee5d 2f800-2fa1d 30000-3134a 31350-33479"

type BhR is Data:
  BhR{lo: U32, hi: U32}

def bhv.hex(xs: List<&2, U32>, +acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case +h <> t:
      bhv.hex(t, U32.add(U32.mul(acc, 16), Bool.pick(U32, U32.is_le(h, 57), U32.sub(h, 48), U32.sub(h, 87))))

def bhv.range(dash: Bool, +tok: List<&2, U32>) -> BhR:
  match dash:
    case True{}:
      BhR{bhv.hex(bhv.before(tok, 45), 0), bhv.hex(bhv.after(tok, 45), 0)}
    case False{}:
      BhR{bhv.hex(tok, 0), bhv.hex(tok, 0)}

def bhv.ranges(ts: List<&2, List<&2, U32>>) -> List<&2, BhR>:
  match ts:
    case Nil{}:
      Nil{}
    case +t <> more:
      bhv.range(bhv.has(t, 45), t) <> bhv.ranges(more)

def bhv.in(rs: List<&2, BhR>, +c: U32) -> Bool:
  match rs:
    case Nil{}:
      False{}
    case BhR{lo, hi} <> more:
      Bool.or(Bool.and(U32.is_ge(c, lo), U32.is_le(c, hi)), bhv.in(more, c))

# a word character of grep -w (the table is read only off ASCII)
def bhv.wc.pick(ascii: Bool, +c: U32) -> Bool:
  match ascii:
    case True{}:
      Bool.or(Bool.or(Bool.and(U32.is_ge(c, 97), U32.is_le(c, 122)), Bool.and(U32.is_ge(c, 65), U32.is_le(c, 90))),
        Bool.or(Bool.and(U32.is_ge(c, 48), U32.is_le(c, 57)), U32.is_eq(c, 95)))
    case False{}:
      bhv.in(bhv.ranges(S.split(S.b(bhv.wtab()), 32)), c)

def bhv.wc(+c: U32) -> Bool:
  bhv.wc.pick(U32.is_lt(c, 128), c)

# [[:space:]] in en_US.UTF-8 (probed as the word table was): tab to CR,
# space, U+1680, U+2000-2006, U+2008-200A, U+2028-2029, U+205F, U+3000
# (not the no-break spaces U+00A0, U+2007, U+202F)
def bhv.space(+c: U32) -> Bool:
  Bool.or(Bool.or(Bool.and(U32.is_ge(c, 9), U32.is_le(c, 13)), Bool.or(U32.is_eq(c, 32), U32.is_eq(c, 5760))),
    Bool.or(Bool.or(Bool.and(U32.is_ge(c, 8192), U32.is_le(c, 8198)), Bool.and(U32.is_ge(c, 8200), U32.is_le(c, 8202))),
      Bool.or(Bool.or(U32.is_eq(c, 8232), U32.is_eq(c, 8233)), Bool.or(U32.is_eq(c, 8287), U32.is_eq(c, 12288)))))

# grep -q '[^[:space:]]': a character that is not a space (an encoding
# error is no character; a NUL is a line end to grep)
def bhv.ink(cs: List<&2, U32>) -> Bool:
  match cs:
    case Nil{}:
      False{}
    case +c <> t:
      Bool.or(Bool.not(Bool.or(bhv.space(c), Bool.or(U32.is_eq(c, 0), U32.is_eq(c, bhv.bad())))), bhv.ink(t))

# What a grep prints ----------------------------------------------------------

def bhv.valid.lines(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      +r = bhv.valid.lines(more)
      Bool.pick(List<&2, List<&2, U32>>, bhv.valid(l), l <> r, r)

# the lines of xs a printing grep can show: none from a file with a NUL,
# else the ones without an encoding error
def bhv.shown.if(nul: Bool, +xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match nul:
    case True{}:
      Nil{}
    case False{}:
      bhv.valid.lines(S.split.lines(xs))

def bhv.shown(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  bhv.shown.if(bhv.has(xs, 0), xs)

def bhv.minus(ls: List<&2, List<&2, U32>>, +ps: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      +r = bhv.minus(more, ps)
      Bool.pick(List<&2, List<&2, U32>>, bhv.elem(l, ps), r, l <> r)

# grep -vxF "$sig" FILE: the lines of xs equal to none of sig's lines
def bhv.grepv(+xs: List<&2, U32>, +sig: List<&2, U32>) -> List<&2, U32>:
  bhv.unlines(bhv.minus(bhv.shown(xs), S.split.str(sig, [10])))

# $(cat FILE): bash drops NUL bytes and the trailing newlines
def bhv.subst(+xs: List<&2, U32>) -> List<&2, U32>:
  S.chomp(S.no.nul(xs))

def bhv.lines.any.eq(ls: List<&2, List<&2, U32>>, +p: List<&2, U32>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case l <> more:
      Bool.or(S.eq(l, p), bhv.lines.any.eq(more, p))

# The checks' text tests ------------------------------------------------------

# grep -qEw 'sorry|admit|axiom|implemented_by|extern|unsafe'
def bhv.lean.words() -> List<&2, List<&2, U32>>:
  [S.b("sorry"), S.b("admit"), S.b("axiom"), S.b("implemented_by"), S.b("extern"), S.b("unsafe")]

def bhv.w.end(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +h <> t:
      Bool.not(bhv.wc(h))

def bhv.w.one(hit: Bool, rest: List<&2, U32>) -> Bool:
  match hit:
    case True{}:
      bhv.w.end(rest)
    case False{}:
      False{}

# one of ws starts cs and a non-word character (or the end) follows it
def bhv.w.at(ws: List<&2, List<&2, U32>>, +cs: List<&2, U32>) -> Bool:
  match ws:
    case Nil{}:
      False{}
    case +w <> more:
      Bool.or(bhv.w.one(S.prefix(cs, w), List.drop(&2, U32, cs, S.len(w))), bhv.w.at(more, cs))

def bhv.w.hit(at: Bool, +prev: U32) -> Bool:
  match at:
    case True{}:
      Bool.not(bhv.wc(prev))
    case False{}:
      False{}

# prev: the character before cs (a newline at the start)
def bhv.w.go(cs: List<&2, U32>, +ws: List<&2, List<&2, U32>>, +prev: U32) -> Bool:
  match cs:
    case Nil{}:
      False{}
    case +h <> +t:
      Bool.or(bhv.w.hit(bhv.w.at(ws, h <> t), prev), bhv.w.go(t, ws, h))

def bhv.lean.gives.up(+term: List<&2, U32>) -> Bool:
  bhv.w.go(bhv.u8(term), bhv.lean.words(), 10)

# grep -q 'declaration uses .sorry'
def bhv.dus.n(n: Nat, +r: List<&2, U32>, +s: List<&2, U32>) -> Bool:
  match n:
    case 0n:
      False{}
    case 1n+m:
      S.prefix(List.drop(&2, U32, r, 1n+m), s)

def bhv.dus.hit(hit: Bool, +r: List<&2, U32>, +s: List<&2, U32>) -> Bool:
  match hit:
    case True{}:
      bhv.dus.n(bhv.u8.len1(r), r, s)
    case False{}:
      False{}

def bhv.dus.go(xs: List<&2, U32>, +p: List<&2, U32>, +s: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> +t:
      Bool.or(bhv.dus.hit(S.prefix(h <> t, p), List.drop(&2, U32, h <> t, 17n), s), bhv.dus.go(t, p, s))

def bhv.dus(+xs: List<&2, U32>) -> Bool:
  bhv.dus.go(xs, S.b("declaration uses "), S.b("sorry"))

# NAME's axioms beyond the allowed ones (grep "'NAME' depends on axioms: " |
# sed 's/.*axioms: \[//; s/\]$//' | tr ',' '\n' | tr -d ' ' | grep -vxE ALLOWED | head -1):
# refused when the first piece left is not empty
def bhv.ax.ok() -> List<&2, List<&2, U32>>:
  [S.b("propext"), S.b("Classical.choice"), S.b("Quot.sound"), S.b("Lean.ofReduceBool"), S.b("Lean.trustCompiler")]

# the bytes after the last p (cur when there is none)
def bhv.after.last(xs: List<&2, U32>, +p: List<&2, U32>, cur: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      cur
    case +h <> +t:
      bhv.after.last(t, p, Bool.pick(List<&2, U32>, S.prefix(h <> t, p), List.drop(&2, U32, h <> t, S.len(p)), cur))

def bhv.unbracket(+xs: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, S.suffix(xs, [93]), bhv.drop.last(xs), xs)

def bhv.nospace(xss: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xss:
    case Nil{}:
      Nil{}
    case x <> more:
      List.filter(~U32, ~(c => U32.is_ne(c, 32)), x) <> bhv.nospace(more)

def bhv.ax.line(+l: List<&2, U32>) -> List<&2, List<&2, U32>>:
  bhv.nospace(S.split.str(bhv.unbracket(bhv.after.last(l, S.b("axioms: ["), l)), [44]))

def bhv.ax.pieces(ls: List<&2, List<&2, U32>>, +pat: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      +r = bhv.ax.pieces(more, pat)
      Bool.pick(List<&2, List<&2, U32>>, S.infix(l, pat), List.append(&2, List<&2, U32>, bhv.ax.line(l), r), r)

def bhv.ax.first.full(ps: List<&2, List<&2, U32>>) -> Bool:
  match ps:
    case Nil{}:
      False{}
    case +p <> more:
      Bool.not(bhv.empty(p))

def bhv.ax.refused(+log: List<&2, U32>, +name: String) -> Bool:
  bhv.ax.first.full(bhv.minus(bhv.ax.pieces(bhv.shown(log), S.b("'" ++ name ++ "' depends on axioms: ")), bhv.ax.ok()))

# Agda: grep -qE 'postulate|\{!|TERMINATING|...'
def bhv.agda.pats() -> List<&2, List<&2, U32>>:
  [S.b("postulate"), S.b("{!"), S.b("TERMINATING"), S.b("NON_TERMINATING"), S.b("NO_POSITIVITY_CHECK"), S.b("NO_UNIVERSE_CHECK"),
   S.b("NO_TERMINATION_CHECK"), S.b("INJECTIVE"), S.b("BUILTIN"), S.b("REWRITE"), S.b("OPTIONS"), S.b("trustMe"), S.b("primEraseEquality")]

# a field separator of awk's once ( ) { } ; are blanks
def bhv.q.sep(+c: U32) -> Bool:
  Bool.or(Bool.or(Bool.or(U32.is_eq(c, 32), U32.is_eq(c, 9)), Bool.or(U32.is_eq(c, 10), U32.is_eq(c, 40))),
    Bool.or(Bool.or(U32.is_eq(c, 41), U32.is_eq(c, 123)), Bool.or(U32.is_eq(c, 125), U32.is_eq(c, 59))))

def bhv.q.end(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +h <> t:
      bhv.q.sep(h)

# awk '{ gsub(/[(){};]/, " "); for (i = 1; i <= NF; i++) if ($i == "?") f = 1 }': a lone `?`
def bhv.q.go(xs: List<&2, U32>, +sep: Bool) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> +t:
      Bool.or(Bool.and(Bool.and(sep, U32.is_eq(h, 63)), bhv.q.end(t)), bhv.q.go(t, bhv.q.sep(h)))

def bhv.agda.gives.up(+term: List<&2, U32>) -> Bool:
  Bool.or(bhv.any.infix(term, bhv.agda.pats()), bhv.q.go(term, True{}))

# The first error's line in an Agda log: the first line matching
# `Task\.agda:[0-9]+[.,][-0-9.,]*: error`, then its first `Task\.agda:[0-9]+`
def bhv.d.is(+c: U32) -> Bool:
  Bool.and(U32.is_ge(c, 48), U32.is_le(c, 57))

def bhv.d.head(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      bhv.d.is(h)

def bhv.digits.go(xs: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> +t True{}:
      h <> bhv.digits.go(t, bhv.d.head(t))
    case _ _:
      Nil{}

def bhv.digits(+xs: List<&2, U32>) -> List<&2, U32>:
  bhv.digits.go(xs, bhv.d.head(xs))

def bhv.set.is(+c: U32) -> Bool:
  Bool.or(bhv.d.is(c), Bool.or(Bool.or(U32.is_eq(c, 45), U32.is_eq(c, 46)), U32.is_eq(c, 44)))

def bhv.set.head(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      bhv.set.is(h)

def bhv.skip.set(xs: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> +t True{}:
      bhv.skip.set(t, bhv.set.head(t))
    case ys _:
      ys

def bhv.ag.sep(+xs: List<&2, U32>) -> Bool:
  Bool.or(S.head.is(xs, 46), S.head.is(xs, 44))

def bhv.ag.tail(ok: Bool, +r: List<&2, U32>) -> Bool:
  match ok:
    case True{}:
      S.prefix(bhv.skip.set(r, bhv.set.head(r)), S.b(": error"))
    case False{}:
      False{}

def bhv.ag.num.ok(n: Nat, +r: List<&2, U32>) -> Bool:
  match n:
    case 0n:
      False{}
    case 1n+m:
      +rest = List.drop(&2, U32, r, 1n+m)
      bhv.ag.tail(bhv.ag.sep(rest), rest)

def bhv.ag.hit(hit: Bool, +r: List<&2, U32>) -> Bool:
  match hit:
    case True{}:
      bhv.ag.num.ok(S.len(bhv.digits(r)), r)
    case False{}:
      False{}

def bhv.ag.scan(xs: List<&2, U32>, +p: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> +t:
      Bool.or(bhv.ag.hit(S.prefix(h <> t, p), List.drop(&2, U32, h <> t, 10n)), bhv.ag.scan(t, p))

def bhv.ag.num.at(hit: Bool, +r: List<&2, U32>) -> List<&2, U32>:
  match hit:
    case True{}:
      bhv.digits(r)
    case False{}:
      Nil{}

# the digits after the first `Task.agda:` followed by one
def bhv.ag.num(xs: List<&2, U32>, +p: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> +t:
      +here = bhv.ag.num.at(S.prefix(h <> t, p), List.drop(&2, U32, h <> t, 10n))
      Bool.pick(List<&2, U32>, bhv.empty(here), bhv.ag.num(t, p), here)

def bhv.ag.el(ls: List<&2, List<&2, U32>>, +p: List<&2, U32>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      Bool.pick(List<&2, U32>, bhv.ag.scan(l, p), bhv.ag.num(l, p), bhv.ag.el(more, p))

def bhv.nat.of(m: Maybe<&2, Nat>) -> Nat:
  match m:
    case Some{n}:
      n
    case None{}:
      0n

# wrong when the first error is past line L (in the tests), else compile
def bhv.agda.after(+el: List<&2, U32>, +l: Nat) -> Bool:
  Bool.and(Bool.not(bhv.empty(el)), Nat.is_gt(bhv.nat.of(Nat.read(S.str(el))), l))

# The task specs (tasks.sh) -----------------------------------------------------
#
# A spec is awk's records: `@@#` comments, `@@ task NAME KIND` (awk fields 3
# and 4), `@@ user|context|type|pre|tests|ref` on a line of its own, any
# other `@@` line an unknown directive, the rest a line of the current
# section.  A task's files are written when the next task starts or the
# spec ends; every error is reported and the spec then fails.

type BhLn is Data:
  BhLn{k: Nat, l: List<&2, U32>}

type BhAct is Data:
  BhErr{msg: String}
  BhDir{path: String}
  BhPut{path: String, data: List<&2, U32>}

# the parse so far: the task (no name before the first), its kind, the
# current section, its lines (newest first), the names seen, whether an
# error was met, the tasks written and their names, the actions (newest first)
type BhP is Data:
  BhP{name: List<&2, U32>, kind: List<&2, U32>, cur: Nat, secs: List<&2, BhLn>, seen: List<&2, List<&2, U32>>, bad: Bool, n: Nat, done: List<&2, List<&2, U32>>, acts: List<&2, BhAct>}

# where a spec's files go: the harness, the language, the spec as named
type BhCx is Data:
  BhCx{q: String, lang: String, file: String}

def bhv.tab.sp(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      Bool.pick(U32, U32.is_eq(h, 9), 32, h) <> bhv.tab.sp(t)

def bhv.nonempty(xss: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xss:
    case Nil{}:
      Nil{}
    case +x <> more:
      +r = bhv.nonempty(more)
      Bool.pick(List<&2, List<&2, U32>>, bhv.empty(x), r, x <> r)

# awk's fields (runs of blanks separate them)
def bhv.fields(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  bhv.nonempty(S.split(bhv.tab.sp(xs), 32))

def bhv.nth(xss: List<&2, List<&2, U32>>, +i: Nat) -> List<&2, U32>:
  match xss i:
    case Nil{} _:
      Nil{}
    case x <> more 0n:
      x
    case x <> more 1n+k:
      bhv.nth(more, k)

# a section line's section: 1 user, 2 context, 3 type, 4 pre, 5 tests, 6 ref; 0 none
def bhv.sec.of(+l: List<&2, U32>) -> Nat:
  Bool.pick(Nat, S.eq(l, S.b("@@ user")), 1n, Bool.pick(Nat, S.eq(l, S.b("@@ context")), 2n,
  Bool.pick(Nat, S.eq(l, S.b("@@ type")), 3n, Bool.pick(Nat, S.eq(l, S.b("@@ pre")), 4n,
  Bool.pick(Nat, S.eq(l, S.b("@@ tests")), 5n, Bool.pick(Nat, S.eq(l, S.b("@@ ref")), 6n, 0n))))))

# a line: 0 a comment, 1 a task, 2 a section, 3 an unknown directive, 4 text
def bhv.p.class(+l: List<&2, U32>) -> Nat:
  Bool.pick(Nat, S.prefix(l, S.b("@@#")), 0n, Bool.pick(Nat, S.prefix(l, S.b("@@ task ")), 1n,
  Bool.pick(Nat, Nat.is_ne(bhv.sec.of(l), 0n), 2n, Bool.pick(Nat, S.prefix(l, S.b("@@")), 3n, 4n))))

def bhv.p.noname(+p: BhP) -> Bool:
  match p:
    case BhP{name, kind, cur, secs, seen, bad, n, done, acts}:
      bhv.empty(name)

# a section's lines in order, k its number
def bhv.p.lines(secs: List<&2, BhLn>, +k: Nat) -> List<&2, List<&2, U32>>:
  match secs:
    case Nil{}:
      Nil{}
    case BhLn{+j, l} <> more:
      +r = bhv.p.lines(more, k)
      Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(j, k), l <> r, r)

# trim(sec[k]): the lines, each with its newline, less the trailing newlines
def bhv.p.sec(+secs: List<&2, BhLn>, +k: Nat) -> List<&2, U32>:
  S.chomp(bhv.unlines(List.reverse(&2, List<&2, U32>, bhv.p.lines(secs, k))))

def bhv.p.has(secs: List<&2, BhLn>, +k: Nat) -> Bool:
  match secs:
    case Nil{}:
      False{}
    case BhLn{+j, l} <> more:
      Bool.or(Nat.is_eq(j, k), bhv.p.has(more, k))

def bhv.acts.err(b: Bool, +msg: String, acts: List<&2, BhAct>) -> List<&2, BhAct>:
  match b:
    case True{}:
      BhErr{msg} <> acts
    case False{}:
      acts

def bhv.p.prompt(+lang: List<&2, U32>, +kind: List<&2, U32>, +u: List<&2, U32>, +c: List<&2, U32>, +t: List<&2, U32>) -> List<&2, U32>:
  bhv.cat([S.b("## User\n\n"), u, S.b("\n\n"),
    Bool.pick(List<&2, U32>, bhv.empty(c), Nil{}, bhv.cat([S.b("## Context\n\n```"), lang, [10], c, S.b("\n```\n\n")])),
    S.b("## Type\n\n"), kind, S.b("\n```"), lang, [10], t, S.b("\n```\n\n## Term\n\n```"), lang, [10]])

# emit(): the task's files
def bhv.p.write(+x: BhCx, p: BhP) -> BhP:
  match x p:
    case BhCx{+q, +lang, file} BhP{+name, +kind, cur, +secs, seen, bad, n, done, acts}:
      +miss = Bool.or(Bool.not(bhv.p.has(secs, 3n)), Bool.not(bhv.p.has(secs, 1n)))
      +d = q ++ "/tasks/" ++ lang ++ "/" ++ S.str(name)
      +t = bhv.p.sec(secs, 3n)
      +out = {[BhPut{q ++ "/refs/" ++ lang ++ "/" ++ S.str(name), List.append(&2, U32, bhv.p.sec(secs, 6n), S.b("\n```\n"))},
        BhPut{d ++ "/prompt", bhv.p.prompt(S.b(lang), kind, bhv.p.sec(secs, 1n), bhv.p.sec(secs, 2n), t)},
        BhPut{d ++ "/kind", List.append(&2, U32, kind, [10])},
        BhPut{d ++ "/tests", List.append(&2, U32, bhv.p.sec(secs, 5n), [10])},
        BhPut{d ++ "/pre", bhv.p.sec(secs, 4n)},
        BhPut{d ++ "/sig", List.append(&2, U32, t, [10])},
        BhDir{d}] : List<&2, BhAct>}
      BhP{Nil{}, kind, cur, Nil{}, seen, Bool.or(bad, miss), 1n+n, name <> done,
        List.append(&2, BhAct, out, bhv.acts.err(miss, "behaviour tasks: " ++ lang ++ "/" ++ S.str(name) ++ ": no user or type", acts))}

def bhv.p.emit.if(none: Bool, +x: BhCx, p: BhP) -> BhP:
  match none:
    case True{}:
      p
    case False{}:
      bhv.p.write(x, p)

def bhv.p.emit(+x: BhCx, +p: BhP) -> BhP:
  bhv.p.emit.if(bhv.p.noname(p), x, p)

# `@@ task NAME KIND`
def bhv.p.task(+fs: List<&2, List<&2, U32>>, p: BhP) -> BhP:
  match p:
    case BhP{name0, kind0, cur, secs, +seen, bad, n, done, acts}:
      +name = bhv.nth(fs, 2n)
      +kind = bhv.nth(fs, 3n)
      +kbad = Bool.not(Bool.or(S.eq(kind, S.b("type")), S.eq(kind, S.b("proposition"))))
      +twice = bhv.elem(name, seen)
      BhP{name, kind, 0n, secs, name <> seen, Bool.or(bad, Bool.or(kbad, twice)), n, done,
        bhv.acts.err(twice, "behaviour tasks: " ++ S.str(name) ++ " twice",
          bhv.acts.err(kbad, "behaviour tasks: " ++ S.str(name) ++ ": kind " ++ S.str(kind), acts))}

def bhv.p.cur(+k: Nat, p: BhP) -> BhP:
  match p:
    case BhP{name, kind, cur, secs, seen, bad, n, done, acts}:
      BhP{name, kind, k, secs, seen, bad, n, done, acts}

def bhv.p.err(+msg: String, p: BhP) -> BhP:
  match p:
    case BhP{name, kind, cur, secs, seen, bad, n, done, acts}:
      BhP{name, kind, cur, secs, seen, True{}, n, done, BhErr{msg} <> acts}

def bhv.p.add.if(none: Bool, +l: List<&2, U32>, p: BhP) -> BhP:
  match none p:
    case True{} same:
      same
    case False{} BhP{name, kind, +cur, secs, seen, bad, n, done, acts}:
      BhP{name, kind, cur, BhLn{cur, l} <> secs, seen, bad, n, done, acts}

def bhv.cx.file(+x: BhCx) -> String:
  match x:
    case BhCx{q, lang, file}:
      file

def bhv.p.do(c: Nat, +x: BhCx, +fnr: Nat, +l: List<&2, U32>, +p: BhP) -> BhP:
  match c:
    case 0n:
      p
    case 1n:
      bhv.p.task(bhv.fields(l), bhv.p.emit(x, p))
    case 2n:
      bhv.p.cur(bhv.sec.of(l), p)
    case 3n:
      bhv.p.err("behaviour tasks: " ++ bhv.cx.file(x) ++ ":" ++ Nat.show(fnr) ++ ": unknown directive " ++ S.str(l), p)
    case _:
      bhv.p.add.if(bhv.p.noname(p), l, p)

def bhv.p.go(ls: List<&2, List<&2, U32>>, +x: BhCx, +fnr: Nat, p: BhP) -> BhP:
  match ls:
    case Nil{}:
      p
    case +l <> more:
      bhv.p.go(more, x, 1n+fnr, bhv.p.do(bhv.p.class(l), x, fnr, l, p))

def bhv.parse(+x: BhCx, +spec: List<&2, U32>) -> BhP:
  bhv.p.emit(x, bhv.p.go(S.split.lines(spec), x, 1n, BhP{Nil{}, Nil{}, 0n, Nil{}, Nil{}, False{}, 0n, Nil{}, Nil{}}))

def bhv.act.run(a: BhAct) -> IO(Unit):
  match a:
    case BhErr{msg}:
      IO.print_err(msg)
    case BhDir{path}:
      S.mkdir(path)
    case BhPut{path, data}:
      S.write(path, data)

def bhv.acts.run(acts: List<&2, BhAct>) -> IO(Unit):
  match acts:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case a <> more:
      do IO<Unit>:
        bhv.act.run(a)
        bhv.acts.run(more)

# --check: a file the spec makes, against the file there (1 when it differs)
def bhv.put.same(same: Bool, +path: String) -> IO(Nat):
  match same:
    case True{}:
      IO.pure(Nat, 0n)
    case False{}:
      do IO<Nat>:
        IO.print_err("behaviour tasks --check: " ++ path ++ ": differs from the spec")
        return 1n

def bhv.put.cmp(+path: String, +data: List<&2, U32>, m: Maybe<&2, List<&2, U32>>) -> IO(Nat):
  match m:
    case None{}:
      do IO<Nat>:
        IO.print_err("behaviour tasks --check: " ++ path ++ ": missing")
        return 1n
    case Some{+xs}:
      bhv.put.same(S.eq(xs, data), path)

def bhv.act.check(a: BhAct) -> IO(Nat):
  match a:
    case BhErr{msg}:
      do IO<Nat>:
        IO.print_err(msg)
        return 1n
    case BhDir{path}:
      IO.pure(Nat, 0n)
    case BhPut{+path, +data}:
      do IO<Nat>:
        m : Maybe<&2, List<&2, U32>> <- S.slurp(path)
        bhv.put.cmp(path, data, m)

def bhv.acts.check(acts: List<&2, BhAct>, +bad: Nat) -> IO(Nat):
  match acts:
    case Nil{}:
      IO.pure(Nat, bad)
    case a <> more:
      do IO<Nat>:
        +k : Nat <- bhv.act.check(a)
        bhv.acts.check(more, Nat.add(bad, k))

# entries of a directory not among the names the spec made
def bhv.stale.one(known: Bool, +e: List<&2, U32>, +dir: String) -> IO(Nat):
  match known:
    case True{}:
      IO.pure(Nat, 0n)
    case False{}:
      do IO<Nat>:
        IO.print_err("behaviour tasks --check: " ++ dir ++ "/" ++ S.str(e) ++ ": not in the spec")
        return 1n

def bhv.stale(es: List<&2, List<&2, U32>>, +names: List<&2, List<&2, U32>>, +dir: String, +bad: Nat) -> IO(Nat):
  match es:
    case Nil{}:
      IO.pure(Nat, bad)
    case +e <> more:
      do IO<Nat>:
        +b : Nat <- bhv.stale.one(bhv.elem(e, names), e, dir)
        bhv.stale(more, names, dir, Nat.add(bad, b))

# A directory's entries (ls: no dot files), bytewise; with dirs, only the
# directories (and links to them: a shell glob's */)
def bhv.undot(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      +r = bhv.undot(more)
      Bool.pick(List<&2, List<&2, U32>>, Bool.or(bhv.empty(l), S.head.is(l, 46)), r, l <> r)

def bhv.ls.of(+o: S.Out) -> List<&2, List<&2, U32>>:
  Bool.pick(List<&2, List<&2, U32>>, U32.is_eq(S.Out.status(o), 0), bhv.sort(bhv.undot(S.split.lines(S.Out.text(o)))), Nil{})

def bhv.ls(+dir: String, dirs: Bool) -> IO(List<&2, List<&2, U32>>):
  match dirs:
    case False{}:
      do IO<List<&2, List<&2, U32>>>:
        +o : S.Out <- S.run.quiet(".", [], 600, "find", [dir, "-mindepth", "1", "-maxdepth", "1", "-printf", "%f\n"], Nil{})
        return bhv.ls.of(o)
    case True{}:
      do IO<List<&2, List<&2, U32>>>:
        +o : S.Out <- S.run.quiet(".", [], 600, "find", [dir, "-mindepth", "1", "-maxdepth", "1", "-xtype", "d", "-printf", "%f\n"], Nil{})
        return bhv.ls.of(o)

def bhv.test(+flag: String, +path: String) -> IO(Bool):
  do IO<Bool>:
    +o : S.Out <- S.run.quiet(".", [], 60, "test", [flag, path], Nil{})
    return U32.is_eq(S.Out.status(o), 0)

def bhv.need(ok: Bool, +code: U32, +msg: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, code, msg)

def bhv.say(quiet: Bool, +s: String) -> IO(Unit):
  match quiet:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.print(s)

def bhv.langs.or(ls: List<&2, String>) -> List<&2, String>:
  match ls:
    case Nil{}:
      ["haskell", "lean", "agda"]
    case l <> more:
      l <> more

# the harness's directory and the repository root
def bhv.root() -> IO(String):
  S.realpath(".")

def bhv.dir(+ft: String) -> IO(String):
  do IO<String>:
    +v : String <- S.env("BEHAVIOUR_DIR", "")
    S.realpath(Bool.pick(String, String.is_empty(v), ft ++ "/tools/corpus-v2/behaviour", v))

def bhv.tasks.stop(check: Bool, sb: Bool, +lang: String) -> IO(Unit):
  match check sb:
    case False{} True{}:
      IO.die(Unit, 1, "behaviour tasks: spec/" ++ lang ++ ".tasks has errors")
    case _ _:
      IO.pure(Unit, Unit{})

# tasks: one language's spec; the answer is the number of mismatches (check)
def bhv.tasks.fin(+check: Bool, +lang: String, +p: BhP, +bad: Nat) -> IO(Nat):
  match p:
    case BhP{name, kind, cur, secs, seen, sb, n, done, acts}:
      do IO<Nat>:
        IO.print(lang ++ ": " ++ Nat.show(n) ++ " tasks")
        bhv.tasks.stop(check, sb, lang)
        return bad

def bhv.p.acts(+p: BhP) -> List<&2, BhAct>:
  match p:
    case BhP{name, kind, cur, secs, seen, bad, n, done, acts}:
      List.reverse(&2, BhAct, acts)

def bhv.p.done(+p: BhP) -> List<&2, List<&2, U32>>:
  match p:
    case BhP{name, kind, cur, secs, seen, bad, n, done, acts}:
      done

def bhv.tasks.mode(check: Bool, +q: String, +lang: String, +p: BhP) -> IO(Nat):
  match check:
    case False{}:
      do IO<Nat>:
        bhv.acts.run(bhv.p.acts(p))
        bhv.tasks.fin(False{}, lang, p, 0n)
    case True{}:
      do IO<Nat>:
        +b0 : Nat <- bhv.acts.check(bhv.p.acts(p), 0n)
        ts : List<&2, List<&2, U32>> <- bhv.ls(q ++ "/tasks/" ++ lang, False{})
        +b1 : Nat <- bhv.stale(ts, bhv.p.done(p), q ++ "/tasks/" ++ lang, b0)
        rs : List<&2, List<&2, U32>> <- bhv.ls(q ++ "/refs/" ++ lang, False{})
        +b2 : Nat <- bhv.stale(rs, bhv.p.done(p), q ++ "/refs/" ++ lang, b1)
        bhv.tasks.fin(True{}, lang, p, b2)

def bhv.tasks.dirs(check: Bool, +q: String, +lang: String) -> IO(Unit):
  match check:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      do IO<Unit>:
        S.mkdir(q ++ "/tasks/" ++ lang)
        S.mkdir(q ++ "/refs/" ++ lang)

def bhv.tasks.spec(+check: Bool, +q: String, +lang: String, +spec: String, m: Maybe<&2, List<&2, U32>>) -> IO(Nat):
  match m:
    case None{}:
      IO.die(Nat, 2, "behaviour tasks: no " ++ spec)
    case Some{+xs}:
      do IO<Nat>:
        bhv.tasks.dirs(check, q, lang)
        bhv.tasks.mode(check, q, lang, bhv.parse(BhCx{q, lang, spec}, xs))

def bhv.tasks.go(ls: List<&2, String>, +check: Bool, +q: String, +bad: Nat) -> IO(Nat):
  match ls:
    case Nil{}:
      IO.pure(Nat, bad)
    case +lang <> more:
      do IO<Nat>:
        +spec : String = q ++ "/spec/" ++ lang ++ ".tasks"
        m : Maybe<&2, List<&2, U32>> <- S.slurp(spec)
        +b : Nat <- bhv.tasks.spec(check, q, lang, spec, m)
        bhv.tasks.go(more, check, q, Nat.add(bad, b))

def bhv.tasks.args(xs: List<&2, String>) -> Bool & List<&2, String>:
  match xs:
    case +x <> +more:
      Bool.pick(Bool & List<&2, String>, String.eq(x, "--check"), (True{}, more), (False{}, x <> more))
    case Nil{}:
      (False{}, Nil{})

def bhv.tasks.check(+bad: Nat) -> IO(Unit):
  bhv.need(Nat.is_eq(bad, 0n), 1, "behaviour tasks --check: " ++ Nat.show(bad) ++ " file(s) not as the spec makes them")

def bhv.tasks.run(a: Bool & List<&2, String>) -> IO(Unit):
  (check, ls) = a
  do IO<Unit>:
    +ft : String <- bhv.root()
    +q : String <- bhv.dir(ft)
    +bad : Nat <- bhv.tasks.go(bhv.langs.or(ls), check, q, 0n)
    bhv.tasks.check(bad)

def bhv.tasks(xs: List<String>) -> IO(Unit):
  bhv.tasks.run(bhv.tasks.args(bhv.args(xs)))

# Running and checking (run.sh) --------------------------------------------------

# a run's settings, and the language's checker: tool (GHC, LEAN_BIN, AGDA),
# env (Lean's), secs (the checker's timeout), libs (AGDA_LIBS)
type BhCf is Data:
  BhCf{q: String, ft: String, tag: String, ckpt: String, gen: Bool, ref: Bool, reuse: Bool, keep: Bool, tokens: String, ana: String, threads: String, tool: String, env: List<&2, String>, secs: Nat, libs: String}

def bhv.cf.q(+c: BhCf) -> String:
  match c:
    case BhCf{q, ft, tag, ckpt, gen, ref, reuse, keep, tokens, ana, threads, tool, env, secs, libs}:
      q

def bhv.cf.ft(+c: BhCf) -> String:
  match c:
    case BhCf{q, ft, tag, ckpt, gen, ref, reuse, keep, tokens, ana, threads, tool, env, secs, libs}:
      ft

def bhv.cf.tag(+c: BhCf) -> String:
  match c:
    case BhCf{q, ft, tag, ckpt, gen, ref, reuse, keep, tokens, ana, threads, tool, env, secs, libs}:
      tag

def bhv.cf.ckpt(+c: BhCf) -> String:
  match c:
    case BhCf{q, ft, tag, ckpt, gen, ref, reuse, keep, tokens, ana, threads, tool, env, secs, libs}:
      ckpt

def bhv.cf.gen(+c: BhCf) -> Bool:
  match c:
    case BhCf{q, ft, tag, ckpt, gen, ref, reuse, keep, tokens, ana, threads, tool, env, secs, libs}:
      gen

def bhv.cf.ref(+c: BhCf) -> Bool:
  match c:
    case BhCf{q, ft, tag, ckpt, gen, ref, reuse, keep, tokens, ana, threads, tool, env, secs, libs}:
      ref

def bhv.cf.reuse(+c: BhCf) -> Bool:
  match c:
    case BhCf{q, ft, tag, ckpt, gen, ref, reuse, keep, tokens, ana, threads, tool, env, secs, libs}:
      reuse

def bhv.cf.keep(+c: BhCf) -> Bool:
  match c:
    case BhCf{q, ft, tag, ckpt, gen, ref, reuse, keep, tokens, ana, threads, tool, env, secs, libs}:
      keep

def bhv.cf.tool(+c: BhCf) -> String:
  match c:
    case BhCf{q, ft, tag, ckpt, gen, ref, reuse, keep, tokens, ana, threads, tool, env, secs, libs}:
      tool

def bhv.cf.env(+c: BhCf) -> List<&2, String>:
  match c:
    case BhCf{q, ft, tag, ckpt, gen, ref, reuse, keep, tokens, ana, threads, tool, env, secs, libs}:
      env

def bhv.cf.secs(+c: BhCf) -> U32:
  match c:
    case BhCf{q, ft, tag, ckpt, gen, ref, reuse, keep, tokens, ana, threads, tool, env, secs, libs}:
      U32.from_nat(secs)

def bhv.cf.libs(+c: BhCf) -> String:
  match c:
    case BhCf{q, ft, tag, ckpt, gen, ref, reuse, keep, tokens, ana, threads, tool, env, secs, libs}:
      libs

# ana's command line for a prompt file
def bhv.cf.ana(+c: BhCf, +prompt: String) -> String & List<String>:
  match c:
    case BhCf{q, ft, tag, ckpt, gen, ref, reuse, keep, tokens, ana, threads, tool, env, secs, libs}:
      (ana, ["--checkpoint", ckpt, "--tokens", tokens, "--threads", threads, "--prompt-file", prompt])

def bhv.cf.with(+c: BhCf, +tool: String, +env: List<&2, String>, +secs: Nat, +libs: String) -> BhCf:
  match c:
    case BhCf{q, ft, tag, ckpt, gen, ref, reuse, keep, tokens, ana, threads, tool0, env0, secs0, libs0}:
      BhCf{q, ft, tag, ckpt, gen, ref, reuse, keep, tokens, ana, threads, tool, env, secs, libs}

# ${NAME:-d}
def bhv.env(+name: String, +d: String) -> IO(String):
  do IO<String>:
    +v : String <- S.env(name, "")
    return Bool.pick(String, String.is_empty(v), d, v)

# [ -n "${NAME:-}" ]
def bhv.set(+name: String) -> IO(Bool):
  do IO<Bool>:
    v : String <- S.env(name, "")
    return Bool.not(String.is_empty(v))

# A process with its stdout and its stderr each into a file, byte for byte
def bhv.run.to(+dir: String, env: List<String>, +prog: String, args: List<String>, +out: String, +err: String) -> IO(U32):
  do IO<U32>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
      Process.run("sh", List.append(&1, String, ["-c", "cd \"$1\" && o=$2 && e=$3 && shift 3 && exec \"$@\" > \"$o\" 2> \"$e\"", "sh", dir, out, err], S.argv.env(env, prog <> args)),
        "", S.cap.bytes(), 4294967295)
    +o : S.Out <- S.run.got(r)
    return S.Out.status(o)

# gen: the output of the prompt (prompt ++ answer), in R/NAME.out
def bhv.gen.fin(ok: Bool, +lang: String, +n: String, +r: String) -> IO(Unit):
  match ok:
    case True{}:
      S.mv(r ++ "/" ++ n ++ ".out.tmp", r ++ "/" ++ n ++ ".out")
    case False{}:
      do IO<Unit>:
        IO.print_err("behaviour run: ana failed on " ++ lang ++ "/" ++ n ++ " (see " ++ r ++ "/" ++ n ++ ".err)")
        S.rm(r ++ "/" ++ n ++ ".out.tmp")

def bhv.gen.ana(a: String & List<String>, +ft: String, +lang: String, +n: String, +r: String) -> IO(Unit):
  (prog, args) = a
  do IO<Unit>:
    +st : U32 <- bhv.run.to(ft, ["TEMPERATURE=0"], prog, args, r ++ "/" ++ n ++ ".out.tmp", r ++ "/" ++ n ++ ".err")
    bhv.gen.fin(U32.is_eq(st, 0), lang, n, r)

def bhv.gen.reuse(skip: Bool, +c: BhCf, +lang: String, +n: String, +r: String) -> IO(Unit):
  match skip:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      bhv.gen.ana(bhv.cf.ana(c, bhv.cf.q(c) ++ "/tasks/" ++ lang ++ "/" ++ n ++ "/prompt"), bhv.cf.ft(c), lang, n, r)

def bhv.gen.mode(ref: Bool, +c: BhCf, +lang: String, +n: String, +r: String) -> IO(Unit):
  match ref:
    case True{}:
      do IO<Unit>:
        p : List<&2, U32> <- S.read(bhv.cf.q(c) ++ "/tasks/" ++ lang ++ "/" ++ n ++ "/prompt")
        f : List<&2, U32> <- S.read(bhv.cf.q(c) ++ "/refs/" ++ lang ++ "/" ++ n)
        S.write(r ++ "/" ++ n ++ ".out", List.append(&2, U32, p, f))
    case False{}:
      do IO<Unit>:
        +size : Nat <- S.size(r ++ "/" ++ n ++ ".out")
        bhv.gen.reuse(Bool.and(bhv.cf.reuse(c), Nat.is_gt(size, 0n)), c, lang, n, r)

def bhv.gen(+c: BhCf, +lang: String, +n: String, +r: String) -> IO(Unit):
  bhv.gen.mode(bhv.cf.ref(c), c, lang, n, r)

# extract: the answer, R/NAME.term (the generated text up to the first
# closing fence line), or the verdict without one
type BhE is Data:
  BhE{ok: Bool, v: List<&2, U32>, term: List<&2, U32>}

type BhT is Data:
  BhT{closed: Bool, term: List<&2, U32>}

# sed "1{/^=== ana: .* ===$/d}": ana --checkpoint's header line
def bhv.is.header.r(p: Bool, +r: List<&2, U32>) -> Bool:
  match p:
    case True{}:
      Bool.and(S.suffix(r, S.b(" ===")), bhv.valid(List.take(&2, U32, r, Nat.sub(S.len(r), 4n))))
    case False{}:
      False{}

def bhv.is.header(+l: List<&2, U32>) -> Bool:
  bhv.is.header.r(S.prefix(l, S.b("=== ana: ")), List.drop(&2, U32, l, 9n))

def bhv.unheader.if(h: Bool, +xs: List<&2, U32>) -> List<&2, U32>:
  match h:
    case True{}:
      bhv.after(xs, 10)
    case False{}:
      xs

def bhv.unheader(+xs: List<&2, U32>) -> List<&2, U32>:
  bhv.unheader.if(bhv.is.header(S.lines.first(xs)), xs)

def bhv.fence.is(ls: List<&2, List<&2, U32>>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case +l <> more:
      S.prefix(l, S.b("```"))

def bhv.fence.put(l: List<&2, U32>, t: BhT) -> BhT:
  match t:
    case BhT{c, term}:
      BhT{c, List.append(&2, U32, l, 10 <> term)}

# awk 'BEGIN{c=0} /^```/{c=1; exit} {print} END{exit c?0:3}'
def bhv.fence.go(ls: List<&2, List<&2, U32>>, at: Bool) -> BhT:
  match ls at:
    case Nil{} _:
      BhT{False{}, Nil{}}
    case _ True{}:
      BhT{True{}, Nil{}}
    case l <> +more False{}:
      bhv.fence.put(l, bhv.fence.go(more, bhv.fence.is(more)))

def bhv.fence(+gen: List<&2, U32>) -> BhT:
  +ls = S.split.lines(gen)
  bhv.fence.go(ls, bhv.fence.is(ls))

def bhv.noprompt() -> BhE:
  BhE{False{}, S.b("noprompt"), Nil{}}

def bhv.extract.term(t: BhT, +r: String, +n: String) -> IO(BhE):
  match t:
    case BhT{+closed, +term}:
      do IO<BhE>:
        S.write(r ++ "/" ++ n ++ ".term", term)
        return BhE{closed, Bool.pick(List<&2, U32>, closed, Nil{}, S.b("unclosed")), term}

def bhv.extract.body(ok: Bool, +gen: List<&2, U32>, +r: String, +n: String) -> IO(BhE):
  match ok:
    case False{}:
      IO.pure(BhE, bhv.noprompt())
    case True{}:
      do IO<BhE>:
        S.write(r ++ "/" ++ n ++ ".gen", gen)
        bhv.extract.term(bhv.fence(gen), r, n)

def bhv.extract.got(+q: String, +lang: String, +n: String, +r: String, m: Maybe<&2, List<&2, U32>>) -> IO(BhE):
  match m:
    case None{}:
      IO.pure(BhE, bhv.noprompt())
    case Some{+out}:
      do IO<BhE>:
        +body : List<&2, U32> = bhv.unheader(out)
        S.write(r ++ "/" ++ n ++ ".body", body)
        +p : List<&2, U32> <- S.read(q ++ "/tasks/" ++ lang ++ "/" ++ n ++ "/prompt")
        bhv.extract.body(S.prefix(body, p), List.drop(&2, U32, body, S.len(p)), r, n)

def bhv.extract(+q: String, +lang: String, +n: String, +r: String) -> IO(BhE):
  do IO<BhE>:
    m : Maybe<&2, List<&2, U32>> <- S.slurp(r ++ "/" ++ n ++ ".out")
    bhv.extract.got(q, lang, n, r, m)

def bhv.unbuild(keep: Bool, +b: String) -> IO(Unit):
  match keep:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      S.rm(b)

# Haskell: Main.hs is the imports, the pre, the sig, the answer less any line
# equal to the sig, `tests :: [Bool]`, a main printing PASS or FAIL; ghc -O0
# (120 s), run (10 s)
def bhv.hs.file(+pre: List<&2, U32>, +sig: List<&2, U32>, +term: List<&2, U32>, +tests: List<&2, U32>) -> List<&2, U32>:
  bhv.cat([S.b("module Main where\n"),
    S.b("import Data.List (sort, sortBy, sortOn, group, groupBy, nub, transpose, foldl', intercalate, isPrefixOf, maximumBy, minimumBy, tails, inits, elemIndex, partition, unfoldr)\n"),
    S.b("import Data.Char (toUpper, toLower, isDigit, isSpace, isLower, isUpper, isAlpha, ord, chr, digitToInt)\n"),
    S.b("import Data.Maybe (mapMaybe, fromMaybe, catMaybes, listToMaybe)\n"),
    S.b("import Data.Ord (comparing)\n"),
    S.b("import qualified Data.Map as M\n"),
    S.b("import System.Exit\n"),
    pre, [10], sig, [10], bhv.grepv(term, sig), [10],
    S.b("tests :: [Bool]\n"),
    S.b("tests = "), tests, [10],
    S.b("main :: IO ()\n"),
    S.b("main = if and tests then putStrLn \"PASS\" else putStrLn (\"FAIL \" ++ show [i | (i, False) <- zip [1 :: Int ..] tests]) >> exitWith (ExitFailure 1)\n")])

def bhv.hs.v(ok: Bool, fail: Bool) -> List<&2, U32>:
  match ok fail:
    case True{} _:
      S.b("pass")
    case False{} True{}:
      S.b("wrong")
    case False{} False{}:
      S.b("crash")

def bhv.hs.run(ok: Bool, +b: String, +r: String, +n: String) -> IO(List<&2, U32>):
  match ok:
    case False{}:
      IO.pure(List<&2, U32>, S.b("compile"))
    case True{}:
      do IO<List<&2, U32>>:
        +st : U32 <- S.run.log(".", [], 10, b ++ "/t", [], r ++ "/" ++ n ++ ".run")
        out : List<&2, U32> <- S.read(r ++ "/" ++ n ++ ".run")
        return bhv.hs.v(U32.is_eq(st, 0), bhv.any.prefix(S.split.lines(out), S.b("FAIL")))

def bhv.hs(+c: BhCf, +n: String, +r: String, e: BhE) -> IO(List<&2, U32>):
  match e:
    case BhE{False{}, v, t}:
      IO.pure(List<&2, U32>, v)
    case BhE{True{}, v, +term}:
      do IO<List<&2, U32>>:
        +d : String = bhv.cf.q(c) ++ "/tasks/haskell/" ++ n
        sig0 : List<&2, U32> <- S.read(d ++ "/sig")
        pre : List<&2, U32> <- S.read(d ++ "/pre")
        tests : List<&2, U32> <- S.read(d ++ "/tests")
        S.write(r ++ "/" ++ n ++ ".hs", bhv.hs.file(pre, bhv.subst(sig0), term, bhv.subst(tests)))
        +b : String = r ++ "/build/" ++ n
        S.mkdir(b)
        +st : U32 <- S.run.log(".", [], 120, bhv.cf.tool(c), ["-O0", "-outputdir", b, "-o", b ++ "/t", r ++ "/" ++ n ++ ".hs"], r ++ "/" ++ n ++ ".ghc")
        +v2 : List<&2, U32> <- bhv.hs.run(U32.is_eq(st, 0), b, r, n)
        bhv.unbuild(bhv.cf.keep(c), b)
        return v2

# Lean: NAME.lean is `import Mathlib`, the pre, the Type joined to the
# answer by ` :=` (unless the answer opens with `:=`), `section
# BehaviourChecks`, the tests, `#print axioms NAME`; Check.lean elaborates
# the first L lines, then the tests only when they had no error
def bhv.lean.head(+pre: List<&2, U32>, +sig: List<&2, U32>, +term: List<&2, U32>) -> List<&2, U32>:
  bhv.cat([S.b("import Mathlib\n\n"), Bool.pick(List<&2, U32>, bhv.empty(pre), Nil{}, List.append(&2, U32, pre, S.b("\n\n"))),
    sig, Bool.pick(List<&2, U32>, S.prefix(term, S.b(":=")), [10], S.b(" :=\n")), term, S.b("\nsection BehaviourChecks\n")])

# the checker's status and log: 0 timeout, 1 refused (sorry), 2 elaborated
# (then the axioms), 3 compile, 4 wrong, 5 died
def bhv.lean.code(+st: U32, +sorry: Bool) -> Nat:
  Bool.pick(Nat, U32.is_eq(st, 124), 0n, Bool.pick(Nat, sorry, 1n, Bool.pick(Nat, U32.is_eq(st, 0), 2n,
    Bool.pick(Nat, U32.is_eq(st, 1), 3n, Bool.pick(Nat, U32.is_eq(st, 2), 4n, 5n)))))

def bhv.lean.v(k: Nat, +log: List<&2, U32>, +n: String) -> List<&2, U32>:
  match k:
    case 0n:
      S.b("timeout")
    case 1n:
      S.b("refused")
    case 2n:
      Bool.pick(List<&2, U32>, bhv.ax.refused(log, n), S.b("refused"), S.b("pass"))
    case 3n:
      S.b("compile")
    case 4n:
      S.b("wrong")
    case _:
      Bool.pick(List<&2, U32>, bhv.lines.any.eq(S.split.lines(log), S.b("-- behaviour: tests")), S.b("crash"), S.b("compile"))

def bhv.lean.go(k: Nat, +c: BhCf, +n: String, +r: String, +term: List<&2, U32>) -> IO(List<&2, U32>):
  match k:
    case 0n:
      IO.pure(List<&2, U32>, S.b("refused"))
    case 1n:
      IO.pure(List<&2, U32>, S.b("compile"))
    case _:
      do IO<List<&2, U32>>:
        +d : String = bhv.cf.q(c) ++ "/tasks/lean/" ++ n
        sig0 : List<&2, U32> <- S.read(d ++ "/sig")
        pre : List<&2, U32> <- S.read(d ++ "/pre")
        tests : List<&2, U32> <- S.read(d ++ "/tests")
        +h : List<&2, U32> = bhv.lean.head(pre, bhv.subst(sig0), term)
        S.write(r ++ "/" ++ n ++ ".lean", bhv.cat([h, tests, S.b("#print axioms " ++ n ++ "\nend BehaviourChecks\n")]))
        +bin : String = bhv.cf.tool(c)
        +st : U32 <- S.run.log(r, bhv.strs(bhv.cf.env(c)), bhv.cf.secs(c), bin ++ "/lean", ["--run", bhv.cf.q(c) ++ "/Check.lean", n ++ ".lean", Nat.show(bhv.nl.count(h, 0n))], r ++ "/" ++ n ++ ".log")
        +log : List<&2, U32> <- S.read(r ++ "/" ++ n ++ ".log")
        return bhv.lean.v(bhv.lean.code(st, bhv.dus(log)), log, n)

# refused (sorry, admit, ...), compile (an empty answer), else checked
def bhv.lean.pre(+term: List<&2, U32>) -> Nat:
  Bool.pick(Nat, bhv.lean.gives.up(term), 0n, Bool.pick(Nat, bhv.ink(bhv.u8(term)), 2n, 1n))

def bhv.lean(+c: BhCf, +n: String, +r: String, e: BhE) -> IO(List<&2, U32>):
  match e:
    case BhE{False{}, v, t}:
      IO.pure(List<&2, U32>, v)
    case BhE{True{}, v, +term}:
      bhv.lean.go(bhv.lean.pre(term), c, n, r, term)

# Agda: Task.agda is --safe, the module header, the imports, the pre, the
# Type, the answer less any line equal to the Type, a separating import
# (L lines so far), then the tests
def bhv.agda.head(+pre: List<&2, U32>, +sig: List<&2, U32>, +term: List<&2, U32>) -> List<&2, U32>:
  bhv.cat([S.b("{-# OPTIONS --safe #-}\nmodule Task where\n\nopen import Data.Nat\nopen import Data.List\n"),
    S.b("open import Data.Bool using (Bool; true; false; not; _∧_; _∨_; if_then_else_; T)\n"),
    S.b("open import Data.Maybe using (Maybe; just; nothing)\n"),
    S.b("open import Data.Product using (_×_; _,_; proj₁; proj₂)\n"),
    S.b("open import Relation.Binary.PropositionalEquality using (_≡_; refl; cong; cong₂; sym; trans; subst)\n\n"),
    Bool.pick(List<&2, U32>, bhv.empty(pre), Nil{}, List.append(&2, U32, pre, S.b("\n\n"))),
    sig, [10], bhv.grepv(term, sig), [10], S.b("open import Agda.Builtin.Unit using ()\n")])

def bhv.agda.v(+st: U32, +log: List<&2, U32>, +l: Nat) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, U32.is_eq(st, 0), S.b("pass"), Bool.pick(List<&2, U32>, U32.is_eq(st, 124), S.b("timeout"),
    Bool.pick(List<&2, U32>, bhv.agda.after(bhv.ag.el(bhv.shown(log), S.b("Task.agda:")), l), S.b("wrong"), S.b("compile"))))

def bhv.agda.go(up: Bool, +c: BhCf, +n: String, +r: String, +term: List<&2, U32>) -> IO(List<&2, U32>):
  match up:
    case True{}:
      IO.pure(List<&2, U32>, S.b("refused"))
    case False{}:
      do IO<List<&2, U32>>:
        +d : String = bhv.cf.q(c) ++ "/tasks/agda/" ++ n
        sig0 : List<&2, U32> <- S.read(d ++ "/sig")
        pre : List<&2, U32> <- S.read(d ++ "/pre")
        tests : List<&2, U32> <- S.read(d ++ "/tests")
        +b : String = r ++ "/build/" ++ n
        S.rm(b)
        S.mkdir(b)
        +h : List<&2, U32> = bhv.agda.head(pre, bhv.subst(sig0), term)
        +f : List<&2, U32> = bhv.cat([h, [10], tests])
        S.write(r ++ "/" ++ n ++ ".agda", f)
        S.write(b ++ "/Task.agda", f)
        +st : U32 <- S.run.log(b, [], bhv.cf.secs(c), bhv.cf.tool(c), ["--library-file=" ++ bhv.cf.libs(c), "-l", "standard-library-2.3", "-i", ".", "Task.agda"], r ++ "/" ++ n ++ ".log")
        bhv.unbuild(bhv.cf.keep(c), b)
        +log : List<&2, U32> <- S.read(r ++ "/" ++ n ++ ".log")
        return bhv.agda.v(st, log, bhv.nl.count(h, 0n))

def bhv.agda(+c: BhCf, +n: String, +r: String, e: BhE) -> IO(List<&2, U32>):
  match e:
    case BhE{False{}, v, t}:
      IO.pure(List<&2, U32>, v)
    case BhE{True{}, v, +term}:
      bhv.agda.go(bhv.agda.gives.up(term), c, n, r, term)

# a task's verdict line: NAME TAB VERDICT
def bhv.check.lang(k: Nat, +c: BhCf, +n: String, +r: String, e: BhE) -> IO(List<&2, U32>):
  match k:
    case 0n:
      bhv.hs(c, n, r, e)
    case 1n:
      bhv.lean(c, n, r, e)
    case _:
      bhv.agda(c, n, r, e)

def bhv.check(+c: BhCf, +lang: String, +k: Nat, +n: String, +r: String) -> IO(List<&2, U32>):
  do IO<List<&2, U32>>:
    e : BhE <- bhv.extract(bhv.cf.q(c), lang, n, r)
    v : List<&2, U32> <- bhv.check.lang(k, c, n, r, e)
    return bhv.cat([S.b(n), [9], v])

# The jobs, PROCS at a time: forked workers take the next task from a channel
# (the work is the processes they run); a check answers its verdict line
type BhJob is Data:
  BhJob{c: BhCf, lang: String, k: Nat, n: String, r: String, gen: Bool}

def bhv.job(j: BhJob) -> IO(List<&2, U32>):
  match j:
    case BhJob{c, lang, k, n, r, True{}}:
      do IO<List<&2, U32>>:
        bhv.gen(c, lang, n, r)
        return Nil{}
    case BhJob{c, lang, k, n, r, False{}}:
      bhv.check(c, lang, k, n, r)

type BhW is Data:
  BhW{more: Bool, acc: List<&2, List<&2, U32>>}

def bhv.wk.got(m: Maybe<&1, BhJob>, acc: List<&2, List<&2, U32>>) -> IO(BhW):
  match m:
    case None{}:
      IO.pure(BhW, BhW{False{}, acc})
    case Some{j}:
      do IO<BhW>:
        v : List<&2, U32> <- bhv.job(j)
        return BhW{True{}, v <> acc}

def bhv.wk.step(+jobs: Chan(BhJob), acc: List<&2, List<&2, U32>>) -> IO(BhW):
  do IO<BhW>:
    m : Maybe<&1, BhJob> <- Chan.recv(BhJob, jobs)
    bhv.wk.got(m, acc)

def bhv.wk.go(fuel: Nat, +jobs: Chan(BhJob), w: BhW) -> IO(List<&2, List<&2, U32>>):
  match fuel w:
    case 1n+f BhW{True{}, acc}:
      IO.bind(BhW, List<&2, List<&2, U32>>, bhv.wk.step(jobs, acc), bhv.wk.go(f, jobs))
    case _ BhW{m, acc}:
      IO.pure(List<&2, List<&2, U32>>, acc)

def bhv.fork(n: Nat, +jobs: Chan(BhJob)) -> IO(List<Chan(List<&2, List<&2, U32>>)>):
  match n:
    case 0n:
      IO.pure(List<Chan(List<&2, List<&2, U32>>)>, Nil{})
    case 1n+m:
      do IO<List<Chan(List<&2, List<&2, U32>>)>>:
        ch : Chan(List<&2, List<&2, U32>>) <- IO.fork(List<&2, List<&2, U32>>, bhv.wk.go(U32.to_nat(4294967295), jobs, BhW{True{}, Nil{}}))
        rest : List<Chan(List<&2, List<&2, U32>>)> <- bhv.fork(m, jobs)
        return ch <> rest

def bhv.send(+jobs: Chan(BhJob), js: List<&2, BhJob>) -> IO(Unit):
  match js:
    case Nil{}:
      Chan.close(BhJob, jobs)
    case j <> more:
      do IO<Unit>:
        ok : Result<&1, &1, BhJob, Unit> <- Chan.send(BhJob, jobs, j)
        bhv.send(jobs, more)

def bhv.join(chs: List<Chan(List<&2, List<&2, U32>>)>, acc: List<&2, List<&2, U32>>) -> IO(List<&2, List<&2, U32>>):
  match chs:
    case Nil{}:
      IO.pure(List<&2, List<&2, U32>>, acc)
    case ch <> more:
      do IO<List<&2, List<&2, U32>>>:
        vs : List<&2, List<&2, U32>> <- IO.join(List<&2, List<&2, U32>>, ch)
        bhv.join(more, List.append(&2, List<&2, U32>, vs, acc))

# xargs -P PROCS (0: all at once)
def bhv.pool(+procs: Nat, +js: List<&2, BhJob>) -> IO(List<&2, List<&2, U32>>):
  +n = List.length(&2, BhJob, js)
  do IO<List<&2, List<&2, U32>>>:
    +jobs : Chan(BhJob) <- Chan.new(BhJob, U32.from_nat(1n+n))
    bhv.send(jobs, js)
    chs : List<Chan(List<&2, List<&2, U32>>)> <- bhv.fork(Bool.pick(Nat, Nat.is_eq(procs, 0n), Nat.max(n, 1n), procs), jobs)
    bhv.join(chs, Nil{})

def bhv.jobs(ns: List<&2, List<&2, U32>>, +c: BhCf, +lang: String, +k: Nat, +r: String, +gen: Bool) -> List<&2, BhJob>:
  match ns:
    case Nil{}:
      Nil{}
    case n <> more:
      BhJob{c, lang, k, S.str(n), r, gen} <> bhv.jobs(more, c, lang, k, r, gen)

# summary.txt: `TAG LANG: P/N pass; ` then `uniq -c | tr -s ' ' | tr '\n' ' '`
# of the sorted verdicts (" C VERDICT " each)
def bhv.field2(+l: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, bhv.has(l, 9), bhv.before(bhv.after(l, 9), 9), l)

def bhv.field2s(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      bhv.field2(l) <> bhv.field2s(more)

def bhv.flush(+cur: List<&2, U32>, +n: Nat) -> String:
  Bool.pick(String, Nat.is_eq(n, 0n), "", " " ++ Nat.show(n) ++ " " ++ S.str(cur) ++ " ")

def bhv.head.eq(xs: List<&2, List<&2, U32>>, +v: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +x <> more:
      S.eq(x, v)

def bhv.uniq(vs: List<&2, List<&2, U32>>, +cur: List<&2, U32>, +n: Nat, same: Bool) -> String:
  match vs same:
    case Nil{} _:
      bhv.flush(cur, n)
    case v <> +more True{}:
      bhv.uniq(more, cur, 1n+n, bhv.head.eq(more, cur))
    case +v <> +more False{}:
      bhv.flush(cur, n) ++ bhv.uniq(more, v, 1n, bhv.head.eq(more, v))

def bhv.passes(ls: List<&2, List<&2, U32>>, +n: Nat) -> Nat:
  match ls:
    case Nil{}:
      n
    case +l <> more:
      bhv.passes(more, Nat.add(n, Bool.pick(Nat, S.suffix(l, S.b("\tpass")), 1n, 0n)))

def bhv.summary(+tag: String, +lang: String, +ls: List<&2, List<&2, U32>>) -> String:
  +vs = bhv.sort(bhv.field2s(ls))
  String.concat([tag, " ", lang, ": ", Nat.show(bhv.passes(ls, 0n)), "/", Nat.show(List.length(&2, List<&2, U32>, ls)), " pass; ",
    bhv.uniq(vs, Nil{}, 0n, bhv.head.eq(vs, Nil{}))])

def bhv.log(+c: BhCf, +msg: String) -> IO(Unit):
  Ck.log("behaviour " ++ bhv.cf.tag(c) ++ ": " ++ msg)

def bhv.gen.all(gen: Bool, +c: BhCf, +lang: String, +k: Nat, +r: String, +gjobs: Nat, +names: List<&2, List<&2, U32>>) -> IO(Unit):
  match gen:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      do IO<Unit>:
        bhv.log(c, lang ++ ": generating " ++ Nat.show(List.length(&2, List<&2, U32>, names)) ++ " answers from " ++ bhv.cf.ckpt(c))
        vs : List<&2, List<&2, U32>> <- bhv.pool(gjobs, bhv.jobs(names, c, lang, k, r, True{}))
        return Unit{}

def bhv.lang(+c: BhCf, +lang: String, +k: Nat, +quiet: Bool, +jobs: Nat, +gjobs: Nat) -> IO(Unit):
  do IO<Unit>:
    +q : String = bhv.cf.q(c)
    +there : Bool <- bhv.test("-d", q ++ "/tasks/" ++ lang)
    bhv.need(there, 2, "behaviour run: no tasks/" ++ lang ++ " (run behaviour tasks)")
    +r : String = q ++ "/results/" ++ bhv.cf.tag(c) ++ "/" ++ lang
    S.mkdir(r)
    +names : List<&2, List<&2, U32>> <- bhv.ls(q ++ "/tasks/" ++ lang, False{})
    bhv.gen.all(bhv.cf.gen(c), c, lang, k, r, gjobs, names)
    bhv.log(c, lang ++ ": checking")
    vs : List<&2, List<&2, U32>> <- bhv.pool(jobs, bhv.jobs(names, c, lang, k, r, False{}))
    +ls : List<&2, List<&2, U32>> = bhv.sort(vs)
    S.write(r ++ "/verdicts.tsv", bhv.unlines(ls))
    +s : String = bhv.summary(bhv.cf.tag(c), lang, ls)
    S.write(r ++ "/summary.txt", S.b(s ++ "\n"))
    bhv.log(c, s)
    bhv.say(quiet, s)

# The languages' checkers (run.sh's case)
def bhv.lang.code(+l: String) -> Nat:
  Bool.pick(Nat, String.eq(l, "haskell"), 0n, Bool.pick(Nat, String.eq(l, "lean"), 1n, Bool.pick(Nat, String.eq(l, "agda"), 2n, 3n)))

# elan's toolchain directory: sed 's|/|--|; s|:|---|' lean-toolchain | tr -d '\n'
def bhv.toolchain(ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      List.append(&2, U32, S.replace.first(S.replace.first(l, [47], S.b("--")), [58], S.b("---")), bhv.toolchain(more))

def bhv.lake.ok(ok: Bool, +ml: String, +o: S.Out) -> IO(String):
  match ok:
    case True{}:
      IO.pure(String, S.str(S.chomp(S.Out.text(o))))
    case False{}:
      IO.die(String, 1, "behaviour run: lake env failed in " ++ ml)

def bhv.store.ok(m: Maybe<&2, List<&2, U32>>) -> Maybe<&2, List<&2, U32>>:
  match m:
    case Some{+x}:
      Bool.pick(Maybe<&2, List<&2, U32>>, Bool.and(S.suffix(x, S.b("/bin/agda")), Nat.is_ge(S.len(x), 20n)), Some{x}, None{})
    case None{}:
      None{}

def bhv.first(a: Maybe<&2, List<&2, U32>>, b: Maybe<&2, List<&2, U32>>) -> Maybe<&2, List<&2, U32>>:
  match a:
    case Some{x}:
      Some{x}
    case None{}:
      b

def bhv.upto.quote(xs: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> +t False{}:
      h <> bhv.upto.quote(t, Bool.or(S.head.is(t, 34), S.head.is(t, 10)))
    case _ _:
      Nil{}

# the text after an opening quote up to the closing one (None at a newline or the end)
def bhv.quoted.of(+xs: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  +x = bhv.upto.quote(xs, Bool.or(S.head.is(xs, 34), S.head.is(xs, 10)))
  Bool.pick(Maybe<&2, List<&2, U32>>, S.head.is(List.drop(&2, U32, xs, S.len(x)), 34), Some{x}, None{})

def bhv.store.at(hit: Bool, +t: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  match hit:
    case True{}:
      bhv.store.ok(bhv.quoted.of(t))
    case False{}:
      None{}

# grep -ao '"/nix/store/[^"]*/bin/agda"' WRAPPER | head -1 | tr -d '"'
def bhv.store.agda(xs: List<&2, U32>, +p: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      None{}
    case +h <> +t:
      bhv.first(bhv.store.at(S.prefix(h <> t, p), t), bhv.store.agda(t, p))

def bhv.agda.bin(m: Maybe<&2, List<&2, U32>>, +w: String) -> String:
  match m:
    case Some{x}:
      S.str(x)
    case None{}:
      w

def bhv.agda.which(ok: Bool, +o: S.Out) -> IO(String):
  match ok:
    case True{}:
      IO.pure(String, S.str(S.chomp(S.Out.text(o))))
    case False{}:
      IO.die(String, 1, "behaviour run: no agda on PATH (set AGDA)")

# AGDA, or the real agda behind nixpkgs' wrapper on PATH (the wrapper passes
# its own --library-file), as bend/Check.bend finds it
def bhv.agda.find(none: Bool, +a: String) -> IO(String):
  match none:
    case False{}:
      IO.pure(String, a)
    case True{}:
      do IO<String>:
        +o : S.Out <- S.run.quiet(".", [], 60, "sh", ["-c", "command -v agda"], Nil{})
        +w : String <- bhv.agda.which(U32.is_eq(S.Out.status(o), 0), o)
        wt : List<&2, U32> <- S.read(w)
        return bhv.agda.bin(bhv.store.agda(wt, S.b("\"/nix/store/")), w)

def bhv.tools(k: Nat, +c: BhCf, +lang: String) -> IO(BhCf):
  match k:
    case 0n:
      do IO<BhCf>:
        +ghc : String <- bhv.env("GHC", bhv.cf.ft(c) ++ "/run/check-cache/ghc-harness/bin/ghc")
        return bhv.cf.with(c, ghc, Nil{}, 120n, "")
    case 1n:
      do IO<BhCf>:
        +ml : String <- bhv.env("MATHLIB", bhv.cf.ft(c) ++ "/run/harness/mathlib4")
        +home : String <- S.env("HOME", "")
        tc : List<&2, U32> <- S.read(ml ++ "/lean-toolchain")
        +bin : String <- bhv.env("LEAN_BIN", home ++ "/.elan/toolchains/" ++ S.str(bhv.toolchain(S.split.lines(tc))) ++ "/bin")
        +path : String <- S.env("PATH", "")
        +o : S.Out <- S.run.quiet(ml, ["PATH=" ++ bin ++ ":" ++ path], 3600, bin ++ "/lake", ["env", "printenv", "LEAN_PATH"], Nil{})
        +lp : String <- bhv.lake.ok(U32.is_eq(S.Out.status(o), 0), ml, o)
        +to : Nat <- S.env.nat("LEAN_TIMEOUT", 300n)
        return bhv.cf.with(c, bin, ["LEAN_PATH=" ++ lp, "PATH=" ++ bin ++ ":" ++ path], to, "")
    case 2n:
      do IO<BhCf>:
        +a0 : String <- S.env("AGDA", "")
        +agda : String <- bhv.agda.find(String.is_empty(a0), a0)
        +libs : String <- bhv.env("AGDA_LIBS", bhv.cf.ft(c) ++ "/run/check-cache/agda/libraries")
        +to : Nat <- S.env.nat("AGDA_TIMEOUT", 300n)
        return bhv.cf.with(c, agda, Nil{}, to, libs)
    case _:
      IO.die(BhCf, 2, "behaviour run: no language " ++ lang ++ " (haskell, lean, agda)")

def bhv.langs(ls: List<&2, String>, +c: BhCf, +quiet: Bool, +jobs: Nat, +gjobs: Nat) -> IO(Unit):
  match ls:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +lang <> more:
      do IO<Unit>:
        +k : Nat = bhv.lang.code(lang)
        +cl : BhCf <- bhv.tools(k, c, lang)
        bhv.lang(cl, lang, k, quiet, jobs, gjobs)
        bhv.langs(more, c, quiet, jobs, gjobs)

# a run: the checkpoint (a file, made absolute) unless REF or CHECK_ONLY
def bhv.ckpt.if(need: Bool, +ckpt: String) -> IO(String):
  match need:
    case False{}:
      IO.pure(String, ckpt)
    case True{}:
      do IO<String>:
        +there : Bool <- bhv.test("-f", ckpt)
        bhv.need(there, 2, "behaviour run: no checkpoint " ++ ckpt)
        S.realpath(ckpt)

def bhv.run.with(+ckpt: String, +tag: String, ls: List<&2, String>, +only: Bool, +quiet: Bool) -> IO(Unit):
  do IO<Unit>:
    +ref : Bool = String.eq(ckpt, "REF")
    +ck : String <- bhv.ckpt.if(Bool.and(Bool.not(ref), Bool.not(only)), ckpt)
    +ft : String <- bhv.root()
    +q : String <- bhv.dir(ft)
    +tokens : String <- bhv.env("TOKENS", "160")
    +ana : String <- bhv.env("ANA", ft ++ "/run/gcroot-ana/bin/ana")
    +threads : String <- bhv.env("ANA_THREADS", "4")
    +jobs : Nat <- S.env.nat("JOBS", 3n)
    +gjobs : Nat <- S.env.nat("GEN_JOBS", 1n)
    +reuse : Bool <- bhv.set("REUSE")
    +keep : Bool <- bhv.set("KEEP_BUILD")
    bhv.langs(bhv.langs.or(ls), BhCf{q, ft, tag, ck, Bool.not(only), ref, reuse, keep, tokens, ana, threads, "", Nil{}, 0n, ""}, quiet, jobs, gjobs)

def bhv.run(xs: List<String>) -> IO(Unit):
  match xs:
    case +ckpt <> +tag <> more:
      do IO<Unit>:
        +only : Bool <- bhv.set("CHECK_ONLY")
        bhv.run.with(ckpt, tag, bhv.args(more), only, False{})
    case _:
      IO.die(Unit, 2, "usage: bend-corpus-v2 behaviour run CKPT|REF TAG [haskell|lean|agda ...]")

# The self-test (selftest.sh) ------------------------------------------------------
#
# Every task gets its reference answer except the ones spec/selftest.mut
# breaks: `@@ mut LANG NAME VERDICT` and the answer's lines up to the next
# `@@` line (trailing blank lines dropped), closed by a fence unless VERDICT
# is unclosed.  The answers are checked as `CHECK_ONLY=1 run - selftest`
# would, into results/selftest/LANG/, and every verdict compared with the
# expected one (pass for the others); exits 1 on a mismatch.

type BhM is Data:
  BhM{lang: List<&2, U32>, name: List<&2, U32>, v: List<&2, U32>, ans: List<&2, List<&2, U32>>}

def bhv.m.add(+l: List<&2, U32>, ms: List<&2, BhM>) -> List<&2, BhM>:
  match ms:
    case Nil{}:
      Nil{}
    case BhM{lang, name, v, ans} <> more:
      BhM{lang, name, v, l <> ans} <> more

def bhv.m.class(+l: List<&2, U32>) -> Nat:
  Bool.pick(Nat, S.prefix(l, S.b("@@#")), 0n, Bool.pick(Nat, S.prefix(l, S.b("@@ mut ")), 1n, Bool.pick(Nat, S.prefix(l, S.b("@@")), 2n, 3n)))

def bhv.m.do(c: Nat, +file: String, +fnr: Nat, +l: List<&2, U32>, ms: List<&2, BhM>) -> List<&2, BhM>:
  match c:
    case 0n:
      ms
    case 1n:
      +fs = bhv.fields(l)
      BhM{bhv.nth(fs, 2n), bhv.nth(fs, 3n), bhv.nth(fs, 4n), Nil{}} <> ms
    case 2n:
      BhM{Nil{}, S.b(file ++ ":" ++ Nat.show(fnr)), S.b("unknown directive " ++ S.str(l)), Nil{}} <> ms
    case _:
      bhv.m.add(l, ms)

def bhv.m.go(ls: List<&2, List<&2, U32>>, +file: String, +fnr: Nat, ms: List<&2, BhM>) -> List<&2, BhM>:
  match ls:
    case Nil{}:
      ms
    case +l <> more:
      bhv.m.go(more, file, 1n+fnr, bhv.m.do(bhv.m.class(l), file, fnr, l, ms))

def bhv.m.answer(+ans: List<&2, List<&2, U32>>) -> List<&2, U32>:
  +a = S.chomp(bhv.unlines(List.reverse(&2, List<&2, U32>, ans)))
  Bool.pick(List<&2, U32>, bhv.empty(a), Nil{}, List.append(&2, U32, a, [10]))

# a record without a language is an unknown directive (its name says where)
def bhv.m.bad(ms: List<&2, BhM>) -> Maybe<&2, List<&2, U32>>:
  match ms:
    case Nil{}:
      None{}
    case BhM{+lang, +name, +v, ans} <> more:
      Bool.pick(Maybe<&2, List<&2, U32>>, Bool.or(bhv.empty(lang), bhv.empty(v)), Some{bhv.cat([name, S.b(": "), v])}, bhv.m.bad(more))

def bhv.m.ok(m: Maybe<&2, List<&2, U32>>) -> IO(Unit):
  match m:
    case None{}:
      IO.pure(Unit, Unit{})
    case Some{x}:
      IO.die(Unit, 2, "behaviour selftest: " ++ S.str(x))

# the expected verdict of LANG/NAME: the last record's, else pass
def bhv.want(ms: List<&2, BhM>, +lang: List<&2, U32>, +n: List<&2, U32>, +w: List<&2, U32>) -> List<&2, U32>:
  match ms:
    case Nil{}:
      w
    case BhM{+l, +m, +v, ans} <> more:
      bhv.want(more, lang, n, Bool.pick(List<&2, U32>, Bool.and(S.eq(l, lang), S.eq(m, n)), v, w))

def bhv.mutated(ms: List<&2, BhM>, +lang: List<&2, U32>) -> String:
  match ms:
    case Nil{}:
      ""
    case BhM{+l, +m, +v, ans} <> more:
      Bool.pick(String, S.eq(l, lang), S.str(m) ++ "=" ++ S.str(v) ++ " ", "") ++ bhv.mutated(more, lang)

# selftest's answers: every task's reference
def bhv.st.refs(ns: List<&2, List<&2, U32>>, +q: String, +lang: String, +t: String) -> IO(Unit):
  match ns:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +n <> more:
      do IO<Unit>:
        p : List<&2, U32> <- S.read(q ++ "/tasks/" ++ lang ++ "/" ++ S.str(n) ++ "/prompt")
        f : List<&2, U32> <- S.read(q ++ "/refs/" ++ lang ++ "/" ++ S.str(n))
        S.write(t ++ "/" ++ lang ++ "/" ++ S.str(n) ++ ".out", List.append(&2, U32, p, f))
        bhv.st.refs(more, q, lang, t)

def bhv.st.prep(ls: List<&2, String>, +q: String, +t: String) -> IO(Unit):
  match ls:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +lang <> more:
      do IO<Unit>:
        S.rm(t ++ "/" ++ lang)
        S.mkdir(t ++ "/" ++ lang)
        ns : List<&2, List<&2, U32>> <- bhv.ls(q ++ "/tasks/" ++ lang, True{})
        bhv.st.refs(ns, q, lang, t)
        bhv.st.prep(more, q, t)

def bhv.st.mut.if(there: Bool, +q: String, +t: String, m: BhM) -> IO(Unit):
  match there m:
    case False{} _:
      IO.pure(Unit, Unit{})
    case True{} BhM{+lang, +name, +v, ans}:
      do IO<Unit>:
        p : List<&2, U32> <- S.read(q ++ "/tasks/" ++ S.str(lang) ++ "/" ++ S.str(name) ++ "/prompt")
        S.write(t ++ "/" ++ S.str(lang) ++ "/" ++ S.str(name) ++ ".out",
          bhv.cat([p, bhv.m.answer(ans), Bool.pick(List<&2, U32>, S.eq(v, S.b("unclosed")), Nil{}, S.b("```\n"))]))

def bhv.m.lang(+m: BhM) -> String:
  match m:
    case BhM{lang, name, v, ans}:
      S.str(lang)

# a broken answer, when its language's directory is there (as selftest.sh's mut)
def bhv.st.muts(ms: List<&2, BhM>, +q: String, +t: String) -> IO(Unit):
  match ms:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +m <> more:
      do IO<Unit>:
        +there : Bool <- bhv.test("-d", t ++ "/" ++ bhv.m.lang(m))
        bhv.st.mut.if(there, q, t, m)
        bhv.st.muts(more, q, t)

def bhv.st.same(ok: Bool, +lang: String, +n: List<&2, U32>, +v: List<&2, U32>, +w: List<&2, U32>) -> IO(Nat):
  match ok:
    case True{}:
      IO.pure(Nat, 0n)
    case False{}:
      do IO<Nat>:
        IO.print("selftest: " ++ lang ++ "/" ++ S.str(n) ++ " is " ++ S.str(v) ++ ", expected " ++ S.str(w))
        return 1n

def bhv.st.line(+l: List<&2, U32>, +ms: List<&2, BhM>, +lang: String) -> IO(Nat):
  +n = bhv.before(l, 9)
  +v = bhv.after(l, 9)
  +w = bhv.want(ms, S.b(lang), n, S.b("pass"))
  bhv.st.same(S.eq(v, w), lang, n, v, w)

def bhv.st.lines(ls: List<&2, List<&2, U32>>, +ms: List<&2, BhM>, +lang: String, +bad: Nat) -> IO(Nat):
  match ls:
    case Nil{}:
      IO.pure(Nat, bad)
    case l <> more:
      do IO<Nat>:
        +b : Nat <- bhv.st.line(l, ms, lang)
        bhv.st.lines(more, ms, lang, Nat.add(bad, b))

def bhv.st.cmp(ls: List<&2, String>, +ms: List<&2, BhM>, +t: String, +bad: Nat) -> IO(Nat):
  match ls:
    case Nil{}:
      IO.pure(Nat, bad)
    case +lang <> more:
      do IO<Nat>:
        xs : List<&2, U32> <- S.read(t ++ "/" ++ lang ++ "/verdicts.tsv")
        +vs : List<&2, List<&2, U32>> = S.split.lines(xs)
        +b : Nat <- bhv.st.lines(vs, ms, lang, 0n)
        IO.print("selftest " ++ lang ++ ": " ++ Nat.show(List.length(&2, List<&2, U32>, vs)) ++ " tasks; " ++ Nat.show(bhv.passes(vs, 0n))
          ++ " pass; mutated: " ++ bhv.mutated(ms, S.b(lang)))
        bhv.st.cmp(more, ms, t, Nat.add(bad, b))

def bhv.st.fin(+bad: Nat) -> IO(Unit):
  match bad:
    case 0n:
      IO.print("selftest: all verdicts as expected")
    case 1n+k:
      IO.die(Unit, 1, "behaviour selftest: " ++ Nat.show(1n+k) ++ " verdict(s) not as expected")

def bhv.selftest(xs: List<String>) -> IO(Unit):
  do IO<Unit>:
    +ls : List<&2, String> = bhv.langs.or(bhv.args(xs))
    +ft : String <- bhv.root()
    +q : String <- bhv.dir(ft)
    +t : String = q ++ "/results/selftest"
    +file : String = q ++ "/spec/selftest.mut"
    mx : List<&2, U32> <- S.read(file)
    +ms : List<&2, BhM> = List.reverse(&2, BhM, bhv.m.go(S.split.lines(mx), file, 1n, Nil{}))
    bhv.m.ok(bhv.m.bad(ms))
    bhv.st.prep(ls, q, t)
    bhv.st.muts(ms, q, t)
    bhv.run.with("-", "selftest", ls, True{}, True{})
    +bad : Nat <- bhv.st.cmp(ls, ms, t, 0n)
    bhv.st.fin(bad)

# Main ---------------------------------------------------------------------------

def bhv.usage() -> IO(Unit):
  IO.die(Unit, 2, "usage: bend-corpus-v2 behaviour tasks [--check] [LANG...] | run CKPT|REF TAG [LANG...] | selftest [LANG...]")

def bhv.sub.go(k: Nat, xs: List<String>) -> IO(Unit):
  match k:
    case 1n:
      bhv.tasks(xs)
    case 2n:
      bhv.run(xs)
    case 3n:
      bhv.selftest(xs)
    case _:
      bhv.usage()

def bhv.sub(+c: String, xs: List<String>) -> IO(Unit):
  bhv.sub.go(Bool.pick(Nat, String.eq(c, "tasks"), 1n, Bool.pick(Nat, String.eq(c, "run"), 2n, Bool.pick(Nat, String.eq(c, "selftest"), 3n, 0n))), xs)

def bhv.main(xs: List<String>) -> IO(Unit):
  match xs:
    case +c <> more:
      bhv.sub(c, more)
    case _:
      bhv.usage()
