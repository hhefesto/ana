# Form 2's kinds: a sample (2026-11-13)

Rendered by run/v9/f3's bend-transcript from own5's and collect5's first units, with exlaw's laws; every echo checked against agent-mugen running Bend on the file (tools/runs/f3-roundtrip.zsh: all identical). Each session is shown as ana trains on it.

## Her comment, then the function (a plain direct ask)

`own:hs2bend/00013/AsPatterns.bend#whitespaceTable@219`

````
## user

Add `whitespaceTable` to hs2bend/00013/AsPatterns.bend.

Every character recognized by the same Data.Char.isSpace used by Prelude.words.

```bend
def whitespaceTable() -> List<&2, U32>:

law whitespaceTable.ex1:
  {whitespaceTable() == [9, 10, 11, 12, 13, 32, 160, 5760, 8192, 8193, 8194, 8195, 8196, 8197, 8198, 8199, 8200, 8201, 8202, 8239, 8287, 12288] : List<&2, U32>}
```

## read

hs2bend/00013/AsPatterns.bend 194 24

## echo

```
    Range{42892, 42892, 1, 4294967295},
    Range{42897, 42899, 2, 4294967295},
    Range{42900, 42900, 1, 48},
    Range{42903, 42921, 2, 4294967295},
    Range{42933, 42947, 2, 4294967295},
    Range{42952, 42954, 2, 4294967295},
    Range{42961, 42961, 1, 4294967295},
    Range{42967, 42969, 2, 4294967295},
    Range{42998, 42998, 1, 4294967295},
    Range{43859, 43859, 1, 4294966368},
    Range{43888, 43967, 1, 4294928432},
    Range{65345, 65370, 1, 4294967264},
    Range{66600, 66639, 1, 4294967256},
    Range{66776, 66811, 1, 4294967256},
    Range{66967, 66977, 1, 4294967257},
    Range{66979, 66993, 1, 4294967257},
    Range{66995, 67001, 1, 4294967257},
    Range{67003, 67004, 1, 4294967257},
    Range{68800, 68850, 1, 4294967232},
    Range{71872, 71903, 1, 4294967264},
    Range{93792, 93823, 1, 4294967264},
    Range{125218, 125251, 1, 4294967262}
  ]
[lines 194-217 of 217]
```

## add

hs2bend/00013/AsPatterns.bend
# Every character recognized by the same Data.Char.isSpace used by Prelude.words.
def whitespaceTable() -> List<&2, U32>:
  [9, 10, 11, 12, 13, 32, 160, 5760, 8192, 8193, 8194, 8195, 8196, 8197, 8198, 8199, 8200, 8201, 8202, 8239, 8287, 12288]

law whitespaceTable.ex1:
  {whitespaceTable() == [9, 10, 11, 12, 13, 32, 160, 5760, 8192, 8193, 8194, 8195, 8196, 8197, 8198, 8199, 8200, 8201, 8202, 8239, 8287, 12288] : List<&2, U32>}

def whitespaceTable.ex1():
  {==}

## echo

```
added: whitespaceTable, whitespaceTable.ex1, lines 218-226
ALL PROOFS CHECK
Use --verdict for mathematical validity.
(exit 0)
```

## mugen

ALL PROOFS CHECK. Added `whitespaceTable` to hs2bend/00013/AsPatterns.bend, with its laws `whitespaceTable.ex1`.

````

## A helper first, and a near name that is not there (helper-1-miss)

`own:hs2bend/00111/Guards.bend#isRight@64`

````
## user

Add `isRight` to hs2bend/00111/Guards.bend.

Test the literal Pythagorean equality, without imposing positive side lengths.

```bend
def isRight(a: Z, b: Z, c: Z) -> String:
```

## read

hs2bend/00111/Guards.bend 34 24

## echo

```
        case Nonnegative{m}: Nonnegative{Nat.add(n, m)}
        case Negative{m}: difference(n, 1n+m)
    case Negative{n}:
      match b:
        case Nonnegative{m}: difference(m, 1n+n)
        case Negative{m}: Negative{1n+Nat.add(n, m)}

# Absolute natural magnitude of an exact signed integer.
def magnitude(z: Z) -> Nat:
  match z:
    case Nonnegative{n}: n
    case Negative{p}: 1n+p

# Absolute value retains unbounded Integer range, including arbitrarily large negatives.
def myAbs(x: Z) -> Z:
  Nonnegative{magnitude(x)}

# Sodium is acceptable on the closed interval 135 through 145.
def bloodSodium(x: Z) -> String:
  match x:
    case Negative{p}: "Too low"
    case Nonnegative{+n}:
      select(String, Nat.is_gt(n, 145n), u => "Too high", u => select(String, Nat.is_lt(n, 135n), u => "Too low", u => "Just right"))
[lines 34-57 of 57]
```

## look

hs2bend/00111/Guards.bend
Z.is_eq

## echo

```
Z.is_eq: not in hs2bend/00111/Guards.bend or Base
```

## look

hs2bend/00111/Guards.bend
select
magnitude
String
Nat.is_eq
Nat.add
Nat.mul

## echo

```
select, lines 20-23:
def select(-A: Type, b: Bool, yes: Unit -> A, no: Unit -> A) -> A:
  match b:
    case True{}: yes(Unit{})
    case False{}: no(Unit{})

magnitude, lines 42-45:
def magnitude(z: Z) -> Nat:
  match z:
    case Nonnegative{n}: n
    case Negative{p}: 1n+p

String, in Base:
type String is Data:

Nat.is_eq, in Base:
def Nat.is_eq(a: Nat, b: Nat) -> Bool:

Nat.add, in Base:
def Nat.add(a: Nat, b: Nat) -> Nat:

Nat.mul, in Base:
def Nat.mul(a: Nat, +b: Nat) -> Nat:
```

## add

hs2bend/00111/Guards.bend
# Squaring erases the sign and preserves exact integer multiplication.
def square(x: Z) -> Nat:
  +n = magnitude(x)
  Nat.mul(n, n)

# Test the literal Pythagorean equality, without imposing positive side lengths.
def isRight(a: Z, b: Z, c: Z) -> String:
  select(String, Nat.is_eq(Nat.add(square(a), square(b)), square(c)), u => "Right on!", u => "Not a right angle")

## echo

```
added: square, isRight, lines 58-65
ALL PROOFS CHECK
Use --verdict for mathematical validity.
(exit 0)
```

## mugen

ALL PROOFS CHECK. Added `square` and `isRight` to hs2bend/00111/Guards.bend.

````

## A nearly empty file, with example laws (scratch-1)

`own:hs2bend/00116/Splitter.bend#scan@15`

````
## user

Add `scan` to hs2bend/00116/Splitter.bend.

Scan once; word and fields are reversed accumulators. keepLast distinguishes
splitOn's trailing empty field from myWords/myLines, which stop on empty input.

```bend
def scan(s: String, +sep: Char, +keepLast: Bool, +word: String, +fields: List<&2, String>) -> List<&2, String>:

law scan.ex1:
  {scan("", '0', True{}, "hello", []) == ["olleh"] : List<&2, String>}

law scan.ex2:
  {scan("ab", ' ', False{}, "a b", ["ab"]) == ["ab", "b aab"] : List<&2, String>}

law scan.ex3:
  {scan("hello", 'a', True{}, "", ["a b", "ab", "hello"]) == ["hello", "ab", "a b", "hello"] : List<&2, String>}
```

## read

hs2bend/00116/Splitter.bend 1 6

## echo

```
# Bend 2 translation of Splitter.
# source: curated:andrewMacmurray_haskell-book-solutions/src/ch9/Splitter.hs
# Literal delimiter splitting, retaining empty fields between consecutive delimiters.
# All pure functions and constants retained. Finite strings use Base.String.
import Base
[lines 1-6 of 6]
```

## look

hs2bend/00116/Splitter.bend
Bool.or
Bool.not
String.is_empty
List.reverse
String
String.reverse
Char.is_eq

## echo

```
Bool.or, in Base:
def Bool.or(a: Bool, b: Bool) -> Bool:

Bool.not, in Base:
def Bool.not(b: Bool) -> Bool:

String.is_empty, in Base:
def String.is_empty(s: String) -> Bool:

List.reverse, in Base:
def List.reverse.go(a, -A: Kind(a), xs: List<a, A>, acc: List<a, A>) ->

String, in Base:
type String is Data:

String.reverse, in Base:
def String.reverse.go(s: String, acc: String) -> String:

Char.is_eq, in Base:
def Char.is_eq(a: Char, b: Char) -> Bool:
```

## add

hs2bend/00116/Splitter.bend
# Choose one suspended branch.
def select(-A: Type, b: Bool, yes: Unit -> A, no: Unit -> A) -> A:
  match b:
    case True{}: yes(Unit{})
    case False{}: no(Unit{})

# Scan once; word and fields are reversed accumulators. keepLast distinguishes
# splitOn's trailing empty field from myWords/myLines, which stop on empty input.
def scan(s: String, +sep: Char, +keepLast: Bool, +word: String, +fields: List<&2, String>) -> List<&2, String>:
  match s:
    case SNil{}:
      select(List<&2, String>, Bool.or(keepLast, Bool.not(String.is_empty(word))),
        u => List.reverse(&2, String, String.reverse(word) <> fields),
        u => List.reverse(&2, String, fields))
    case SCon{+c, +rest}:
      select(List<&2, String>, Char.is_eq(c, sep),
        u => scan(rest, sep, keepLast, "", String.reverse(word) <> fields),
        u => scan(rest, sep, keepLast, SCon{c, word}, fields))

law scan.ex1:
  {scan("", '0', True{}, "hello", []) == ["olleh"] : List<&2, String>}

def scan.ex1():
  {==}

law scan.ex2:
  {scan("ab", ' ', False{}, "a b", ["ab"]) == ["ab", "b aab"] : List<&2, String>}

def scan.ex2():
  {==}

law scan.ex3:
  {scan("hello", 'a', True{}, "", ["a b", "ab", "hello"]) == ["hello", "ab", "a b", "hello"] : List<&2, String>}

def scan.ex3():
  {==}

## echo

```
added: select, scan, scan.ex1, scan.ex2, scan.ex3, lines 7-42
ALL PROOFS CHECK
Use --verdict for mathematical validity.
(exit 0)
```

## mugen

ALL PROOFS CHECK. Added `select` and `scan` to hs2bend/00116/Splitter.bend, with its laws `scan.ex1`, `scan.ex2` and `scan.ex3`.

````

## A law mutant: well-typed, wrong, caught by a law

`repo:hub__0xfd64aefef43747d3eaeea50c10a112e5/dkim.bend#Dkim.wsp@47`

````
## user

`Dkim.wsp` in hub__0xfd64aefef43747d3eaeea50c10a112e5/dkim.bend fails bend check. Fix it.

## check

hub__0xfd64aefef43747d3eaeea50c10a112e5/dkim.bend

## echo

```
SOME PROOFS FAIL
Error:
- expected : True{}
- observed : False{}
Location: Dkim.wsp.ex3
65 | def Dkim.wsp.ex3():
66>|   {==}
   |   ^^^^
67 | 
(exit 1)
```

## look

hub__0xfd64aefef43747d3eaeea50c10a112e5/dkim.bend
Dkim.wsp
String.starts_with

## echo

```
Dkim.wsp, lines 47-48:
def Dkim.wsp(+l: String) -> Bool:
  String.starts_with(" ", l) || String.starts_with(l, "\t")

String.starts_with, in Base:
law String.starts_with:
```

## def

hub__0xfd64aefef43747d3eaeea50c10a112e5/dkim.bend
def Dkim.wsp(+l: String) -> Bool:
  String.starts_with(l, " ") || String.starts_with(l, "\t")

## echo

```
ok: Dkim.wsp, lines 47-48
ALL PROOFS CHECK
Use --verdict for mathematical validity.
(exit 0)
```

## mugen

ALL PROOFS CHECK. Fixed `Dkim.wsp` in hub__0xfd64aefef43747d3eaeea50c10a112e5/dkim.bend: its law `Dkim.wsp.ex3` says False{}, and it computed True{}.

````

## A form mix-up (the `&2` dropped)

`own:hs2bend/00116/Splitter.bend#scan@15`

````
## user

`scan` in hs2bend/00116/Splitter.bend fails bend check. Fix it.

Scan once; word and fields are reversed accumulators. keepLast distinguishes
splitOn's trailing empty field from myWords/myLines, which stop on empty input.

## check

hs2bend/00116/Splitter.bend

## echo

```
SOME PROOFS FAIL
Error:
- expected : Quant
- observed : Data
Context:
- sep      : Char
- keepLast : Bool
- word     : String
- fields   : List<&2, String>
- u        : Unit
Location: scan
18 |       select(List<&2, String>, Bool.or(keepLast, Bool.not(String.is_empty(word))),
19>|         u => List.reverse(String, String.reverse(word) <> fields),
   |                           ^^^^^^
20 |         u => List.reverse(&2, String, fields))
(exit 1)
```

## look

hs2bend/00116/Splitter.bend
scan
select
Bool.or
Bool.not
String.is_empty
List.reverse
String
String.reverse
Char.is_eq

## echo

```
scan, lines 15-24:
def scan(s: String, +sep: Char, +keepLast: Bool, +word: String, +fields: List<&2, String>) -> List<&2, String>:
  match s:
    case SNil{}:
      select(List<&2, String>, Bool.or(keepLast, Bool.not(String.is_empty(word))),
        u => List.reverse(String, String.reverse(word) <> fields),
        u => List.reverse(&2, String, fields))
    case SCon{+c, +rest}:
      select(List<&2, String>, Char.is_eq(c, sep),
        u => scan(rest, sep, keepLast, "", String.reverse(word) <> fields),
        u => scan(rest, sep, keepLast, SCon{c, word}, fields))

select, lines 8-11:
def select(-A: Type, b: Bool, yes: Unit -> A, no: Unit -> A) -> A:
  match b:
    case True{}: yes(Unit{})
    case False{}: no(Unit{})

Bool.or, in Base:
def Bool.or(a: Bool, b: Bool) -> Bool:

Bool.not, in Base:
def Bool.not(b: Bool) -> Bool:

String.is_empty, in Base:
def String.is_empty(s: String) -> Bool:

List.reverse, in Base:
def List.reverse.go(a, -A: Kind(a), xs: List<a, A>, acc: List<a, A>) ->

String, in Base:
type String is Data:

String.reverse, in Base:
def String.reverse.go(s: String, acc: String) -> String:

Char.is_eq, in Base:
def Char.is_eq(a: Char, b: Char) -> Bool:
```

## def

hs2bend/00116/Splitter.bend
def scan(s: String, +sep: Char, +keepLast: Bool, +word: String, +fields: List<&2, String>) -> List<&2, String>:
  match s:
    case SNil{}:
      select(List<&2, String>, Bool.or(keepLast, Bool.not(String.is_empty(word))),
        u => List.reverse(&2, String, String.reverse(word) <> fields),
        u => List.reverse(&2, String, fields))
    case SCon{+c, +rest}:
      select(List<&2, String>, Char.is_eq(c, sep),
        u => scan(rest, sep, keepLast, "", String.reverse(word) <> fields),
        u => scan(rest, sep, keepLast, SCon{c, word}, fields))

## echo

```
ok: scan, lines 15-24
ALL PROOFS CHECK
Use --verdict for mathematical validity.
(exit 0)
```

## mugen

ALL PROOFS CHECK. Fixed `scan` in hs2bend/00116/Splitter.bend: bend check said expected Quant, observed Data at line 19.

````
