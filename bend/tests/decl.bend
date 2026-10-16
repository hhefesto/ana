import Base
import ../Sys.bend as S
import ../Sha256.bend as H
import ../Check/Lib.bend as Cl
import ../CorpusV2/Lib.bend as L
import ../CorpusV2/Decl.bend as D

# bend-corpus-v2 decl-new (bend/CorpusV2/Decl.bend, 2026-10-16): a new wave's
# units less what the corpus trains on or holds out.  The pure parts against
# their meaning: a unit's file is its id before `#`, its file's text is fields
# 5 to 8 joined (the file byte for byte), its declaration is sha256(language
# NUL signature NUL body), the held=/seen= words.  Then the whole tool on units
# written here, one a rule: a held-out repository and a listed path (a V2
# holdout written here), a held source file's own id, another file with a held
# file's text, a text whose key the holdout lists, a held unit's declaration in
# another file, a seen unit's declaration, a declaration twice (the first
# kept), two kept units of one file; OUT is exactly the kept pairs in order,
# OUT.dropped each dropped id with its reason, the stats every count, a
# second run the same bytes, and no held or seen file a dropped unit.  Each
# check prints `ok NAME` or `FAIL NAME`; any FAIL exits 1.

type DcCk is Data:
  DcCk{name: String, ok: Bool}

def dt.end(ok: Bool, +bad: Nat, +names: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "decl: " ++ Nat.show(bad) ++ " check(s) failed:" ++ names)

def dt.say(cs: List<&2, DcCk>, +bad: Nat, +names: String) -> IO(Unit):
  match cs:
    case Nil{}:
      dt.end(Nat.is_eq(bad, 0n), bad, names)
    case DcCk{+n, +ok} <> t:
      do IO<Unit>:
        IO.print(Bool.pick(String, ok, "ok ", "FAIL ") ++ n)
        dt.say(t, Bool.pick(Nat, ok, bad, 1n+bad), Bool.pick(String, ok, names, names ++ " " ++ n))

# a unit's record: lang, kind, name, doc, sig, head, pre, body, tail, names,
# hole, then a mutant (fields joined by 0x1E)
def dt.rec(+sig: String, +head: String, +pre: String, +body: String, +tail: String) -> List<&2, U32>:
  S.join([S.b("bend"), S.b("type"), S.b("f"), Nil{}, S.b(sig), S.b(head), S.b(pre), S.b(body), S.b(tail), S.b("x"), S.b("?goal"), S.b("  0\n")], 30)

def dt.pair(+id: String, +rec: List<&2, U32>) -> List<&2, U32>:
  L.v2.concat([S.b(id), [0], rec, [0]])

# The pure parts -----------------------------------------------------------------

def dt.args.is(a: D.DclArgs) -> Bool:
  match a:
    case D.DclArgs{+h, +s, +b}:
      Bool.and(Bool.and(S.eq(S.b(String.concat(h)), S.b("a.nulb.jsonl")), S.eq(S.b(String.concat(s)), S.b("s.nul"))),
        S.eq(S.b(String.concat(b)), S.b("x=1")))

def dt.pure() -> List<&2, DcCk>:
  +r = dt.rec("def f() -> U32:", "import Base\n\n", "def f() -> U32:\n", "  1\n", "\ndef g() -> U32:\n  2\n")
  [DcCk{"file: the id before `#`", Bool.and(S.eq(D.dcl.file(S.b("repo:a__b/c/d.bend#f@3")), S.b("repo:a__b/c/d.bend")),
     S.eq(D.dcl.file(S.b("repo:a/x.bend")), S.b("repo:a/x.bend")))},
   DcCk{"text: head, pre, body and tail joined (the file)", S.eq(D.dcl.text(r), S.b("import Base\n\ndef f() -> U32:\n  1\n\ndef g() -> U32:\n  2\n"))},
   DcCk{"decl: sha256 of language NUL signature NUL body", String.eq(D.dcl.decl(r), H.sha256(S.b("bend\u{0}def f() -> U32:\u{0}  1\n")))},
   DcCk{"decl: the head and tail do not count", String.eq(D.dcl.decl(r), D.dcl.decl(dt.rec("def f() -> U32:", "", "def f() -> U32:\n", "  1\n", "")))},
   DcCk{"tkey: the last key for the same file, else the text's", Bool.and(String.eq(D.dcl.tkey(True{}, "k", r), "k"),
     String.eq(D.dcl.tkey(False{}, "k", r), L.v2.key(D.dcl.text(r))))},
   DcCk{"reasons: the codes' names", String.eq(String.concat([D.dcl.reason(0n), D.dcl.reason(1n), D.dcl.reason(2n), D.dcl.reason(3n), D.dcl.reason(4n), D.dcl.reason(5n), D.dcl.reason(6n)]),
     "keptv2-heldheld-fileheld-textheld-declseendup")},
   DcCk{"args: held= and seen= in the order given, anything else refused", dt.args.is(D.dcl.args(["held=a.nul", "seen=s.nul", "held=b.jsonl", "x=1"]))}]

# The tool on files ----------------------------------------------------------------------

# the bodies: each unit's own declaration
def dt.u(+sig: String, +body: String) -> List<&2, U32>:
  dt.rec(sig, "import Base\n\n", sig ++ "\n", body, "")

# the vault's source file (held .jsonl), and its text
def dt.vault.text() -> String:
  "import Base\n\ndef v() -> U32:\n  7\n"

def dt.held.jsonl() -> String:
  "{\"id\": \"repo:o__vaultrepo/v.bend\", \"text\": \"import Base\\n\\ndef v() -> U32:\\n  7\\n\"}\nnot a record\n"

# the text whose content key the V2 holdout lists
def dt.listed.text() -> String:
  "import Base\n\ndef e() -> U32:\n  5\n"

def dt.held.units() -> List<&2, U32>:
  dt.pair("repo:o__horepo/h.bend#hd@3", dt.u("def hd() -> U32:", "  42\n"))

def dt.seen.units() -> List<&2, U32>:
  L.v2.concat([dt.pair("repo:o__old/s.bend#sd@3", dt.u("def sd() -> U32:", "  9\n")), dt.pair("repo:o__old/s.bend#se@5", dt.u("def se() -> U32:", "  10\n"))])

# kept 1 and kept 2 share a file (its content key reused), the dup repeats kept 1's declaration
def dt.k1() -> List<&2, U32>:
  dt.pair("repo:p__new/k.bend#k1@3", dt.u("def k1() -> U32:", "  1\n"))

def dt.k2() -> List<&2, U32>:
  dt.pair("repo:p__new/k.bend#k2@5", dt.u("def k2() -> U32:", "  2\n"))

def dt.units() -> List<&2, U32>:
  L.v2.concat([
    dt.pair("repo:x__heldrepo/a.bend#a@3", dt.u("def a() -> U32:", "  1\n")),
    dt.pair("repo:x__pathrepo/sub/P.bend#b@3", dt.u("def b() -> U32:", "  2\n")),
    dt.pair("repo:o__vaultrepo/v.bend#v@3", dt.u("def v() -> U32:", "  7\n")),
    dt.pair("repo:y__copy/c.bend#v@3", dt.rec("def v() -> U32:", "import Base\n\n", "def v() -> U32:\n", "  7\n", "")),
    dt.pair("repo:z__z/e.bend#e@3", dt.rec("def e() -> U32:", "import Base\n\n", "def e() -> U32:\n", "  5\n", "")),
    dt.pair("repo:q__q/h2.bend#hd@3", dt.rec("def hd() -> U32:", "import Base\n\n", "def hd() -> U32:\n", "  42\n", "\ndef w() -> U32:\n  0\n")),
    dt.pair("repo:q__q/s2.bend#sd@3", dt.rec("def sd() -> U32:", "import Base\n\n", "def sd() -> U32:\n", "  9\n", "\ndef w2() -> U32:\n  0\n")),
    dt.k1(),
    dt.pair("repo:p__other/d.bend#k1@3", dt.rec("def k1() -> U32:", "import Base\n# another file\n\n", "def k1() -> U32:\n", "  1\n", "")),
    dt.k2()])

def dt.dropped() -> String:
  "v2-held\trepo:x__heldrepo/a.bend#a@3\nv2-held\trepo:x__pathrepo/sub/P.bend#b@3\nheld-file\trepo:o__vaultrepo/v.bend#v@3\nheld-text\trepo:y__copy/c.bend#v@3\nheld-text\trepo:z__z/e.bend#e@3\nheld-decl\trepo:q__q/h2.bend#hd@3\nseen\trepo:q__q/s2.bend#sd@3\ndup\trepo:p__other/d.bend#k1@3\n"

def dt.stats() -> String:
  "dup 1\nheld-decl 1\nheld-file 1\nheld-text 2\nkept 2\nseen 1\nunits 10\nv2-held 2\n"

def dt.v2(+dir: String) -> IO(Unit):
  do IO<Unit>:
    S.mkdir(dir ++ "/v2")
    S.write(dir ++ "/v2/units.tsv", S.b("unit\tlang\n" ++ "heldrepo\tbend\n"))
    S.write(dir ++ "/v2/exclude.paths", S.b("pathrepo\tsub/P.bend\n"))
    S.write(dir ++ "/v2/exclude.sha256", S.b(L.v2.key(S.b(dt.listed.text())) ++ "\n"))

def dt.run(+dir: String, +out: String) -> IO(List<&2, Cl.Stat>):
  D.dcl.run(dir ++ "/units.nul", out, [dir ++ "/held.jsonl", dir ++ "/held.nul"], [dir ++ "/seen.nul"], dir ++ "/v2")

def dt.io(+dir: String) -> IO(List<&2, DcCk>):
  do IO<List<&2, DcCk>>:
    dt.v2(dir)
    S.write(dir ++ "/held.jsonl", S.b(dt.held.jsonl()))
    S.write(dir ++ "/held.nul", dt.held.units())
    S.write(dir ++ "/seen.nul", dt.seen.units())
    S.write(dir ++ "/units.nul", dt.units())
    +st : List<&2, Cl.Stat> <- dt.run(dir, dir ++ "/out.nul")
    +o : List<&2, U32> <- S.read(dir ++ "/out.nul")
    +dr : List<&2, U32> <- S.read(dir ++ "/out.nul.dropped")
    +sf : List<&2, U32> <- S.read(dir ++ "/out.nul.stats")
    tmp : Bool <- S.exists(dir ++ "/out.nul.tmp")
    st2 : List<&2, Cl.Stat> <- dt.run(dir, dir ++ "/again.nul")
    +o2 : List<&2, U32> <- S.read(dir ++ "/again.nul")
    +d2 : List<&2, U32> <- S.read(dir ++ "/again.nul.dropped")
    st3 : List<&2, Cl.Stat> <- D.dcl.run(dir ++ "/units.nul", dir ++ "/none.nul", Nil{}, Nil{}, dir ++ "/v2")
    +o3 : List<&2, U32> <- S.read(dir ++ "/none.nul")
    st4 : List<&2, Cl.Stat> <- D.dcl.run(dir ++ "/out.nul", dir ++ "/self.nul", Nil{}, [dir ++ "/out.nul"], dir ++ "/v2")
    +o4 : List<&2, U32> <- S.read(dir ++ "/self.nul")
    return [DcCk{"tool: OUT is the kept pairs as they stand, in UNITS' order", S.eq(o, L.v2.concat([dt.k1(), dt.k2()]))},
      DcCk{"tool: OUT.dropped names each dropped unit with the first rule that holds", S.eq(dr, S.b(dt.dropped()))},
      DcCk{"tool: OUT.stats counts every rule, kept and units, in byte order", S.eq(sf, S.b(dt.stats()))},
      DcCk{"tool: the stats it answers are the file's", String.eq(Cl.stat.show(st), dt.stats())},
      DcCk{"tool: OUT.tmp is moved into place", Bool.not(tmp)},
      DcCk{"tool: a second run writes the same bytes", Bool.and(S.eq(o2, o), S.eq(d2, dr))},
      DcCk{"tool: with no held or seen file only the v2 holdout, the listed text and the duplicates go (the copy of v is a duplicate now)",
        S.eq(o3, L.v2.concat([dt.pair("repo:o__vaultrepo/v.bend#v@3", dt.u("def v() -> U32:", "  7\n")),
          dt.pair("repo:q__q/h2.bend#hd@3", dt.rec("def hd() -> U32:", "import Base\n\n", "def hd() -> U32:\n", "  42\n", "\ndef w() -> U32:\n  0\n")),
          dt.pair("repo:q__q/s2.bend#sd@3", dt.rec("def sd() -> U32:", "import Base\n\n", "def sd() -> U32:\n", "  9\n", "\ndef w2() -> U32:\n  0\n")),
          dt.k1(), dt.k2()]))},
      DcCk{"tool: OUT seen against itself keeps nothing", Bool.and(Nat.is_eq(S.len(o4), 0n), String.eq(Cl.stat.show(st4), "dup 0\nheld-decl 0\nheld-file 0\nheld-text 0\nkept 0\nseen 2\nunits 2\nv2-held 0\n"))},
      DcCk{"tool: a second run answers the same stats (a held .jsonl line that is no record is passed over)", String.eq(Cl.stat.show(st2), dt.stats())}]

def main() -> IO(Unit):
  do IO<Unit>:
    +dir : String <- S.mktemp()
    io : List<&2, DcCk> <- dt.io(dir)
    S.rm(dir)
    dt.say(List.append(&2, DcCk, dt.pure(), io), 0n, "")
