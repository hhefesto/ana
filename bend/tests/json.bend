import Base
import ../Json.bend as J
import ../Sys.bend as S

# Json: decoding as jq -r . does (the raw-control-character case aside),
# and quoting as jq -c does.  Each line prints `ok NAME` or `FAIL NAME`.

def verdict(+name: String, ok: Bool) -> String:
  Bool.pick(String, ok, "ok ", "FAIL ") ++ name

def got(m: Maybe<&2, List<&2, U32>>, +want: List<&2, U32>) -> Bool:
  match m:
    case Some{x}:
      S.eq(x, want)
    case None{}:
      False{}

def none(m: Maybe<&2, List<&2, U32>>) -> Bool:
  match m:
    case Some{x}:
      False{}
    case None{}:
      True{}

def doc.is(m: Maybe<&2, J.Doc>, +id: List<&2, U32>, +t: List<&2, U32>) -> Bool:
  match m:
    case Some{J.Doc{i, x}}:
      Bool.and(S.eq(i, id), S.eq(x, t))
    case None{}:
      False{}

def doc.none(m: Maybe<&2, J.Doc>) -> Bool:
  match m:
    case Some{d}:
      False{}
    case None{}:
      True{}

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(verdict("escapes", got(J.string(S.b("\"a\\\"b\\\\c\\/d\\n\\t\\u00e9\\ud83d\\ude00\"")), S.b("a\"b\\c/d\n\té😀"))))
    IO.print(verdict("space", got(J.string(S.b("  \"x\" \n")), S.b("x"))))
    IO.print(verdict("trailing", none(J.string(S.b("\"x\" y")))))
    IO.print(verdict("bad-escape", none(J.string(S.b("\"\\q\"")))))
    IO.print(verdict("unpaired-high", none(J.string(S.b("\"\\ud83d\\u0041\"")))))
    IO.print(verdict("lone-low", got(J.string(S.b("\"\\ude00x\"")), S.b("\u{FFFD}x"))))
    IO.print(verdict("raw-tab", got(J.string(S.b("\"a\tb\"")), S.b("a\tb"))))
    IO.print(verdict("unclosed", none(J.string(S.b("\"abc")))))
    IO.print(verdict("quote", S.eq(J.quote(S.b("a\"\\\n\u{1}\u{7f}\t\u{8}\u{c}é")), S.b("\"a\\\"\\\\\\n\\u0001\\u007f\\t\\b\\fé\""))))
    IO.print(verdict("doc", doc.is(J.doc(S.b("{\"id\":\"a/b\",\"text\":\"x\\ny\"}")), S.b("a/b"), S.b("x\ny"))))
    IO.print(verdict("doc-order", doc.none(J.doc(S.b("{\"text\":\"x\",\"id\":\"a\"}")))))
    IO.print(verdict("doc-extra", doc.none(J.doc(S.b("{\"id\":\"a\",\"text\":\"x\",\"n\":1}")))))
    IO.print(verdict("nonul", S.eq(J.nonul(S.b("a\u{0}b\u{0}")), S.b("ab"))))
    IO.print(verdict("line", S.eq(J.line(S.b("a#r0"), S.b("x\"\n")), S.b("{\"id\":\"a#r0\",\"text\":\"x\\\"\\n\"}"))))
