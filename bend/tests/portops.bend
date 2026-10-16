import Base
import ../Sys.bend as S
import ../CorpusV2/PortOps.bend as P

# The renames of bend-corpus-v2 port (bend/CorpusV2/PortOps.bend,
# 2026-10-16) against their meaning, on a small Base and modules written
# here: the declarations as the loader reads them (`def`, `law`, `@unsafe
# def`, `type` with brackets and a `:` in its parameters, its
# constructors); the header (comments and blank lines in it, the aliases);
# import paths folded and read through a sibling link, a hub path none of
# the root's; fresh names; and the plans: a module declaring a Base type
# and a Base constructor renames both and every token of them in its body
# but not in strings or comments; its importer renames `L.Text` and
# `L.Pair` and keeps `L.show`; an alias that shadows a Base name is renamed
# with the names its module declares and not the Base name it does not; a
# binder named like a constructor only the locked Base has is renamed, one
# the older Base had is not; a module with nothing to rename is its text;
# a checker's failures read back through the renames; whether an error
# points into a text.  Each check prints `ok NAME` or `FAIL NAME`; any FAIL
# exits 1.  Run from bend/tests.

type PoCk is Data:
  PoCk{name: String, ok: Bool}

def po.end(ok: Bool, +bad: Nat, +names: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "portops: " ++ Nat.show(bad) ++ " check(s) failed:" ++ names)

def po.say(cs: List<&2, PoCk>, +bad: Nat, +names: String) -> IO(Unit):
  match cs:
    case Nil{}:
      po.end(Nat.is_eq(bad, 0n), bad, names)
    case PoCk{+n, +ok} <> t:
      do IO<Unit>:
        IO.print(Bool.pick(String, ok, "ok ", "FAIL ") ++ n)
        po.say(t, Bool.pick(Nat, ok, bad, 1n+bad), Bool.pick(String, ok, names, names ++ " " ++ n))

def po.texts.eq(xs: List<&2, List<&2, U32>>, ys: List<&2, List<&2, U32>>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case +x <> xt +y <> yt:
      Bool.and(S.eq(x, y), po.texts.eq(xt, yt))
    case _ _:
      False{}

def po.strs(xs: List<&2, String>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      S.b(x) <> po.strs(t)

def po.is(+xs: List<&2, List<&2, U32>>, ys: List<&2, String>) -> Bool:
  po.texts.eq(xs, po.strs(ys))

# The texts ------------------------------------------------------------------------------------------

def po.base() -> String:
  "import Base\n\n# Key is a key; Text is what it typed\ntype Event is Data:\n  Key{code: U32, down: Bool}\n  Text{text: String}\n\ntype Ex is Data:\n  E1{op: U32, a: Ex}\n  EK{c: U32}\n\ndef Pair(-A: Type, -B: Type) -> Type:\n  A & B\n\ndef TCP.recv_bytes(n: U32) -> U32:\n  n\n\ntype Poll<a, b, -A: Kind(a), -R: Kind(b)> is Kind(a <&> b):\n  Ready{value: A}\n  Wait{rest: R}\n\n@unsafe def Unsafe.peek(n: U32) -> U32:\n  n\n\nlaw idem:\n  for n: U32\n  {n == n : U32}\n"

def po.old() -> String:
  "type Event is Data:\n  Key{code: U32, down: Bool}\n\ntype Poll<a, b, -A: Kind(a), -R: Kind(b)> is Kind(a <&> b):\n  Ready{value: A}\n  Wait{rest: R}\n"

def po.lib() -> String:
  "# Inputs: a text, or another\nimport Base\n\ntype Input is Data:\n  Text{value: String}\n  Other{n: U32}\n\ntype Pair is Data:\n  MkPair{a: U32, b: U32}\n\ndef show(i: Input) -> String:\n  match i:\n    case Text{value}: value\n    case Other{n}: \"Text\"  # Text stays here\n\ndef Text_(n: U32) -> U32:\n  n\n"

def po.lib.want() -> String:
  "# Inputs: a text, or another\nimport Base\n\ntype Input is Data:\n  Text__{value: String}\n  Other{n: U32}\n\ntype Pair_ is Data:\n  MkPair{a: U32, b: U32}\n\ndef show(i: Input) -> String:\n  match i:\n    case Text__{value}: value\n    case Other{n}: \"Text\"  # Text stays here\n\ndef Text_(n: U32) -> U32:\n  n\n"

def po.tcp() -> String:
  "import Base\n\ndef recv_bytes(n: U32) -> U32:\n  n\n"

def po.main() -> String:
  "import Base\n\n# the pieces\nimport ./lib.bend as L\nimport ../net/tcp.bend as TCP\n\ndef go(p: L.Pair) -> String:\n  L.show(L.Text{\"hi\"})\n\ndef get(n: U32) -> U32:\n  TCP.recv_bytes(n)\n\ndef far(n: U32) -> U32:\n  TCP.other(n)\n"

def po.main.want() -> String:
  "import Base\n\n# the pieces\nimport ./lib.bend as L\nimport ../net/tcp.bend as TCP_\n\ndef go(p: L.Pair_) -> String:\n  L.show(L.Text__{\"hi\"})\n\ndef get(n: U32) -> U32:\n  TCP_.recv_bytes(n)\n\ndef far(n: U32) -> U32:\n  TCP.other(n)\n"

def po.bind() -> String:
  "import Base\n\ntype T is Data:\n  Two{a: U32, b: U32}\n\ndef f(t: T) -> U32:\n  match t:\n    case Two{E1, Ready}: E1\n\ndef g(t: T) -> Ex:\n  EK{3}\n"

def po.bind.want() -> String:
  "import Base\n\ntype T is Data:\n  Two{a: U32, b: U32}\n\ndef f(t: T) -> U32:\n  match t:\n    case Two{E1_, Ready}: E1_\n\ndef g(t: T) -> Ex:\n  EK{3}\n"

def po.plain() -> String:
  "import Base\nimport ./lib.bend as L\n\ndef h(i: L.Input) -> String:\n  L.show(i)\n"

def po.links() -> List<&2, P.PtoLink>:
  [P.PtoLink{S.b("Link"), S.b("own__link")}]

def po.mods() -> List<&2, P.PtoMod>:
  [P.pto.mod(po.links(), S.b("r__x/src/lib.bend"), S.b(po.lib())),
   P.pto.mod(po.links(), S.b("r__x/net/tcp.bend"), S.b(po.tcp())),
   P.pto.mod(po.links(), S.b("r__x/src/main.bend"), S.b(po.main())),
   P.pto.mod(po.links(), S.b("r__x/src/bind.bend"), S.b(po.bind())),
   P.pto.mod(po.links(), S.b("r__x/src/plain.bend"), S.b(po.plain()))]

def po.b() -> P.PtoBase:
  P.pto.base.of(S.b(po.base()), S.b(po.old()))

def po.nth(ps: List<&2, P.PtoPlan>, n: Nat) -> P.PtoPlan:
  match ps n:
    case p <> t 0n:
      p
    case p <> t 1n+k:
      po.nth(t, k)
    case Nil{} _:
      P.PtoPlan{Nil{}, Nil{}, Nil{}, Nil{}, 0n, 0n, 0n}

def po.rn.is(rs: List<&2, P.PtoRn>, ws: List<&2, String>) -> Bool:
  match rs ws:
    case Nil{} Nil{}:
      True{}
    case P.PtoRn{+o, +n} <> rt +a <> +b <> wt:
      Bool.and(Bool.and(S.eq(o, S.b(a)), S.eq(n, S.b(b))), po.rn.is(rt, wt))
    case _ _:
      False{}

def po.imps.is(imps: List<&2, P.PtoImp>, ws: List<&2, String>) -> Bool:
  match imps ws:
    case Nil{} Nil{}:
      True{}
    case P.PtoImp{+p, +a} <> it +x <> +y <> wt:
      Bool.and(Bool.and(S.eq(p, S.b(x)), S.eq(a, S.b(y))), po.imps.is(it, wt))
    case _ _:
      False{}

# Checks ----------------------------------------------------------------------------------------------

def po.decl.checks() -> List<&2, PoCk>:
  +bd = P.pto.decls(S.b(po.base()))
  +ld = P.pto.decls(S.b(po.lib()))
  +b = po.b()
  [PoCk{"decls: def, type with brackets and a : in its parameters, @unsafe def, law", po.is(P.pto.decl.tlds(bd), ["Event", "Ex", "Pair", "TCP.recv_bytes", "Poll", "Unsafe.peek", "idem"])},
   PoCk{"decls: each type's constructors, a comment between types passed over", po.is(P.pto.decl.ctrs(bd), ["Key", "Text", "E1", "EK", "Ready", "Wait"])},
   PoCk{"decls: a module's (a string and a comment after a match arm are no declaration)", Bool.and(po.is(P.pto.decl.tlds(ld), ["Input", "Pair", "show", "Text_"]), po.is(P.pto.decl.ctrs(ld), ["Text", "Other", "MkPair"]))},
   PoCk{"base: the constructors only the locked Base has", Bool.and(Bool.and(P.pto.in(P.pto.base.fresh(b), S.b("Text")), P.pto.in(P.pto.base.fresh(b), S.b("E1"))),
     Bool.and(Bool.not(P.pto.in(P.pto.base.fresh(b), S.b("Key"))), Bool.not(P.pto.in(P.pto.base.fresh(b), S.b("Ready")))))}]

def po.hd.checks() -> List<&2, PoCk>:
  +h = P.pto.header(S.b(po.main()))
  +hl = P.pto.header(S.b(po.lib()))
  [PoCk{"header: its imports with their aliases (Base has none), a comment line among them", po.imps.is(P.pto.hd.imps(h), ["Base", "", "./lib.bend", "L", "../net/tcp.bend", "TCP"])},
   PoCk{"header: its bytes are the lines up to the first other line", Bool.and(Nat.is_eq(P.pto.hd.n(h), S.len(S.b("import Base\n\n# the pieces\nimport ./lib.bend as L\nimport ../net/tcp.bend as TCP\n\n"))),
     Nat.is_eq(P.pto.hd.n(hl), S.len(S.b("# Inputs: a text, or another\nimport Base\n\n"))))},
   PoCk{"paths: ./ and ../ folded from the importer's directory", Bool.and(S.eq(P.pto.resolve(po.links(), S.b("r__x/src/main.bend"), S.b("./lib.bend")), S.b("r__x/src/lib.bend")),
     S.eq(P.pto.resolve(po.links(), S.b("r__x/src/main.bend"), S.b("../net/tcp.bend")), S.b("r__x/net/tcp.bend")))},
   PoCk{"paths: a sibling link read through, a hub path and Base none of the root's", Bool.and(S.eq(P.pto.resolve(po.links(), S.b("r__x/main.bend"), S.b("../Link/a/b.bend")), S.b("own__link/a/b.bend")),
     Bool.and(List.is_empty(&2, U32, P.pto.resolve(po.links(), S.b("r__x/main.bend"), S.b("0xab12/x.bend"))), List.is_empty(&2, U32, P.pto.resolve(po.links(), S.b("r__x/main.bend"), S.b("Base")))))},
   PoCk{"fresh: `_` appended until unused", Bool.and(S.eq(P.pto.fresh(S.b("Text"), P.pto.set(po.strs(["Text", "Text_"]))), S.b("Text__")), S.eq(P.pto.fresh(S.b("A"), P.pto.set(Nil{})), S.b("A_")))}]

def po.plan.checks() -> List<&2, PoCk>:
  +ps = P.pto.plans(po.mods(), po.b())
  +lib = po.nth(ps, 0n)
  +tcp = po.nth(ps, 1n)
  +main = po.nth(ps, 2n)
  +bind = po.nth(ps, 3n)
  +plain = po.nth(ps, 4n)
  [PoCk{"own: a Base type and a Base constructor renamed in the module, fresh against its own names (Text_ is a def: Text__)", Bool.and(S.eq(P.pto.plan.text(lib), S.b(po.lib.want())),
     Bool.and(po.rn.is(P.pto.plan.body(lib), ["Pair", "Pair_", "Text", "Text__"]), Nat.is_eq(P.pto.plan.own(lib), 2n)))},
   PoCk{"own: a module without a clash is its text", Bool.and(S.eq(P.pto.plan.text(tcp), S.b(po.tcp())), Bool.not(P.pto.plan.changed(tcp)))},
   PoCk{"importer: L.Pair and L.Text follow their module, L.show stays; the shadowing alias renamed with its module's names, TCP.other (Base's) kept", S.eq(P.pto.plan.text(main), S.b(po.main.want()))},
   PoCk{"importer: the renames it made", Bool.and(po.rn.is(P.pto.plan.alias(main), ["TCP", "TCP_"]), Nat.is_eq(P.pto.plan.qual(main), 3n))},
   PoCk{"binder: E1 (a constructor only the locked Base has) renamed; Ready (the older Base had it) and EK (braced) kept", Bool.and(S.eq(P.pto.plan.text(bind), S.b(po.bind.want())), Nat.is_eq(P.pto.plan.binder(bind), 1n))},
   PoCk{"importer: a module whose imports renamed nothing it uses is its text", Bool.and(S.eq(P.pto.plan.text(plain), S.b(po.plain())), Bool.not(P.pto.plan.changed(plain)))},
   PoCk{"rename: no pairs is the text byte for byte", S.eq(P.pto.rename(S.b(po.main()), Nil{}), S.b(po.main()))}]

def po.out() -> String:
  "SOME PROOFS FAIL\nError:\n- expected : U32\n- observed : Text__\nLocation: show\n12 |   match i:\n13>|     case Text__{value}: value\n   |          ^^^^\n"

def po.out.checks() -> List<&2, PoCk>:
  +inv = P.pto.rn.inv([P.PtoRn{S.b("Text"), S.b("Text__")}])
  [PoCk{"fails: the Error and Location lines, read back through the renames", po.is(P.pto.fails(S.b(po.out()), inv), ["Error:", "Location: show"])},
   PoCk{"fails: a TODO count and a Location alone (a parse error) are not a definition's", po.is(P.pto.fails(S.b("SOME PROOFS FAIL\nError: 2 TODOs found.\nLocation:\n3 | x\n"), inv), ["Error: 2 TODOs found."])},
   PoCk{"at: the error's line is the text's line 13", Bool.and(P.pto.at.self(S.b(po.out()), S.b(po.lib.want())), Bool.not(P.pto.at.self(S.b(po.out()), S.b(po.lib()))))},
   PoCk{"at: no line shown, none", Bool.not(P.pto.at.self(S.b("Error:\n- expected : x\n"), S.b(po.lib())))}]

def main() -> IO(Unit):
  po.say(List.concat(&2, PoCk, [po.decl.checks(), po.hd.checks(), po.plan.checks(), po.out.checks()]), 0n, "")
