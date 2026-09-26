import Base
import ./Sys.bend as S
import ./Json.bend as J

# bend-code-evals: per-language evaluation corpora from held-out repositories.
#
#   bend-code-evals TOKENIZER.bpe OUT_DIR [EVAL.jsonl]
#
# The sources here were held out WHOLE by extract-code.sh, chosen by a hash of
# the package or repository name. That matters: the trainer's own
# train/validation split is a hash of document position, and code vendors
# heavily, so a position-based split puts the same file on both sides.
# Nothing in these corpora comes from a package the model trained on.
#
# Corpora are packed exactly as the training corpus is, because bpb has to be
# measured on the distribution the model actually sees. Unpacked, short files
# yield no window at all and the population silently becomes "long files
# only".
#
# EVAL (default run/code-eval.jsonl) is JSON lines, `{"id": ..., "text": ...}`
# in that order. One pass sorts its documents by language into
# OUT_DIR/.LANG.nul (id, text without NULs: jq's
# `explode | map(select(. != 0)) | implode`); then, a language at a time,
# bend-pack (--target PACK_TARGET, default 131072, --group: a packed document
# stays inside one repository, so a window never spans two unrelated
# projects) and bend-prepare write OUT_DIR/code-LANG.corpus (through a .tmp,
# renamed once complete). The tools are BEND_PACK and BEND_PREPARE, else
# bend-pack and bend-prepare in BEND_TOOLS, else on PATH.

# Languages ---------------------------------------------------------------------

def ends(+id: List<&2, U32>, s: String) -> Bool:
  S.suffix(id, S.b(s))

# Extension groups, not individual extensions: literate variants are the same
# language and would otherwise make populations too small to measure with.
# 1 haskell `\.(hs|lhs)$`, 2 nix `\.nix$`, 3 agda `\.(agda|lagda)$`, 4 lean
# `\.lean$`, 5 idris `\.(idr|ipkg)$`, 0 none
def lang.of(+id: List<&2, U32>) -> Nat:
  Bool.pick(Nat, Bool.or(ends(id, ".hs"), ends(id, ".lhs")), 1n,
    Bool.pick(Nat, ends(id, ".nix"), 2n,
      Bool.pick(Nat, Bool.or(ends(id, ".agda"), ends(id, ".lagda")), 3n,
        Bool.pick(Nat, ends(id, ".lean"), 4n,
          Bool.pick(Nat, Bool.or(ends(id, ".idr"), ends(id, ".ipkg")), 5n, 0n)))))

def name.of(k: Nat) -> String:
  match k:
    case 1n:
      "haskell"
    case 2n:
      "nix"
    case 3n:
      "agda"
    case 4n:
      "lean"
    case 5n:
      "idris"
    case _:
      ""

# The split: one pass over EVAL --------------------------------------------------

# the open .LANG.nul files
type Fs is Type:
  Fs{h: File, n: File, a: File, l: File, i: File}

def fs.put(k: Nat, fs: Fs, xs: List<&2, U32>) -> IO(Fs):
  match k fs:
    case 1n Fs{h, n, a, l, i}:
      do IO<Fs>:
        h2 : File <- S.emit(h, xs)
        return Fs{h2, n, a, l, i}
    case 2n Fs{h, n, a, l, i}:
      do IO<Fs>:
        n2 : File <- S.emit(n, xs)
        return Fs{h, n2, a, l, i}
    case 3n Fs{h, n, a, l, i}:
      do IO<Fs>:
        a2 : File <- S.emit(a, xs)
        return Fs{h, n, a2, l, i}
    case 4n Fs{h, n, a, l, i}:
      do IO<Fs>:
        l2 : File <- S.emit(l, xs)
        return Fs{h, n, a, l2, i}
    case 5n Fs{h, n, a, l, i}:
      do IO<Fs>:
        i2 : File <- S.emit(i, xs)
        return Fs{h, n, a, l, i2}
    case _ Fs{h, n, a, l, i}:
      IO.pure(Fs, Fs{h, n, a, l, i})

def fs.close(fs: Fs) -> IO(Unit):
  match fs:
    case Fs{h, n, a, l, i}:
      do IO<Unit>:
        File.close(h)
        File.close(n)
        File.close(a)
        File.close(l)
        File.close(i)

def fs.open(+dir: String) -> IO(Fs):
  do IO<Fs>:
    h : File <- IO.try(File, File.open(dir ++ "/.haskell.nul", "w"))
    n : File <- IO.try(File, File.open(dir ++ "/.nix.nul", "w"))
    a : File <- IO.try(File, File.open(dir ++ "/.agda.nul", "w"))
    l : File <- IO.try(File, File.open(dir ++ "/.lean.nul", "w"))
    i : File <- IO.try(File, File.open(dir ++ "/.idris.nul", "w"))
    return Fs{h, n, a, l, i}

# the documents of each language
type Cn is Data:
  Cn{h: Nat, n: Nat, a: Nat, l: Nat, i: Nat}

def cn.bump(k: Nat, c: Cn) -> Cn:
  match k c:
    case 1n Cn{h, n, a, l, i}:
      Cn{1n+h, n, a, l, i}
    case 2n Cn{h, n, a, l, i}:
      Cn{h, 1n+n, a, l, i}
    case 3n Cn{h, n, a, l, i}:
      Cn{h, n, 1n+a, l, i}
    case 4n Cn{h, n, a, l, i}:
      Cn{h, n, a, 1n+l, i}
    case 5n Cn{h, n, a, l, i}:
      Cn{h, n, a, l, 1n+i}
    case _ Cn{h, n, a, l, i}:
      Cn{h, n, a, l, i}

def cn.of(k: Nat, c: Cn) -> Nat:
  match k c:
    case 1n Cn{h, n, a, l, i}:
      h
    case 2n Cn{h, n, a, l, i}:
      n
    case 3n Cn{h, n, a, l, i}:
      a
    case 4n Cn{h, n, a, l, i}:
      l
    case 5n Cn{h, n, a, l, i}:
      i
    case _ Cn{h, n, a, l, i}:
      0n

def blank(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +h <> t:
      Bool.and(J.ws(h), blank(t))

# a line: a document, a blank line (jq reads past it), or neither
type Ln is Data:
  Doc{k: Nat, bytes: List<&2, U32>}
  Blank{}
  Bad{}

def ln.doc(m: Maybe<&2, J.Doc>, +line: List<&2, U32>) -> Ln:
  match m:
    case Some{J.Doc{+id, t}}:
      Doc{lang.of(id), List.append(&2, U32, id, 0 <> List.append(&2, U32, J.nonul(t), [0]))}
    case None{}:
      Bool.pick(Ln, blank(line), Blank{}, Bad{})

def ln.of(+line: List<&2, U32>) -> Ln:
  ln.doc(J.doc(line), line)

type Ev is Type:
  Ev{rd: S.Rd, fs: Fs, cn: Cn, line: Nat, go: Bool}

def ev.put(+eval: String, rd: S.Rd, fs: Fs, cn: Cn, +l: Nat, x: Ln) -> IO(Ev):
  match x:
    case Doc{+k, b}:
      do IO<Ev>:
        f2 : Fs <- fs.put(k, fs, b)
        return Ev{rd, f2, cn.bump(k, cn), 1n+l, True{}}
    case Blank{}:
      IO.pure(Ev, Ev{rd, fs, cn, 1n+l, True{}})
    case Bad{}:
      do IO<Ev>:
        S.Rd.close(rd)
        fs.close(fs)
        IO.die(Ev, 1, "build-code-evals: line " ++ Nat.show(1n+l) ++ " of " ++ eval ++ " is not an {\"id\", \"text\"} object")

def ev.got(+eval: String, rd: S.Rd, fs: Fs, cn: Cn, +l: Nat, m: Maybe<&2, List<&2, U32>>) -> IO(Ev):
  match m:
    case None{}:
      IO.pure(Ev, Ev{rd, fs, cn, l, False{}})
    case Some{+x}:
      ev.put(eval, rd, fs, cn, l, ln.of(x))

def ev.pair(+eval: String, fs: Fs, cn: Cn, +l: Nat, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Ev):
  (rd, m) = r
  ev.got(eval, rd, fs, cn, l, m)

def ev.step(+eval: String, e: Ev) -> IO(Ev):
  match e:
    case Ev{rd, fs, cn, +l, g}:
      do IO<Ev>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        ev.pair(eval, fs, cn, l, r)

def ev.go(fuel: Nat, +eval: String, e: Ev) -> IO(Cn):
  match fuel e:
    case 1n+p Ev{rd, fs, cn, l, True{}}:
      IO.bind(Ev, Cn, ev.step(eval, Ev{rd, fs, cn, l, True{}}), ev.go(p, eval))
    case _ Ev{rd, fs, cn, l, g}:
      do IO<Cn>:
        S.Rd.close(rd)
        fs.close(fs)
        return cn

def big() -> Nat:
  1000000000n

def split(+eval: String, +dir: String) -> IO(Cn):
  do IO<Cn>:
    rd : S.Rd <- S.Rd.lines(eval)
    fs : Fs <- fs.open(dir)
    ev.go(big(), eval, Ev{rd, fs, Cn{0n, 0n, 0n, 0n, 0n}, 0n, True{}})

# A language: pack, prepare, report ------------------------------------------

def spaces(n: Nat) -> String:
  match n:
    case 0n:
      ""
    case 1n+k:
      " " ++ spaces(k)

# printf's %-Ns and %Ns (widths in bytes)
def pad.r(+s: String, +w: Nat) -> String:
  s ++ spaces(Nat.sub(w, S.len(S.b(s))))

def pad.l(+s: String, +w: Nat) -> String:
  spaces(Nat.sub(w, S.len(S.b(s)))) ++ s

# the value of the `ordinary tokens: N` line (empty: none)
def tokens.of(ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      Bool.pick(List<&2, U32>, S.prefix(l, S.b("ordinary tokens: ")), S.strip(l, S.b("ordinary tokens: ")), tokens.of(more))

# whatever a tool said, on stderr
def said(+xs: List<&2, U32>) -> IO(Unit):
  Bool.pick(IO(Unit), Nat.is_eq(S.len(xs), 0n), IO.pure(Unit, Unit{}), IO.print_err(S.str(S.chomp(xs))))

def prepared(+name: String, +n: Nat, +corpus: String, +packed: String, o: S.Out) -> IO(Unit):
  match o:
    case S.Out{+st, +t}:
      Bool.pick(IO(Unit), U32.is_eq(st, 0),
        do IO<Unit>:
          S.rm(packed)
          S.mv(corpus ++ ".tmp", corpus)
          IO.print_err("build-code-evals: " ++ pad.r(name, 8n) ++ " " ++ pad.l(Nat.show(n), 6n) ++ " held-out files -> "
            ++ pad.l(S.str(tokens.of(S.split.lines(t))), 9n) ++ " tokens  " ++ corpus),
        IO.die(Unit, 1, "build-code-evals: " ++ name ++ " failed to prepare\n  " ++ S.str(S.chomp(t))))

def packed(+name: String, +n: Nat, +dir: String, +tok: String, +prep: String, o: S.Out) -> IO(Unit):
  match o:
    case S.Out{+st, +t}:
      +nul = dir ++ "/." ++ name ++ ".nul"
      +pk = dir ++ "/." ++ name ++ ".packed.nul"
      +corpus = dir ++ "/code-" ++ name ++ ".corpus"
      Bool.pick(IO(Unit), U32.is_eq(st, 0),
        do IO<Unit>:
          said(t)
          S.rm(nul)
          +p : S.Out <- S.run(".", [], 2000000, prep, ["--threads", "1", tok, pk, corpus ++ ".tmp"], Nil{})
          prepared(name, n, corpus, pk, p),
        do IO<Unit>:
          said(t)
          IO.die(Unit, st, "build-code-evals: " ++ name ++ ": bend-pack failed (exit " ++ U32.show(st) ++ ")"))

def lang.run(+k: Nat, n: Nat, +dir: String, +tok: String, +pack: String, +prep: String, +target: String) -> IO(Unit):
  match n:
    case 0n:
      do IO<Unit>:
        S.rm(dir ++ "/." ++ name.of(k) ++ ".nul")
        IO.print_err("build-code-evals: " ++ name.of(k) ++ " -- no held-out documents, skipped")
    case 1n+m:
      +name = name.of(k)
      do IO<Unit>:
        +o : S.Out <- S.run(".", [], 2000000, pack, ["--threads", "1", dir ++ "/." ++ name ++ ".nul", dir ++ "/." ++ name ++ ".packed.nul", "--target", target, "--prefix", "eval-" ++ name, "--group"], Nil{})
        packed(name, 1n+m, dir, tok, prep, o)

def langs.go(k: Nat, +cn: Cn, +dir: String, +tok: String, +pack: String, +prep: String, +target: String) -> IO(Unit):
  match k:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+(+j):
      do IO<Unit>:
        langs.go(j, cn, dir, tok, pack, prep, target)
        lang.run(1n+j, cn.of(1n+j, cn), dir, tok, pack, prep, target)

# The driver --------------------------------------------------------------------

def tool.of(+dir: String, +name: String) -> String:
  Bool.pick(String, String.is_empty(dir), name, dir ++ "/" ++ name)

def need(ok: Bool, +msg: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, msg)

def build(+tok: String, +dir: String, +eval: String) -> IO(Unit):
  do IO<Unit>:
    +bt : String <- S.env("BEND_TOOLS", "")
    +pack : String <- S.env("BEND_PACK", tool.of(bt, "bend-pack"))
    +prep : String <- S.env("BEND_PREPARE", tool.of(bt, "bend-prepare"))
    +target : String <- S.env("PACK_TARGET", "131072")
    +tt : Bool <- S.exists(tok)
    need(tt, "build-code-evals: no such tokenizer: " ++ tok)
    +et : Bool <- S.exists(eval)
    need(et, "build-code-evals: no such holdout: " ++ eval)
    S.mkdir(dir)
    +cn : Cn <- split(eval, dir)
    langs.go(5n, cn, dir, tok, pack, prep, target)
    f : S.Out <- S.run(".", [], 600, "find", [dir, "-mindepth", "1", "-maxdepth", "1", "-name", "code-*.corpus"], Nil{})
    IO.print_err("build-code-evals: wrote " ++ Nat.show(List.length(&2, List<&2, U32>, S.split.lines(S.Out.text(f)))) ++ " corpora to " ++ dir)

def args.go(xs: List<String>) -> IO(Unit):
  match xs:
    case +t <> +o <> Nil{}:
      build(t, o, "run/code-eval.jsonl")
    case +t <> +o <> +e <> Nil{}:
      build(t, o, e)
    case _:
      IO.die(Unit, 2, "usage: bend-code-evals TOKENIZER.bpe OUT_DIR [EVAL.jsonl]")

def main() -> IO(Unit):
  do IO<Unit>:
    xs : List<String> <- IO.args()
    args.go(xs)
