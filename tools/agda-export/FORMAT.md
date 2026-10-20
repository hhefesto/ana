# agda-export's output format (version 2, Agda 2.8.0)

agda-export is Agda 2.8.0 with one more backend. It writes Agda's elaborated
definitions as S-expressions so that agda2bend, a Bend program, can translate
them into Bend 2. It makes no translation decisions: it filters, renames and
erases nothing. One kind of term is rebuilt instead of copied: parameters that
Agda's internal syntax leaves out are put back (see "Explicit and stored
terms"). This file is the contract between the two programs.

    agda-export --export-dir=OUT [--export-pretty] [--export-stored-only]
                [--export-skip-existing] [--export-copy-types] [agda's flags] FILE.agda

Run it from the root of FILE's library (the directory that holds its
`.agda-lib`), as agda is run. It type-checks FILE, loading interfaces that are
up to date, then writes the following for FILE and for every module FILE
imports, transitively (Agda.Primitive and the Agda.Builtin modules included):

- `OUT/<Top.Level.Module>.sexp`: the module's header, then one `(def ...)`
  for each definition in its signature. Each top-level expression is
  followed by a newline. A string may contain a raw newline, so a reader
  must not split the file on newlines.
- `OUT/_index.sexp`: one `(module-stats ...)` per module, then `(total ...)`.

The flake's wrapper (`nix build .#agda-export`) sets `AGDA_DIR` (unless it is
already set) to a directory whose `libraries` names standard-library 2.3 and
agda-categories 0.3.0, both with prebuilt interfaces. Flags:

- `--export-pretty` indents the output. It is still one value per
  definition and parses the same way.
- `--export-stored-only` writes every term as Agda stores it, each one
  wrapped in `noparams`.
- `--export-skip-existing` keeps a module whose `.sexp` file is already
  there. A module's file is written under a temporary name first and then
  renamed, so a file that exists is complete.
- `--export-copy-types` writes the copies a module application makes in
  full (see "Copies"); by default a copy function is written compactly.
- `AGDA_EXPORT_DEBUG=1` logs every term left in stored form, with the
  reason.

Log lines go to stderr, stamped in UTC-6.

## Lexical syntax

    sexp   ::= atom | int | string | "(" sexp* ")"
    atom   ::= [A-Za-z0-9_.-]+      (one that is all digits is an int)
    int    ::= [0-9]+               (non-negative, unbounded)
    string ::= '"' ( [^"\\] | '\"' | '\\' )* '"'

- Strings are UTF-8, and `\"` and `\\` are their only escapes. Every other
  character, newline included, stands for itself.
- List elements are separated by single spaces, or, in pretty output, by
  newlines and indentation.
- Agda names are always strings, so `"_∘_"` and `"∘-resp-≈"` need no
  escaping.
- A precedence such as `4.5`, and the `seconds` field in the index, are
  atoms.

In the grammar below, a word in capitals stands for a form defined in this
file. `X*` means zero or more, and `a|b` means one of the atoms.

## Shared pieces

    Q     ::= (q STRING W H)
    INFO  ::= HIDING RELEVANCE QUANTITY
    HIDING    ::= visible | hidden | instance
    RELEVANCE ::= relevant | irrelevant | shape-irrelevant
    QUANTITY  ::= w | q1 | q0          (q0: @0, erased)
    RANGE ::= (range FILE L C L C) | (range none)

- `Q` is a qualified name. STRING is Agda's printing of the name, such as
  `"Categories.Category.Core.Category._∘_"`; the last part is the canonical
  (original) name. `W H` is the name's NameId: a counter, and the hash of
  the top-level module that created the name. Two names can print the same
  (for example definitions in different anonymous modules `_`), but they
  never have the same NameId. Use the pair as the key and the string for
  display.
- `INFO` is written as three atoms placed directly in the enclosing list. It
  comes first in every argument, binder and domain. Cohesion, polarity,
  locks and the argument's origin are not written. They are the defaults in
  code that does not use `--cohesion`, `--polarity` or `--guarded`.
- In `RANGE`, FILE is a string or `none`. The positions count from 1, and the
  end is exclusive, as Agda keeps it.

## Module header (the first expression of a file)

    (module STRING (name STRING) (file STRING|none) (imports STRING*)
            (options STRING*) (library-options STRING*) (builtins BUILTIN*) (defs N))
    BUILTIN ::= (builtin STRING (term TERM) | (prim STRING Q) | (rewrite Q*))

- `imports` lists the modules this one imports directly.
- `options` holds the file's `OPTIONS` pragmas, and `library-options` the
  flags from its `.agda-lib`.
- `builtins` holds the BUILTIN pragmas bound in this module, such as
  `"EQUALITY"`, `"LEVEL"`, `"NATURAL"` and `"primLevelMax"`. A `term` is
  closed.
- `defs` is the number of `def` expressions that follow.

## Definitions

    (def Q
      (name STRING) (canonical STRING)      ; the concrete name here, and where it was defined
      (fixity none) | (fixity infix|infixl|infixr PREC)
      (module STRING)                       ; the module the name lives in (may be a section, e.g. "M._")
      RANGE                                 ; the name's binding site
      (lines L L) | (lines none)            ; first and last line it occupies, see below
      (kind function|data|record|constructor|postulate|primitive|other)
      (modality INFO)                       ; e.g. q0 for an @0 definition
      (flags FLAG*)                         ; copy instance injective copattern-lhs no-compilation abstract-defn
      (language without-k|with-k|cubical|erased-cubical)
      (type TYPE)
      DETAILS)

- `lines` gives the first and last line of the binding site, of the
  function's clauses, of the record's fields, or of the data type's
  constructors, counting only those in the same file. Agda's interfaces do
  not keep clause ranges (they print as `(range none)`). So a function's
  `lines` is its name's line, and a record or data type ends at its last
  field or constructor.
- The flags mean:
  - `copy`: made by module application, such as `module M = N args` or
    `open N args`;
  - `no-compilation`: one of the transp and hcomp helpers that
    `--cubical-compatible` (implied by `--without-K`) generates;
  - `copattern-lhs`: the definition matches on copatterns;
  - `abstract-defn`: Agda wrapped the definition as abstract.
- `type` is closed: no variables are in scope. It is `none` for a copy
  function written compactly (see "Copies").
- A data type's or record's `clause` (a copy's: the original applied to
  the module's arguments) is written in explicit form, as a function's
  clauses are (version 2.1; before, it was stored).

DETAILS is one of the forms below, by kind:

    (function (projection PROJ) (restored-params N) (with-of Q|none)
              (extlam none | (extlam STRING (absurd yes|no)))
              (terminates yes|no|unknown) (mutual Q* | unknown)
              (fun-flags static|inline|macro|first-order|erasure|abstract|proj ...)
              (opaque yes|no) (kan-op Q|none)
              (clauses CLAUSE*) (compiled TREE|none))
    PROJ ::= none | (proper Q|none) (orig Q) (from INFO Q) (index N) (lams (l INFO STRING)*)

    (record (pars N) (con Q) (named-con yes|no) (induction inductive|coinductive|none)
            (fields (field INFO Q)*) TEL
            (eta specified|inferred yes | specified|inferred no pattern|copattern)
            (pattern-matching pattern|copattern) (mutual ...) (abstract yes|no)
            (terminates ...) (clause CLAUSE|none))

    (data (pars N) (ixs N) (cons Q*) (sort SORT) (mutual ...) (abstract yes|no)
          (path-cons Q*) (clause CLAUSE|none))

    (constructor (data Q) (pars N) (arity N) (src-con Q) (con-kind data|record)
                 (induction ...) (fields (field INFO Q)*) (projections Q* | unknown)
                 (forced yes|no ...) (erased yes|no ... | unknown) (erasure yes|no)
                 (inline yes|no) (abstract yes|no))

    (postulate (const-transp yes|no))
    (primitive STRING (abstract ..) (opaque ..) (clauses CLAUSE*) (compiled TREE|none))
    (other "DataOrRecSig" (pars N)) | (other "GeneralizableVar" (args N|none))
          | (other "PrimitiveSort" STRING SORT)

### Functions

- `projection` is `none` for an ordinary function.
- For a record field, `proper` names the record. For a projection-like
  function (Agda's optimisation of a function whose leading arguments are
  determined by its principal argument's type), `proper` is `none`.
- `index` counts the principal argument from 1, so the function has
  index-1 parameters before it. `lams` gives the INFO and name of those
  parameters and of the principal argument.
- `restored-params` (see "Explicit and stored terms") is how many of those
  parameters this export put back into the clauses and case tree.
- `with-of` names the parent of a `with` helper. Such helpers, `where`
  helpers (in the section the clause's `where-module` names) and the
  functions behind pattern lambdas (`extlam`) are ordinary definitions of
  their module, and each has its own `def`.
- `kan-op` names the data type of a cubical transp or hcomp helper.

### Records

- `pars` counts the parameters. TEL is the telescope of the parameters
  followed by the fields, in order, each field's type in the scope of the
  parameters and the earlier fields.
- `fields` gives the field projections in order. Each field is also a
  `function` definition, whose `projection` is `proper`.
- `eta` says whether eta-equality holds, and whether the user specified it
  or Agda inferred it.
- `con` is the constructor (Agda names it `R.constructor` when the record
  declares none, in which case `named-con` is `no`).

### Data types

- `cons` lists the constructors in declaration order.
- `sort` is the data type's sort, in the scope of its parameters as Agda
  stores it. For a data type made by module application, it is the
  original's sort, in the original's parameter scope.

### Constructors

- `pars` counts the parameters of the data type or record.
- `arity` counts the constructor's own arguments.
- `src-con` is the original constructor, when this one is a copy.

## Types, terms, eliminations

    TYPE ::= (el SORT TERM)
    TERM ::= (var I STRING ELIM*)          ; de Bruijn index I, the binder's name
           | (lam INFO ABS)
           | (lit LIT)
           | (def Q ELIM*)
           | (con Q system|con|rec|split ELIM*)
           | (pi DOM ABS)                  ; ABS over a TYPE
           | (sort SORT)
           | (level LEVEL)
           | (meta W H ELIM*)
           | (dontcare TERM)               ; an irrelevant subterm
           | (dummy STRING ELIM*)
           | (noparams TERM)               ; see "Explicit and stored terms"
    ABS  ::= (abs STRING BODY) | (noabs STRING BODY)
    DOM  ::= (dom INFO STRING|none TYPE)   ; STRING: the name for {x = ...} application
    ELIM ::= (apply INFO TERM) | (proj prefix|postfix|system Q) | (iapply TERM TERM TERM)
    LEVEL ::= (max N (plus K TERM)*)       ; the maximum of N and each TERM + K
    SORT ::= (set LEVEL) | (prop LEVEL) | (sset LEVEL) | (inf set|prop|sset N)
           | (sizeuniv) | (lockuniv) | (leveluniv) | (intervaluniv)
           | (pisort (dom INFO STRING|none TERM) SORT (abs STRING SORT))
           | (funsort SORT SORT) | (univsort SORT)
           | (metas W H ELIM*) | (defs Q ELIM*) | (dummys STRING)
    LIT  ::= (nat N) | (word64 N) | (float STRING) | (string STRING) | (char N)
           | (qname Q) | (meta STRING W H)

- `(var I "x" ...)`: I counts binders outward from 0. The string is the name
  of the binder that I points at, recorded as the exporter passes it (a
  `pi`, a `lam`, a telescope entry, or a case tree's `vars`). It is only a
  hint. An index with no binder in scope has the hint `"?unbound"`; the
  index counts these, and there should be none.
- `abs` binds a variable in BODY, and `noabs` binds none (a non-dependent Pi,
  or a constant lambda).
- Eliminations apply left to right. A `def`, `con` or `var` carries every
  argument Agda has, hidden, instance and erased ones included, each with
  its INFO.
- Levels are terms like any other: `Level`, `lzero`, `lsuc` and `_⊔_`, or
  `(level ...)` in normal form. They are kept; erasing them is the
  translator's job. `(set LEVEL)` is `Set ℓ`, and `(inf set 0)` is `Setω`.
- Terms are as Agda elaborated them: implicit arguments are filled in,
  `with` and pattern lambdas are lifted to their own definitions, and
  metavariables are solved. A `meta` appears only if the source left one
  unsolved.
- `con`'s second field is where the term came from: `con` for a constructor
  the user wrote, `rec` for a record expression, `system` for one the
  system inserted.

## Telescopes, clauses, patterns

    TEL    ::= (tel (b STRING INFO STRING|none TYPE)*) | (noparams TEL)
    CLAUSE ::= (clause RANGE TEL (pats PAT*) (body TERM|absurd)
                       (type (of INFO TYPE) | none) (catchall yes|no)
                       (unreachable yes|no|unknown) (recursive yes|no|unknown)
                       (where-module STRING|none))
    PAT    ::= (p INFO STRING|none PATTERN)          ; STRING: the argument's name
    PATTERN ::= (pvar STRING I ORIGIN)               ; I: index into the clause's TEL
              | (pdot ORIGIN TERM)
              | (pcon Q ORIGIN (record yes|no) (lazy yes|no) (fallthrough yes|no)
                      (type INFO TYPE | none) PAT*)  ; type: the pattern's own type
              | (plit ORIGIN LIT)
              | (pproj prefix|postfix|system Q)      ; a copattern
              | (piapply ORIGIN TERM TERM STRING I)
              | (pdef ORIGIN Q PAT*)                 ; cubical (hcomp, transp) only
    ORIGIN ::= system | split | split-arg | var | dot | wild | con | rec | lit | absurd

- A TEL binding's TYPE is in the scope of the earlier bindings.
- A clause's TEL binds its pattern variables in dependency order. Its
  patterns, its body and its `type` (the type of the right-hand side) are in
  the scope of the whole TEL, the last binding being index 0.
- A pattern variable's I is its de Bruijn index in TEL. The terms inside dot
  patterns and the pattern types are in TEL's scope too.
- An absurd pattern is a `pvar` with origin `absurd`, and its clause's body
  is `absurd`.
- Agda keeps the clauses that `--cubical-compatible` generates, which match
  on `pdef` or `piapply`, next to the user's own.
- Clause bodies are written in explicit form. The patterns, including the
  terms inside them, are written as Agda stores them.

## Case trees (`compiled`)

    TREE ::= (case INFO N BRANCHES) | (done (vars X*) TERM) | (fail (vars X*)) | (noparams TREE)
    X    ::= (x INFO STRING)
    BRANCHES ::= (branches (copattern yes|no)
                           (cons (br Q ARITY TREE)*)
                           (eta none | Q ARITY TREE)
                           (lits (lbr LIT TREE)*)
                           (catchall TREE|none)
                           (fallthrough yes|no|none)
                           (lazy yes|no))

This is Agda's funCompiled, the compiled pattern match:

- The tree works on a list of arguments. At the root, that list is the
  function's arguments in order.
- `(case INFO N ...)` matches on argument N, counting from 0.
- A `cons` branch for a constructor of arity k replaces argument N with the
  constructor's k fields, so later indices count in the new list.
- `eta` is the same, for the one constructor of an eta record.
- A `lits` branch matches a literal and removes argument N.
- `catchall` is taken when no other branch matches.
- With `(copattern yes)`, N is the number of arguments so far, and each
  `br` names a projection, with arity 0, that the result is observed
  through. A definition by a record expression (`f = record { ... }`) is
  compiled this way, one branch per field.
- `(done (vars ...) TERM)`: TERM is in the scope of the vars, the last one
  being index 0.
- `fail` is an absurd leaf.

## Explicit and stored terms

Agda's internal syntax leaves out two kinds of arguments that its type
checker can recover, but that Bend must be given:

- **Projections.** A field is written as a postfix elimination
  `(var 0 "r" (proj ... Category._∘_) ...)`, without the record's parameters.
- **Projection-like functions.** These are written without their leading
  parameters, and their clauses and case trees are written without the
  patterns for them.

The exporter puts these arguments back:

- It re-checks each type, telescope, clause body and clause type with
  Agda's internal checker (CheckInternal).
- It runs a copy of Agda's own `reconstructParameters` with one change:
  constructors are left as stored.
- Each projection becomes `(def P PARAMS... PRINCIPAL REST...)`, where P is
  the projection or projection-like function, PARAMS are its index-1
  parameters, and PRINCIPAL is the record or data value. A projection-like
  function applied to a constructor reduces, as Agda's `elimView` does.
- The clauses of a projection or projection-like function get their dropped
  parameters back as `pvar` patterns with origin `system`, bound to the TEL
  variables no pattern binds. `restored-params` counts them.
- The case tree is recompiled from the explicit clauses with Agda's clause
  compiler and the stored split tree, as Agda's backends recompile it.

Where the reconstruction fails, the stored form is written inside
`(noparams X)`. In stored form, a projection is a `proj` elimination,
projection-like functions lack their parameters, and the case tree lacks
restored-params arguments. A case tree is written explicit when its
recompiled shape (indices, branches, vars) equals the stored tree's. A
leaf whose clause body stayed stored is `(done (vars ...) (noparams TERM))`.
If the shapes differ, the whole stored tree is wrapped as
`(compiled (noparams TREE))`.

Throughout the export, in explicit and stored form alike, constructor
applications carry only the constructor's own arguments, never the data
type's parameters (`pars` in the constructor's definition says how many
those are). Sorts (the SORT of an `el`) are not re-checked. A `proj`
elimination inside a sort is counted as `residual-proj` in the index.

Where reconstruction is known to fail:

- the transp and hcomp helpers (`no-compilation`), and the clauses that
  `--cubical-compatible` generates, whose interval types do not re-check
  outside cubical Agda;
- copies of record projections made by module application, whose stored
  body is a lambda over the principal argument alone.

The index counts each of these failures by reason.

## Copies (version 2)

A module application (`open M args`, `module N = M args`, a record module
opened on a value) makes a copy of each definition of M: flag `copy`. A
copy function is the original applied to the module's arguments, and its
case tree says so: `(done (vars X*) (def ORIGINAL ARGS... VARS...))`. Its
type and clauses are the original's with the arguments substituted at every
occurrence of a parameter, written out in full: in agda-categories they were
99% of some modules (Categories.Category.Monoidal.Closed: 86 MB, 155 of its
167 definitions copies), and the version 1 export of the library ran out of
a 10 GB heap on them.

So by default a copy function is written with `(type none)` and
`(clauses)` empty; its case tree is written as for any function. A reader
inlines the tree where the copy is used: `(def COPY ES...)` is the leaf's
term with the vars bound to ES. Copies of data types, records and
constructors are written in full (they are few and small).
`--export-copy-types` writes copy functions in full as version 1 did.

## The index (`_index.sexp`)

    (module-stats STRING (skipped yes|no) (defs N) (bytes N) (seconds ATOM)
                  (kinds (KIND N)*) (explicit N) (stored N) (trees-explicit N) (trees-stored N)
                  (residual-proj N) (unbound N) (reasons (reason STRING N)*))
    (total (modules N) (skipped N) (defs N) (bytes N) (kinds ...) (explicit N) (stored N)
           (trees-explicit N) (trees-stored N) (residual-proj N) (unbound N) (reasons ...))

- `explicit` and `stored` count types, telescopes, clause bodies and clause
  types.
- `trees-explicit` and `trees-stored` count case trees.
- A reason prefixed `no-compilation:` comes from a cubical helper
  definition, and one prefixed `cubical clause:` from a generated cubical
  clause.
