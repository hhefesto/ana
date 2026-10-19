import Base
import ../Sys.bend as S
import ../ToBend/Sexp.bend as X

# Ast: the parser of Agda.  agda2bend reads Agda after Agda has elaborated
# it: agda-export writes every definition as an S-expression of Agda's
# internal syntax, with every implicit argument filled in
# (tools/agda-export/FORMAT.md is the grammar), Sexp.bend reads the
# S-expression, and this module decodes it into `Ag`, the Agda syntax tree
# the translation (Cata.bend) folds over.  It decides nothing: names,
# levels, erasure and the Bend encoding are the later passes' job.
#
# The source text is not parsed: Agda leaves most arguments out of the
# source (the category, objects and morphisms of `id-comm = trans identityʳ
# (sym identityˡ)`) and only Agda's elaborator knows them, while Bend infers
# almost nothing, so the translation needs the elaborated form.
#
# Two steps.  `aas.x` turns the S-expression into `AgX`, the same tree with
# every keyword atom (`var`, `apply`, `hidden`, ...) replaced by its
# constructor in `AgKw`: an atom is classified once, by a 32-bit hash
# (h = 31*h + byte, wrapping) and one U32 `match`, with no two of the 173
# keywords sharing a hash (tests/agda2bend.bend checks each).  Then
# `aas.dec(x, c)` decodes x as grammar category c by pattern matching alone.
# Bend matches only on parameters and pattern-bound variables, allows no
# mutual recursion, and sees termination only on pattern-bound parts, so
# the whole grammar is one def over one type, and every recursive call is
# on a part of x its pattern bound.  A form the grammar does not know (the
# cubical ones) is kept as `AgRaw` with its category, so decoding is total.
#
# `Ag` is one type for every category (terms, eliminations, sorts, levels,
# telescopes, clauses, patterns, case trees, name lists) for the same
# reason: a pass over it is one def.  Lists are spines: each element
# constructor carries the rest of its list, and a list ends in its own
# end constructor.  Every def is prefixed `aas.`; every type and
# constructor `Ag`, `Ax` or `Ak`.

# The keywords of FORMAT.md, one constructor each (`where-module` is
# AkWhereModule), and AkWord for any other word.
type AgKw is Data:
  AkW{}
  AkRelevant{}
  AkVar{}
  AkApply{}
  AkHidden{}
  AkVisible{}
  AkQ{}
  AkDef{}
  AkPlus{}
  AkSet{}
  AkMax{}
  AkEl{}
  AkSystem{}
  AkNone{}
  AkAbs{}
  AkDom{}
  AkPi{}
  AkP{}
  AkB{}
  AkX{}
  AkCon{}
  AkPvar{}
  AkLam{}
  AkNo{}
  AkInf{}
  AkType{}
  AkRange{}
  AkSort{}
  AkFunction{}
  AkLevel{}
  AkL{}
  AkYes{}
  AkProj{}
  AkCatchall{}
  AkIrrelevant{}
  AkIntervaluniv{}
  AkVars{}
  AkDone{}
  AkClause{}
  AkTel{}
  AkUnreachable{}
  AkBody{}
  AkPats{}
  AkWhereModule{}
  AkRecursive{}
  AkOf{}
  AkNoabs{}
  AkSset{}
  AkWithoutK{}
  AkFunsort{}
  AkMutual{}
  AkTerminates{}
  AkOpaque{}
  AkCompiled{}
  AkClauses{}
  AkProjection{}
  AkWithOf{}
  AkFunFlags{}
  AkRestoredParams{}
  AkExtlam{}
  AkKanOp{}
  AkModule{}
  AkName{}
  AkFlags{}
  AkFixity{}
  AkKind{}
  AkModality{}
  AkCanonical{}
  AkLanguage{}
  AkLines{}
  AkInline{}
  AkCopy{}
  AkBr{}
  AkFallthrough{}
  AkLazy{}
  AkUnknown{}
  AkRecord{}
  AkFrom{}
  AkOrig{}
  AkIndex{}
  AkProper{}
  AkLams{}
  AkNoparams{}
  AkEta{}
  AkCopattern{}
  AkCons{}
  AkLits{}
  AkBranches{}
  AkCase{}
  AkPisort{}
  AkField{}
  AkPcon{}
  AkPproj{}
  AkPdot{}
  AkQ0{}
  AkErased{}
  AkSplit{}
  AkCopatternLhs{}
  AkInfix{}
  AkConstructor{}
  AkIapply{}
  AkAbstract{}
  AkPars{}
  AkInduction{}
  AkFields{}
  AkNoCompilation{}
  AkPdef{}
  AkPrefix{}
  AkData{}
  AkSrcCon{}
  AkProjections{}
  AkConKind{}
  AkErasure{}
  AkForced{}
  AkArity{}
  AkInductive{}
  AkNamedCon{}
  AkPatternMatching{}
  AkInferred{}
  AkInfixr{}
  AkInfixl{}
  AkLeveluniv{}
  AkWild{}
  AkSplitArg{}
  AkBuiltin{}
  AkTerm{}
  AkAbsurd{}
  AkOther{}
  AkErasedCubical{}
  AkPrimitive{}
  AkPostulate{}
  AkConstTransp{}
  AkPathCons{}
  AkIxs{}
  AkLit{}
  AkNat{}
  AkWord64{}
  AkFloat{}
  AkString{}
  AkChar{}
  AkQname{}
  AkMeta{}
  AkDontcare{}
  AkDummy{}
  AkInstance{}
  AkShapeIrrelevant{}
  AkQ1{}
  AkPostfix{}
  AkProp{}
  AkSizeuniv{}
  AkLockuniv{}
  AkUnivsort{}
  AkMetas{}
  AkDefs{}
  AkDummys{}
  AkPlit{}
  AkPiapply{}
  AkLbr{}
  AkFail{}
  AkWithK{}
  AkCubical{}
  AkCoinductive{}
  AkSpecified{}
  AkPattern{}
  AkRec{}
  AkDot{}
  AkImports{}
  AkOptions{}
  AkLibraryOptions{}
  AkBuiltins{}
  AkPrim{}
  AkRewrite{}
  AkFile{}
  AkWord{}

# An S-expression with its keywords classified: a keyword, any other atom
# (the digits of a number, a precedence like 4.5), a string, and the cons
# cells of a list.
type AgX is Data:
  AxKw{k: AgKw}
  AxNum{s: List<&2, U32>}
  AxStr{s: List<&2, U32>}
  AxNil{}
  AxCons{h: AgX, t: AgX}

# A qualified name (q STRING W H): Agda's printing of it, and its NameId,
# the counter and the hash of the module that made it.  Two names may
# print the same; their NameIds differ, so (w, k) is the key.
type AgQ is Data:
  AgQ{s: List<&2, U32>, w: List<&2, U32>, k: List<&2, U32>}

# An argument's INFO: hiding (AkVisible, AkHidden, AkInstance), relevance
# (AkRelevant, AkIrrelevant, AkShapeIrrelevant) and quantity (AkW, AkQ1,
# AkQ0, the last erased).
type AgI is Data:
  AgI{h: AgKw, r: AgKw, m: AgKw}

# The grammar category aas.dec reads an expression as.
type AgCat is Data:
  AcTerm{}
  AcType{}
  AcElims{}
  AcSort{}
  AcLevel{}
  AcPlus{}
  AcLit{}
  AcTel{}
  AcTelBs{}
  AcClauses{}
  AcClTy{}
  AcPats{}
  AcPat{}
  AcTree{}
  AcVars{}
  AcBranches{}
  AcBrs{}
  AcEta{}
  AcLBrs{}
  AcQs{}

# Agda's syntax.  `x` fields are binder names as Agda printed them (a hint:
# variables are de Bruijn indices); `i` is an INFO.
type Ag is Data:
  # Terms.  An `es` is an elimination spine.  `dep` is False for `noabs`
  # (a constant lambda, a non-dependent Pi), whose body still counts the
  # binder.  AgPi's `a` and `b` are TYPEs (AgEl), `b` in the scope of x.
  AgVar{i: Nat, x: List<&2, U32>, es: Ag}
  AgLam{i: AgI, x: List<&2, U32>, dep: Bool, b: Ag}
  AgLit{l: Ag}
  AgDef{q: AgQ, es: Ag}
  AgCon{q: AgQ, o: AgKw, es: Ag}
  AgPi{i: AgI, x: List<&2, U32>, a: Ag, dep: Bool, b: Ag}
  AgSort{s: Ag}
  AgLevel{l: Ag}
  AgMeta{es: Ag}
  AgDontCare{t: Ag}
  AgDummy{s: List<&2, U32>, es: Ag}
  AgStored{t: Ag}
  AgEl{s: Ag, t: Ag}
  AgAbsurd{}
  AgNone{}
  # Eliminations: an application to an argument, a projection.
  AgENil{}
  AgEApp{i: AgI, t: Ag, rest: Ag}
  AgEProj{q: AgQ, rest: Ag}
  AgERaw{x: AgX, rest: Ag}
  # Sorts: Set ℓ, Prop ℓ, SSet ℓ, Setω_n (k: set, prop or sset), and the
  # level, size, lock and interval universes (k names which).
  AgSSet{l: Ag}
  AgSProp{l: Ag}
  AgSSSet{l: Ag}
  AgSInf{k: AgKw, n: Nat}
  AgSUniv{k: AgKw}
  # The sorts of Pi types and of sorts: a function type's, a dependent
  # one's (the domain's INFO, name and type, the domain's sort and the
  # codomain's, in the scope of x), the sort of a sort, and a defined sort.
  AgSFun{a: Ag, b: Ag}
  AgSPi{i: AgI, x: List<&2, U32>, t: Ag, a: Ag, b: Ag}
  AgSUnivOf{s: Ag}
  AgSDef{q: AgQ, es: Ag}
  # Levels: the maximum of n and each term plus k.
  AgLMax{n: Nat, ps: Ag}
  AgLPlus{k: Nat, t: Ag, rest: Ag}
  AgLEnd{}
  # Literals (their digits or text as written).
  AgLNat{s: List<&2, U32>}
  AgLWord{s: List<&2, U32>}
  AgLFloat{s: List<&2, U32>}
  AgLStr{s: List<&2, U32>}
  AgLChar{s: List<&2, U32>}
  AgLQName{q: AgQ}
  # Telescopes: each binding's TYPE in the scope of the earlier ones.
  AgTel{x: List<&2, U32>, i: AgI, ty: Ag, rest: Ag}
  AgTEnd{}
  # Clauses: the telescope of the pattern variables, the patterns, the
  # body (AgAbsurd for an absurd clause), the right-hand side's TYPE or
  # AgNone, and whether it is a catch-all.
  AgCl{tel: Ag, ps: Ag, body: Ag, ty: Ag, catchall: Bool, rest: Ag}
  AgClEnd{}
  # Patterns: a spine of arguments (x: the argument's name, or empty),
  # each a pattern.  A variable's n is its de Bruijn index in the clause's
  # telescope; o is its origin (an absurd pattern has AkAbsurd).
  AgPArg{i: AgI, x: List<&2, U32>, p: Ag, rest: Ag}
  AgPEnd{}
  AgPVar{x: List<&2, U32>, n: Nat, o: AgKw}
  AgPDot{t: Ag}
  AgPCon{q: AgQ, rec: Bool, ps: Ag}
  AgPLit{l: Ag}
  AgPProj{q: AgQ}
  # Case trees (Agda's funCompiled): split argument n; a leaf with its
  # variables (the last is index 0); an absurd leaf.  A branch list's
  # constructor branches, its eta branch (an AgBr or AgNone), its literal
  # branches and its catch-all (a tree or AgNone); copattern branches
  # name projections.
  AgCase{i: AgI, n: Nat, b: Ag}
  AgDone{xs: Ag, t: Ag}
  AgFail{xs: Ag}
  AgBranches{copat: Bool, cons: Ag, eta: Ag, lits: Ag, catchall: Ag}
  AgBr{q: AgQ, n: Nat, t: Ag, rest: Ag}
  AgLBr{l: Ag, t: Ag, rest: Ag}
  AgBEnd{}
  AgVars{i: AgI, x: List<&2, U32>, rest: Ag}
  AgVEnd{}
  # Name lists: record fields (with their INFO), a data type's
  # constructors, a mutual block.
  AgQs{i: AgI, q: AgQ, rest: Ag}
  AgQEnd{}
  # A form this grammar does not know, kept with the category it was read
  # as (the cubical forms: iapply, piapply, pdef, the interval sorts).
  AgRaw{c: AgCat, x: AgX}

# Keywords ---------------------------------------------------------------

def aas.hash(xs: List<&2, U32>, acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      aas.hash(t, U32.add(U32.mul(acc, 31), h))

# A keyword's constructor from its hash (AkWord for any other hash).
def aas.kw.of(h: U32) -> AgKw:
  match h:
    case 119:
      AkW{}
    case 3744277149:
      AkRelevant{}
    case 116519:
      AkVar{}
    case 93029230:
      AkApply{}
    case 3077479850:
      AkHidden{}
    case 466743410:
      AkVisible{}
    case 113:
      AkQ{}
    case 99333:
      AkDef{}
    case 3444122:
      AkPlus{}
    case 113762:
      AkSet{}
    case 107876:
      AkMax{}
    case 3239:
      AkEl{}
    case 3407639087:
      AkSystem{}
    case 3387192:
      AkNone{}
    case 96370:
      AkAbs{}
    case 99650:
      AkDom{}
    case 3577:
      AkPi{}
    case 112:
      AkP{}
    case 98:
      AkB{}
    case 120:
      AkX{}
    case 98690:
      AkCon{}
    case 3453111:
      AkPvar{}
    case 106904:
      AkLam{}
    case 3521:
      AkNo{}
    case 104417:
      AkInf{}
    case 3575610:
      AkType{}
    case 108280125:
      AkRange{}
    case 3536286:
      AkSort{}
    case 1380938712:
      AkFunction{}
    case 102865796:
      AkLevel{}
    case 108:
      AkL{}
    case 119527:
      AkYes{}
    case 3449693:
      AkProj{}
    case 48680198:
      AkCatchall{}
    case 398849734:
      AkIrrelevant{}
    case 2726089675:
      AkIntervaluniv{}
    case 3612204:
      AkVars{}
    case 3089282:
      AkDone{}
    case 2937032047:
      AkClause{}
    case 114715:
      AkTel{}
    case 3229076180:
      AkUnreachable{}
    case 3029410:
      AkBody{}
    case 3433520:
      AkPats{}
    case 2156548626:
      AkWhereModule{}
    case 1165780018:
      AkRecursive{}
    case 3543:
      AkOf{}
    case 104990481:
      AkNoabs{}
    case 3539727:
      AkSset{}
    case 927528102:
      AkWithoutK{}
    case 3785796509:
      AkFunsort{}
    case 3232200724:
      AkMutual{}
    case 2986151474:
      AkTerminates{}
    case 3284272161:
      AkOpaque{}
    case 3695438993:
      AkCompiled{}
    case 853680356:
      AkClauses{}
    case 2325006927:
      AkProjection{}
    case 1355089982:
      AkWithOf{}
    case 2595566777:
      AkFunFlags{}
    case 1032277917:
      AkRestoredParams{}
    case 3005929431:
      AkExtlam{}
    case 3156224502:
      AkKanOp{}
    case 3226183276:
      AkModule{}
    case 3373707:
      AkName{}
    case 97513095:
      AkFlags{}
    case 3020822649:
      AkFixity{}
    case 3292052:
      AkKind{}
    case 3672244961:
      AkModality{}
    case 828351732:
      AkCanonical{}
    case 2681377624:
      AkLanguage{}
    case 102977279:
      AkLines{}
    case 3110970009:
      AkInline{}
    case 3059573:
      AkCopy{}
    case 3152:
      AkBr{}
    case 4078330602:
      AkFallthrough{}
    case 3314548:
      AkLazy{}
    case 4010126410:
      AkUnknown{}
    case 3360058449:
      AkRecord{}
    case 3151786:
      AkFrom{}
    case 3419713:
      AkOrig{}
    case 100346066:
      AkIndex{}
    case 3315163984:
      AkProper{}
    case 3314139:
      AkLams{}
    case 1463808647:
      AkNoparams{}
    case 100754:
      AkEta{}
    case 837963172:
      AkCopattern{}
    case 3059505:
      AkCons{}
    case 3322044:
      AkLits{}
    case 4269560272:
      AkBranches{}
    case 3046192:
      AkCase{}
    case 3306970903:
      AkPisort{}
    case 97427706:
      AkField{}
    case 3435282:
      AkPcon{}
    case 106884045:
      AkPproj{}
    case 3436249:
      AkPdot{}
    case 3551:
      AkQ0{}
    case 2999829118:
      AkErased{}
    case 109648666:
      AkSplit{}
    case 790688462:
      AkCopatternLhs{}
    case 100348112:
      AkInfix{}
    case 2706561018:
      AkConstructor{}
    case 3099090085:
      AkIapply{}
    case 1732898850:
      AkAbstract{}
    case 3433458:
      AkPars{}
    case 3927072577:
      AkInduction{}
    case 3020259001:
      AkFields{}
    case 1452114871:
      AkNoCompilation{}
    case 3435925:
      AkPdef{}
    case 3314856594:
      AkPrefix{}
    case 3076010:
      AkData{}
    case 2340299289:
      AkSrcCon{}
    case 3355738116:
      AkProjections{}
    case 3662249215:
      AkConKind{}
    case 2800405353:
      AkErasure{}
    case 3026178777:
      AkForced{}
    case 93082333:
      AkArity{}
    case 3927072785:
      AkInductive{}
    case 1236371694:
      AkNamedCon{}
    case 2550744474:
      AkPatternMatching{}
    case 169606531:
      AkInferred{}
    case 3110791586:
      AkInfixr{}
    case 3110791580:
      AkInfixl{}
    case 2639729418:
      AkLeveluniv{}
    case 3649482:
      AkWild{}
    case 403172643:
      AkSplitArg{}
    case 230960163:
      AkBuiltin{}
    case 3556460:
      AkTerm{}
    case 2871074741:
      AkAbsurd{}
    case 106069776:
      AkOther{}
    case 4034227366:
      AkErasedCubical{}
    case 2460159207:
      AkPrimitive{}
    case 2023037947:
      AkPostulate{}
    case 1175457906:
      AkConstTransp{}
    case 3870702553:
      AkPathCons{}
    case 104740:
      AkIxs{}
    case 107159:
      AkLit{}
    case 108833:
      AkNat{}
    case 3512873800:
      AkWord64{}
    case 97526364:
      AkFloat{}
    case 3402981393:
      AkString{}
    case 3052374:
      AkChar{}
    case 107731580:
      AkQname{}
    case 3347973:
      AkMeta{}
    case 1175416354:
      AkDontcare{}
    case 95945896:
      AkDummy{}
    case 555127957:
      AkInstance{}
    case 286635122:
      AkShapeIrrelevant{}
    case 3552:
      AkQ1{}
    case 3903762293:
      AkPostfix{}
    case 3449699:
      AkProp{}
    case 847958279:
      AkSizeuniv{}
    case 1910313265:
      AkLockuniv{}
    case 4005076004:
      AkUnivsort{}
    case 103787278:
      AkMetas{}
    case 3079438:
      AkDefs{}
    case 2974322891:
      AkDummys{}
    case 3443751:
      AkPlit{}
    case 3715254549:
      AkPiapply{}
    case 106940:
      AkLbr{}
    case 3135262:
      AkFail{}
    case 3507395876:
      AkWithK{}
    case 1111893237:
      AkCubical{}
    case 1784384805:
      AkCoinductive{}
    case 2600353200:
      AkSpecified{}
    case 3503877008:
      AkPattern{}
    case 112784:
      AkRec{}
    case 99657:
      AkDot{}
    case 1926037870:
      AkImports{}
    case 3045492382:
      AkOptions{}
    case 2275189644:
      AkLibraryOptions{}
    case 2864797872:
      AkBuiltins{}
    case 3449510:
      AkPrim{}
    case 1101148556:
      AkRewrite{}
    case 3143036:
      AkFile{}
    case _:
      AkWord{}

def aas.kw(+s: List<&2, U32>) -> AgKw:
  aas.kw.of(aas.hash(s, 0))

# A keyword's hash: the code two keywords are compared by.
def aas.kw.code(k: AgKw) -> U32:
  match k:
    case AkW{}:
      119
    case AkRelevant{}:
      3744277149
    case AkVar{}:
      116519
    case AkApply{}:
      93029230
    case AkHidden{}:
      3077479850
    case AkVisible{}:
      466743410
    case AkQ{}:
      113
    case AkDef{}:
      99333
    case AkPlus{}:
      3444122
    case AkSet{}:
      113762
    case AkMax{}:
      107876
    case AkEl{}:
      3239
    case AkSystem{}:
      3407639087
    case AkNone{}:
      3387192
    case AkAbs{}:
      96370
    case AkDom{}:
      99650
    case AkPi{}:
      3577
    case AkP{}:
      112
    case AkB{}:
      98
    case AkX{}:
      120
    case AkCon{}:
      98690
    case AkPvar{}:
      3453111
    case AkLam{}:
      106904
    case AkNo{}:
      3521
    case AkInf{}:
      104417
    case AkType{}:
      3575610
    case AkRange{}:
      108280125
    case AkSort{}:
      3536286
    case AkFunction{}:
      1380938712
    case AkLevel{}:
      102865796
    case AkL{}:
      108
    case AkYes{}:
      119527
    case AkProj{}:
      3449693
    case AkCatchall{}:
      48680198
    case AkIrrelevant{}:
      398849734
    case AkIntervaluniv{}:
      2726089675
    case AkVars{}:
      3612204
    case AkDone{}:
      3089282
    case AkClause{}:
      2937032047
    case AkTel{}:
      114715
    case AkUnreachable{}:
      3229076180
    case AkBody{}:
      3029410
    case AkPats{}:
      3433520
    case AkWhereModule{}:
      2156548626
    case AkRecursive{}:
      1165780018
    case AkOf{}:
      3543
    case AkNoabs{}:
      104990481
    case AkSset{}:
      3539727
    case AkWithoutK{}:
      927528102
    case AkFunsort{}:
      3785796509
    case AkMutual{}:
      3232200724
    case AkTerminates{}:
      2986151474
    case AkOpaque{}:
      3284272161
    case AkCompiled{}:
      3695438993
    case AkClauses{}:
      853680356
    case AkProjection{}:
      2325006927
    case AkWithOf{}:
      1355089982
    case AkFunFlags{}:
      2595566777
    case AkRestoredParams{}:
      1032277917
    case AkExtlam{}:
      3005929431
    case AkKanOp{}:
      3156224502
    case AkModule{}:
      3226183276
    case AkName{}:
      3373707
    case AkFlags{}:
      97513095
    case AkFixity{}:
      3020822649
    case AkKind{}:
      3292052
    case AkModality{}:
      3672244961
    case AkCanonical{}:
      828351732
    case AkLanguage{}:
      2681377624
    case AkLines{}:
      102977279
    case AkInline{}:
      3110970009
    case AkCopy{}:
      3059573
    case AkBr{}:
      3152
    case AkFallthrough{}:
      4078330602
    case AkLazy{}:
      3314548
    case AkUnknown{}:
      4010126410
    case AkRecord{}:
      3360058449
    case AkFrom{}:
      3151786
    case AkOrig{}:
      3419713
    case AkIndex{}:
      100346066
    case AkProper{}:
      3315163984
    case AkLams{}:
      3314139
    case AkNoparams{}:
      1463808647
    case AkEta{}:
      100754
    case AkCopattern{}:
      837963172
    case AkCons{}:
      3059505
    case AkLits{}:
      3322044
    case AkBranches{}:
      4269560272
    case AkCase{}:
      3046192
    case AkPisort{}:
      3306970903
    case AkField{}:
      97427706
    case AkPcon{}:
      3435282
    case AkPproj{}:
      106884045
    case AkPdot{}:
      3436249
    case AkQ0{}:
      3551
    case AkErased{}:
      2999829118
    case AkSplit{}:
      109648666
    case AkCopatternLhs{}:
      790688462
    case AkInfix{}:
      100348112
    case AkConstructor{}:
      2706561018
    case AkIapply{}:
      3099090085
    case AkAbstract{}:
      1732898850
    case AkPars{}:
      3433458
    case AkInduction{}:
      3927072577
    case AkFields{}:
      3020259001
    case AkNoCompilation{}:
      1452114871
    case AkPdef{}:
      3435925
    case AkPrefix{}:
      3314856594
    case AkData{}:
      3076010
    case AkSrcCon{}:
      2340299289
    case AkProjections{}:
      3355738116
    case AkConKind{}:
      3662249215
    case AkErasure{}:
      2800405353
    case AkForced{}:
      3026178777
    case AkArity{}:
      93082333
    case AkInductive{}:
      3927072785
    case AkNamedCon{}:
      1236371694
    case AkPatternMatching{}:
      2550744474
    case AkInferred{}:
      169606531
    case AkInfixr{}:
      3110791586
    case AkInfixl{}:
      3110791580
    case AkLeveluniv{}:
      2639729418
    case AkWild{}:
      3649482
    case AkSplitArg{}:
      403172643
    case AkBuiltin{}:
      230960163
    case AkTerm{}:
      3556460
    case AkAbsurd{}:
      2871074741
    case AkOther{}:
      106069776
    case AkErasedCubical{}:
      4034227366
    case AkPrimitive{}:
      2460159207
    case AkPostulate{}:
      2023037947
    case AkConstTransp{}:
      1175457906
    case AkPathCons{}:
      3870702553
    case AkIxs{}:
      104740
    case AkLit{}:
      107159
    case AkNat{}:
      108833
    case AkWord64{}:
      3512873800
    case AkFloat{}:
      97526364
    case AkString{}:
      3402981393
    case AkChar{}:
      3052374
    case AkQname{}:
      107731580
    case AkMeta{}:
      3347973
    case AkDontcare{}:
      1175416354
    case AkDummy{}:
      95945896
    case AkInstance{}:
      555127957
    case AkShapeIrrelevant{}:
      286635122
    case AkQ1{}:
      3552
    case AkPostfix{}:
      3903762293
    case AkProp{}:
      3449699
    case AkSizeuniv{}:
      847958279
    case AkLockuniv{}:
      1910313265
    case AkUnivsort{}:
      4005076004
    case AkMetas{}:
      103787278
    case AkDefs{}:
      3079438
    case AkDummys{}:
      2974322891
    case AkPlit{}:
      3443751
    case AkPiapply{}:
      3715254549
    case AkLbr{}:
      106940
    case AkFail{}:
      3135262
    case AkWithK{}:
      3507395876
    case AkCubical{}:
      1111893237
    case AkCoinductive{}:
      1784384805
    case AkSpecified{}:
      2600353200
    case AkPattern{}:
      3503877008
    case AkRec{}:
      112784
    case AkDot{}:
      99657
    case AkImports{}:
      1926037870
    case AkOptions{}:
      3045492382
    case AkLibraryOptions{}:
      2275189644
    case AkBuiltins{}:
      2864797872
    case AkPrim{}:
      3449510
    case AkRewrite{}:
      1101148556
    case AkFile{}:
      3143036
    case AkWord{}:
      0

def aas.kw.eq(a: AgKw, b: AgKw) -> Bool:
  U32.is_eq(aas.kw.code(a), aas.kw.code(b))

# Classifying ---------------------------------------------------------------

# a letter starts a keyword; a digit starts a number
def aas.alpha(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      Bool.or(Bool.and(U32.is_ge(h, 97), U32.is_le(h, 122)), Bool.and(U32.is_ge(h, 65), U32.is_le(h, 90)))

def aas.x.atom(alpha: Bool, +s: List<&2, U32>) -> AgX:
  match alpha:
    case True{}:
      AxKw{aas.kw(s)}
    case False{}:
      AxNum{s}

# the S-expression with its keywords classified
def aas.x(x: X.Sx) -> AgX:
  match x:
    case X.SxAtom{+s}:
      aas.x.atom(aas.alpha(s), s)
    case X.SxStr{s}:
      AxStr{s}
    case X.SxNil{}:
      AxNil{}
    case X.SxCons{h, t}:
      AxCons{aas.x(h), aas.x(t)}

# Small pieces ---------------------------------------------------------------

# a number's value (0 for anything else)
def aas.n(x: AgX) -> Nat:
  match x:
    case AxNum{s}:
      X.tsx.nat.go(s, 0n)
    case _:
      0n

# a number's digits
def aas.digits(x: AgX) -> List<&2, U32>:
  match x:
    case AxNum{s}:
      s
    case _:
      Nil{}

# a string's bytes (empty for `none` and anything else)
def aas.str(x: AgX) -> List<&2, U32>:
  match x:
    case AxStr{s}:
      s
    case _:
      Nil{}

# a keyword (AkWord for anything else)
def aas.k(x: AgX) -> AgKw:
  match x:
    case AxKw{k}:
      k
    case _:
      AkWord{}

def aas.info(h: AgX, r: AgX, m: AgX) -> AgI:
  AgI{aas.k(h), aas.k(r), aas.k(m)}

# the INFO of an argument the grammar gives none (a data type's
# constructor list, a mutual block)
def aas.i.vis() -> AgI:
  AgI{AkVisible{}, AkRelevant{}, AkW{}}

# (q STRING W H)
def aas.q(x: AgX) -> AgQ:
  match x:
    case AxCons{AxKw{AkQ{}}, AxCons{s, AxCons{w, AxCons{k, AxNil{}}}}}:
      AgQ{aas.str(s), aas.digits(w), aas.digits(k)}
    case _:
      AgQ{Nil{}, Nil{}, Nil{}}

def aas.yes(k: AgKw) -> Bool:
  match k:
    case AkYes{}:
      True{}
    case _:
      False{}

# `abs` binds a variable its body uses; `noabs` binds one it does not
def aas.dep(k: AgKw) -> Bool:
  match k:
    case AkAbs{}:
      True{}
    case _:
      False{}

# The decoder ----------------------------------------------------------------

# x read as category c (FORMAT.md's grammar, form by form).
def aas.dec(x: AgX, c: AgCat) -> Ag:
  match x c:
    # TERM
    case AxCons{AxKw{AkVar{}}, AxCons{i, AxCons{nm, es}}} AcTerm{}:
      AgVar{aas.n(i), aas.str(nm), aas.dec(es, AcElims{})}
    case AxCons{AxKw{AkDef{}}, AxCons{q, es}} AcTerm{}:
      AgDef{aas.q(q), aas.dec(es, AcElims{})}
    case AxCons{AxKw{AkCon{}}, AxCons{q, AxCons{o, es}}} AcTerm{}:
      AgCon{aas.q(q), aas.k(o), aas.dec(es, AcElims{})}
    case AxCons{AxKw{AkLam{}}, AxCons{h, AxCons{r, AxCons{m, AxCons{AxCons{ab, AxCons{nm, AxCons{body, AxNil{}}}}, AxNil{}}}}}} AcTerm{}:
      AgLam{aas.info(h, r, m), aas.str(nm), aas.dep(aas.k(ab)), aas.dec(body, AcTerm{})}
    case AxCons{AxKw{AkPi{}}, AxCons{AxCons{dk, AxCons{h, AxCons{r, AxCons{m, AxCons{dn, AxCons{a, AxNil{}}}}}}}, AxCons{AxCons{ab, AxCons{nm, AxCons{b, AxNil{}}}}, AxNil{}}}} AcTerm{}:
      AgPi{aas.info(h, r, m), aas.str(nm), aas.dec(a, AcType{}), aas.dep(aas.k(ab)), aas.dec(b, AcType{})}
    case AxCons{AxKw{AkLit{}}, AxCons{l, AxNil{}}} AcTerm{}:
      AgLit{aas.dec(l, AcLit{})}
    case AxCons{AxKw{AkSort{}}, AxCons{s, AxNil{}}} AcTerm{}:
      AgSort{aas.dec(s, AcSort{})}
    case AxCons{AxKw{AkLevel{}}, AxCons{l, AxNil{}}} AcTerm{}:
      AgLevel{aas.dec(l, AcLevel{})}
    case AxCons{AxKw{AkMeta{}}, AxCons{w, AxCons{hh, es}}} AcTerm{}:
      AgMeta{aas.dec(es, AcElims{})}
    case AxCons{AxKw{AkDontcare{}}, AxCons{t, AxNil{}}} AcTerm{}:
      AgDontCare{aas.dec(t, AcTerm{})}
    case AxCons{AxKw{AkDummy{}}, AxCons{s, es}} AcTerm{}:
      AgDummy{aas.str(s), aas.dec(es, AcElims{})}
    case AxCons{AxKw{AkNoparams{}}, AxCons{t, AxNil{}}} AcTerm{}:
      AgStored{aas.dec(t, AcTerm{})}
    case AxKw{AkAbsurd{}} AcTerm{}:
      AgAbsurd{}
    # TYPE
    case AxCons{AxKw{AkEl{}}, AxCons{s, AxCons{t, AxNil{}}}} AcType{}:
      AgEl{aas.dec(s, AcSort{}), aas.dec(t, AcTerm{})}
    case AxCons{AxKw{AkNoparams{}}, AxCons{t, AxNil{}}} AcType{}:
      AgStored{aas.dec(t, AcType{})}
    # ELIM*
    case AxNil{} AcElims{}:
      AgENil{}
    case AxCons{AxCons{AxKw{AkApply{}}, AxCons{h, AxCons{r, AxCons{m, AxCons{t, AxNil{}}}}}}, rest} AcElims{}:
      AgEApp{aas.info(h, r, m), aas.dec(t, AcTerm{}), aas.dec(rest, AcElims{})}
    case AxCons{AxCons{AxKw{AkProj{}}, AxCons{how, AxCons{q, AxNil{}}}}, rest} AcElims{}:
      AgEProj{aas.q(q), aas.dec(rest, AcElims{})}
    case AxCons{e, rest} AcElims{}:
      AgERaw{e, aas.dec(rest, AcElims{})}
    # SORT
    case AxCons{AxKw{AkSet{}}, AxCons{l, AxNil{}}} AcSort{}:
      AgSSet{aas.dec(l, AcLevel{})}
    case AxCons{AxKw{AkProp{}}, AxCons{l, AxNil{}}} AcSort{}:
      AgSProp{aas.dec(l, AcLevel{})}
    case AxCons{AxKw{AkSset{}}, AxCons{l, AxNil{}}} AcSort{}:
      AgSSSet{aas.dec(l, AcLevel{})}
    case AxCons{AxKw{AkInf{}}, AxCons{k, AxCons{n, AxNil{}}}} AcSort{}:
      AgSInf{aas.k(k), aas.n(n)}
    case AxCons{AxKw{AkFunsort{}}, AxCons{a, AxCons{b, AxNil{}}}} AcSort{}:
      AgSFun{aas.dec(a, AcSort{}), aas.dec(b, AcSort{})}
    case AxCons{AxKw{AkPisort{}}, AxCons{AxCons{dk, AxCons{h, AxCons{r, AxCons{m, AxCons{dn, AxCons{t, AxNil{}}}}}}}, AxCons{a, AxCons{AxCons{ab, AxCons{nm, AxCons{b, AxNil{}}}}, AxNil{}}}}} AcSort{}:
      AgSPi{aas.info(h, r, m), aas.str(nm), aas.dec(t, AcTerm{}), aas.dec(a, AcSort{}), aas.dec(b, AcSort{})}
    case AxCons{AxKw{AkUnivsort{}}, AxCons{s, AxNil{}}} AcSort{}:
      AgSUnivOf{aas.dec(s, AcSort{})}
    case AxCons{AxKw{AkDefs{}}, AxCons{q, es}} AcSort{}:
      AgSDef{aas.q(q), aas.dec(es, AcElims{})}
    case AxCons{AxKw{u}, AxNil{}} AcSort{}:
      AgSUniv{u}
    # LEVEL
    case AxCons{AxKw{AkMax{}}, AxCons{n, ps}} AcLevel{}:
      AgLMax{aas.n(n), aas.dec(ps, AcPlus{})}
    case AxNil{} AcPlus{}:
      AgLEnd{}
    case AxCons{AxCons{AxKw{AkPlus{}}, AxCons{k, AxCons{t, AxNil{}}}}, rest} AcPlus{}:
      AgLPlus{aas.n(k), aas.dec(t, AcTerm{}), aas.dec(rest, AcPlus{})}
    # LIT
    case AxCons{AxKw{AkNat{}}, AxCons{n, AxNil{}}} AcLit{}:
      AgLNat{aas.digits(n)}
    case AxCons{AxKw{AkWord64{}}, AxCons{n, AxNil{}}} AcLit{}:
      AgLWord{aas.digits(n)}
    case AxCons{AxKw{AkFloat{}}, AxCons{s, AxNil{}}} AcLit{}:
      AgLFloat{aas.str(s)}
    case AxCons{AxKw{AkString{}}, AxCons{s, AxNil{}}} AcLit{}:
      AgLStr{aas.str(s)}
    case AxCons{AxKw{AkChar{}}, AxCons{n, AxNil{}}} AcLit{}:
      AgLChar{aas.digits(n)}
    case AxCons{AxKw{AkQname{}}, AxCons{q, AxNil{}}} AcLit{}:
      AgLQName{aas.q(q)}
    # TEL
    case AxCons{AxKw{AkTel{}}, bs} AcTel{}:
      aas.dec(bs, AcTelBs{})
    case AxCons{AxKw{AkNoparams{}}, AxCons{t, AxNil{}}} AcTel{}:
      AgStored{aas.dec(t, AcTel{})}
    case AxNil{} AcTelBs{}:
      AgTEnd{}
    case AxCons{AxCons{bk, AxCons{nm, AxCons{h, AxCons{r, AxCons{m, AxCons{dn, AxCons{ty, AxNil{}}}}}}}}, rest} AcTelBs{}:
      AgTel{aas.str(nm), aas.info(h, r, m), aas.dec(ty, AcType{}), aas.dec(rest, AcTelBs{})}
    # CLAUSE*
    case AxNil{} AcClauses{}:
      AgClEnd{}
    case AxCons{AxCons{AxKw{AkClause{}}, AxCons{rng, AxCons{tel, AxCons{AxCons{pk, ps}, AxCons{AxCons{bk, AxCons{body, AxNil{}}}, AxCons{ty, AxCons{AxCons{ck, AxCons{ca, AxNil{}}}, more}}}}}}}, rest} AcClauses{}:
      AgCl{aas.dec(tel, AcTel{}), aas.dec(ps, AcPats{}), aas.dec(body, AcTerm{}), aas.dec(ty, AcClTy{}), aas.yes(aas.k(ca)), aas.dec(rest, AcClauses{})}
    case AxCons{AxKw{AkType{}}, AxCons{AxCons{ok, AxCons{h, AxCons{r, AxCons{m, AxCons{t, AxNil{}}}}}}, AxNil{}}} AcClTy{}:
      aas.dec(t, AcType{})
    # PAT*
    case AxNil{} AcPats{}:
      AgPEnd{}
    case AxCons{AxCons{AxKw{AkP{}}, AxCons{h, AxCons{r, AxCons{m, AxCons{nm, AxCons{p, AxNil{}}}}}}}, rest} AcPats{}:
      AgPArg{aas.info(h, r, m), aas.str(nm), aas.dec(p, AcPat{}), aas.dec(rest, AcPats{})}
    # PATTERN
    case AxCons{AxKw{AkPvar{}}, AxCons{nm, AxCons{n, AxCons{o, AxNil{}}}}} AcPat{}:
      AgPVar{aas.str(nm), aas.n(n), aas.k(o)}
    case AxCons{AxKw{AkPdot{}}, AxCons{o, AxCons{t, AxNil{}}}} AcPat{}:
      AgPDot{aas.dec(t, AcTerm{})}
    case AxCons{AxKw{AkPcon{}}, AxCons{q, AxCons{o, AxCons{AxCons{rk, AxCons{rec, AxNil{}}}, AxCons{lz, AxCons{ft, AxCons{ty, ps}}}}}}} AcPat{}:
      AgPCon{aas.q(q), aas.yes(aas.k(rec)), aas.dec(ps, AcPats{})}
    case AxCons{AxKw{AkPlit{}}, AxCons{o, AxCons{l, AxNil{}}}} AcPat{}:
      AgPLit{aas.dec(l, AcLit{})}
    case AxCons{AxKw{AkPproj{}}, AxCons{how, AxCons{q, AxNil{}}}} AcPat{}:
      AgPProj{aas.q(q)}
    # TREE
    case AxKw{AkNone{}} AcTree{}:
      AgNone{}
    case AxCons{AxKw{AkCase{}}, AxCons{h, AxCons{r, AxCons{m, AxCons{n, AxCons{b, AxNil{}}}}}}} AcTree{}:
      AgCase{aas.info(h, r, m), aas.n(n), aas.dec(b, AcBranches{})}
    case AxCons{AxKw{AkDone{}}, AxCons{AxCons{vk, vs}, AxCons{t, AxNil{}}}} AcTree{}:
      AgDone{aas.dec(vs, AcVars{}), aas.dec(t, AcTerm{})}
    case AxCons{AxKw{AkFail{}}, AxCons{AxCons{vk, vs}, AxNil{}}} AcTree{}:
      AgFail{aas.dec(vs, AcVars{})}
    case AxCons{AxKw{AkNoparams{}}, AxCons{t, AxNil{}}} AcTree{}:
      AgStored{aas.dec(t, AcTree{})}
    case AxNil{} AcVars{}:
      AgVEnd{}
    case AxCons{AxCons{xk, AxCons{h, AxCons{r, AxCons{m, AxCons{nm, AxNil{}}}}}}, rest} AcVars{}:
      AgVars{aas.info(h, r, m), aas.str(nm), aas.dec(rest, AcVars{})}
    case AxCons{AxKw{AkBranches{}}, AxCons{AxCons{cpk, AxCons{cp, AxNil{}}}, AxCons{AxCons{csk, brs}, AxCons{AxCons{ek, eta}, AxCons{AxCons{lk, lbrs}, AxCons{AxCons{cak, AxCons{ca, AxNil{}}}, more}}}}}} AcBranches{}:
      AgBranches{aas.yes(aas.k(cp)), aas.dec(brs, AcBrs{}), aas.dec(eta, AcEta{}), aas.dec(lbrs, AcLBrs{}), aas.dec(ca, AcTree{})}
    case AxNil{} AcBrs{}:
      AgBEnd{}
    case AxCons{AxCons{bk, AxCons{q, AxCons{n, AxCons{t, AxNil{}}}}}, rest} AcBrs{}:
      AgBr{aas.q(q), aas.n(n), aas.dec(t, AcTree{}), aas.dec(rest, AcBrs{})}
    case AxCons{q, AxCons{n, AxCons{t, AxNil{}}}} AcEta{}:
      AgBr{aas.q(q), aas.n(n), aas.dec(t, AcTree{}), AgBEnd{}}
    case AxNil{} AcLBrs{}:
      AgBEnd{}
    case AxCons{AxCons{lk, AxCons{l, AxCons{t, AxNil{}}}}, rest} AcLBrs{}:
      AgLBr{aas.dec(l, AcLit{}), aas.dec(t, AcTree{}), aas.dec(rest, AcLBrs{})}
    # name lists: (field INFO Q)* or Q*
    case AxNil{} AcQs{}:
      AgQEnd{}
    case AxCons{AxCons{AxKw{AkField{}}, AxCons{h, AxCons{r, AxCons{m, AxCons{q, AxNil{}}}}}}, rest} AcQs{}:
      AgQs{aas.info(h, r, m), aas.q(q), aas.dec(rest, AcQs{})}
    case AxCons{q, rest} AcQs{}:
      AgQs{aas.i.vis(), aas.q(q), aas.dec(rest, AcQs{})}
    # `none` where a TYPE or an eta branch may be absent, `unknown` for a
    # mutual block Agda did not record
    case AxCons{AxKw{AkType{}}, AxCons{AxKw{AkNone{}}, AxNil{}}} AcClTy{}:
      AgNone{}
    case AxCons{AxKw{AkNone{}}, AxNil{}} AcEta{}:
      AgNone{}
    case AxKw{AkUnknown{}} AcQs{}:
      AgQEnd{}
    # anything else
    case y d:
      AgRaw{d, y}

# Definitions ----------------------------------------------------------------

# A function's projection info: none, or (proper Q|none) (orig Q) (from
# INFO Q) (index N) (lams ...): the record a field belongs to (None for a
# projection-like function), the original, and the principal argument's
# position counting from 1.
type AgProj is Data:
  AgPrNone{}
  AgPrOf{rec: Maybe<&2, AgQ>, orig: AgQ, index: Nat}

# A definition's details, by kind.
type AgD is Data:
  # a function: its projection info, how many parameters the export put
  # back, the parent of a `with` helper, whether it is a pattern lambda,
  # Agda's termination verdict, its mutual block, clauses and case tree
  AgDFun{proj: AgProj, restored: Nat, with: Maybe<&2, AgQ>, extlam: Bool, term: AgKw, mutual: Ag, cls: Ag, tree: Ag}
  # a record: its parameter count, constructor, whether the user named
  # it, induction, fields, the telescope of parameters then fields,
  # whether eta holds, and pattern or copattern matching
  AgDRec{pars: Nat, con: AgQ, named: Bool, ind: AgKw, fields: Ag, tel: Ag, eta: Bool, pm: AgKw}
  # a data type: parameter and index counts, constructors, sort
  AgDData{pars: Nat, ixs: Nat, cons: Ag, sort: Ag}
  # a constructor: its data type or record, the parameter count, its own
  # argument count, data or record
  AgDCon{data: AgQ, pars: Nat, arity: Nat, ck: AgKw}
  AgDPost{}
  AgDPrim{name: List<&2, U32>, cls: Ag, tree: Ag}
  AgDOther{x: AgX}

# A definition: its name, concrete name, module, the file and line of its
# binding site, its first and last line, kind, modality, flags, language,
# TYPE (closed) and details.
type AgDecl is Data:
  AgDecl{q: AgQ, name: List<&2, U32>, mod: List<&2, U32>, file: List<&2, U32>, line: Nat, l0: Nat, l1: Nat, kind: AgKw, m: AgI, flags: List<&2, AgKw>, lang: AgKw, ty: Ag, d: AgD}

# A module's header: its name, file, direct imports, options, and how many
# definitions follow.
type AgMod is Data:
  AgMod{name: List<&2, U32>, file: List<&2, U32>, imports: List<&2, List<&2, U32>>, opts: List<&2, List<&2, U32>>, defs: Nat}

# a list's first element, and the elements after it
def aas.first(x: AgX) -> AgX:
  match x:
    case AxCons{h, t}:
      h
    case _:
      AxNil{}

def aas.rest(x: AgX) -> AgX:
  match x:
    case AxCons{h, t}:
      t
    case _:
      AxNil{}

def aas.second(x: AgX) -> AgX:
  aas.first(aas.rest(x))

# the keyword code of the head of x's first element (0 when it has none)
def aas.hd.code(x: AgX) -> U32:
  match x:
    case AxCons{AxCons{AxKw{k}, a}, t}:
      aas.kw.code(k)
    case _:
      0

# hit: whether x's first element has the head being looked for, decided by
# the caller so the recursion stays in one def
def aas.fld.go(x: AgX, +code: U32, hit: Bool) -> AgX:
  match x hit:
    case AxCons{AxCons{k, a}, t} True{}:
      a
    case AxCons{e, +t} False{}:
      aas.fld.go(t, code, U32.is_eq(aas.hd.code(t), code))
    case _ _:
      AxNil{}

# The arguments of the first element of list x whose head is keyword k:
# in ((name "n") (kind record)), k = AkKind gives (record).  AxNil when
# there is none.
def aas.fld(+x: AgX, +k: AgKw) -> AgX:
  aas.fld.go(x, aas.kw.code(k), U32.is_eq(aas.hd.code(x), aas.kw.code(k)))

# a field's first argument
def aas.fld1(+x: AgX, +k: AgKw) -> AgX:
  aas.first(aas.fld(x, k))

def aas.kws(x: AgX) -> List<&2, AgKw>:
  match x:
    case AxCons{h, t}:
      aas.k(h) <> aas.kws(t)
    case _:
      Nil{}

def aas.strs(x: AgX) -> List<&2, List<&2, U32>>:
  match x:
    case AxCons{h, t}:
      aas.str(h) <> aas.strs(t)
    case _:
      Nil{}

# Q, or None for `none`
def aas.q.opt(x: AgX) -> Maybe<&2, AgQ>:
  match x:
    case AxCons{AxKw{AkQ{}}, r}:
      Some{aas.q(AxCons{AxKw{AkQ{}}, r})}
    case _:
      None{}

# (projection none) or (projection (proper Q|none) (orig Q) (from INFO Q)
# (index N) (lams ...)), k being the first argument's keyword
def aas.proj.of(k: AgKw, +p: AgX) -> AgProj:
  match k:
    case AkNone{}:
      AgPrNone{}
    case _:
      AgPrOf{aas.q.opt(aas.fld1(p, AkProper{})), aas.q(aas.fld1(p, AkOrig{})), aas.n(aas.fld1(p, AkIndex{}))}

# (extlam none) or (extlam STRING (absurd yes|no))
def aas.extlam(k: AgKw) -> Bool:
  match k:
    case AkNone{}:
      False{}
    case _:
      True{}

def aas.d.fun(+f: AgX) -> AgD:
  AgDFun{aas.proj.of(aas.k(aas.fld1(f, AkProjection{})), aas.fld(f, AkProjection{})), aas.n(aas.fld1(f, AkRestoredParams{})),
    aas.q.opt(aas.fld1(f, AkWithOf{})), aas.extlam(aas.k(aas.fld1(f, AkExtlam{}))), aas.k(aas.fld1(f, AkTerminates{})),
    aas.dec(aas.fld(f, AkMutual{}), AcQs{}), aas.dec(aas.fld(f, AkClauses{}), AcClauses{}), aas.dec(aas.fld1(f, AkCompiled{}), AcTree{})}

def aas.d.rec(+r: AgX) -> AgD:
  AgDRec{aas.n(aas.fld1(r, AkPars{})), aas.q(aas.fld1(r, AkCon{})), aas.yes(aas.k(aas.fld1(r, AkNamedCon{}))),
    aas.k(aas.fld1(r, AkInduction{})), aas.dec(aas.fld(r, AkFields{}), AcQs{}), aas.dec(aas.fld(r, AkTel{}), AcTelBs{}),
    aas.yes(aas.k(aas.second(aas.fld(r, AkEta{})))), aas.k(aas.fld1(r, AkPatternMatching{}))}

def aas.d.data(+d: AgX) -> AgD:
  AgDData{aas.n(aas.fld1(d, AkPars{})), aas.n(aas.fld1(d, AkIxs{})), aas.dec(aas.fld(d, AkCons{}), AcQs{}), aas.dec(aas.fld1(d, AkSort{}), AcSort{})}

def aas.d.con(+c: AgX) -> AgD:
  AgDCon{aas.q(aas.fld1(c, AkData{})), aas.n(aas.fld1(c, AkPars{})), aas.n(aas.fld1(c, AkArity{})), aas.k(aas.fld1(c, AkConKind{}))}

def aas.d.prim(+p: AgX) -> AgD:
  AgDPrim{aas.str(aas.first(p)), aas.dec(aas.fld(p, AkClauses{}), AcClauses{}), aas.dec(aas.fld1(p, AkCompiled{}), AcTree{})}

# the details, by kind (each kind's details sit under its own keyword)
def aas.d(k: AgKw, +a: AgX) -> AgD:
  match k:
    case AkFunction{}:
      aas.d.fun(aas.fld(a, AkFunction{}))
    case AkRecord{}:
      aas.d.rec(aas.fld(a, AkRecord{}))
    case AkData{}:
      aas.d.data(aas.fld(a, AkData{}))
    case AkConstructor{}:
      aas.d.con(aas.fld(a, AkConstructor{}))
    case AkPostulate{}:
      AgDPost{}
    case AkPrimitive{}:
      aas.d.prim(aas.fld(a, AkPrimitive{}))
    case _:
      AgDOther{a}

def aas.info.of(+m: AgX) -> AgI:
  aas.info(aas.first(m), aas.second(m), aas.first(aas.rest(aas.rest(m))))

# (def Q (name S) (canonical S) (fixity ..) (module S) RANGE (lines L L)
#   (kind K) (modality INFO) (flags F*) (language L) (type TYPE) DETAILS),
# given the elements after `def`
def aas.decl.of(+a: AgX, +k: AgKw) -> AgDecl:
  AgDecl{aas.q(aas.first(a)), aas.str(aas.fld1(a, AkName{})), aas.str(aas.fld1(a, AkModule{})),
    aas.str(aas.fld1(a, AkRange{})), aas.n(aas.second(aas.fld(a, AkRange{}))),
    aas.n(aas.fld1(a, AkLines{})), aas.n(aas.second(aas.fld(a, AkLines{}))),
    k, aas.info.of(aas.fld(a, AkModality{})), aas.kws(aas.fld(a, AkFlags{})), aas.k(aas.fld1(a, AkLanguage{})),
    aas.dec(aas.fld1(a, AkType{}), AcType{}), aas.d(k, a)}

def aas.decl(+x: AgX) -> AgDecl:
  aas.decl.of(aas.rest(x), aas.k(aas.fld1(aas.rest(x), AkKind{})))

def aas.mod.of(+a: AgX) -> AgMod:
  AgMod{aas.str(aas.first(a)), aas.str(aas.fld1(a, AkFile{})), aas.strs(aas.fld(a, AkImports{})), aas.strs(aas.fld(a, AkOptions{})), aas.n(aas.fld1(a, AkDefs{}))}

# a module's header, given the whole (module ...) expression
def aas.mod(x: AgX) -> AgMod:
  aas.mod.of(aas.rest(x))

# One expression of an export file: the module header, a definition, or
# anything else (the index's records).
type AgTop is Data:
  AgTopMod{m: AgMod}
  AgTopDef{d: AgDecl}
  AgTopOther{}

def aas.top.of(k: AgKw, +x: AgX) -> AgTop:
  match k:
    case AkModule{}:
      AgTopMod{aas.mod(x)}
    case AkDef{}:
      AgTopDef{aas.decl(x)}
    case _:
      AgTopOther{}

def aas.top.x(+x: AgX) -> AgTop:
  aas.top.of(aas.k(aas.first(x)), x)

# one expression of an export file, decoded
def aas.top(x: X.Sx) -> AgTop:
  aas.top.x(aas.x(x))

# Counting -----------------------------------------------------------------

# How many AgRaw and AgERaw nodes a tree holds: the forms the decoder kept
# raw.  The decoder is total, and this is how a run checks that what it
# kept raw is only the cubical forms it is meant to leave out.
def aas.raws(a: Ag) -> Nat:
  match a:
    case AgVar{i, x, es}:
      aas.raws(es)
    case AgLam{i, x, d, b}:
      aas.raws(b)
    case AgLit{l}:
      aas.raws(l)
    case AgDef{q, es}:
      aas.raws(es)
    case AgCon{q, o, es}:
      aas.raws(es)
    case AgPi{i, x, s, d, b}:
      Nat.add(aas.raws(s), aas.raws(b))
    case AgSort{s}:
      aas.raws(s)
    case AgLevel{l}:
      aas.raws(l)
    case AgMeta{es}:
      aas.raws(es)
    case AgDontCare{t}:
      aas.raws(t)
    case AgDummy{s, es}:
      aas.raws(es)
    case AgStored{t}:
      aas.raws(t)
    case AgEl{s, t}:
      Nat.add(aas.raws(s), aas.raws(t))
    case AgEApp{i, t, rest}:
      Nat.add(aas.raws(t), aas.raws(rest))
    case AgEProj{q, rest}:
      aas.raws(rest)
    case AgERaw{x, rest}:
      1n+aas.raws(rest)
    case AgSSet{l}:
      aas.raws(l)
    case AgSProp{l}:
      aas.raws(l)
    case AgSSSet{l}:
      aas.raws(l)
    case AgSFun{a, b}:
      Nat.add(aas.raws(a), aas.raws(b))
    case AgSPi{i, x, t, a, b}:
      Nat.add(aas.raws(t), Nat.add(aas.raws(a), aas.raws(b)))
    case AgSUnivOf{s}:
      aas.raws(s)
    case AgSDef{q, es}:
      aas.raws(es)
    case AgLMax{n, ps}:
      aas.raws(ps)
    case AgLPlus{k, t, rest}:
      Nat.add(aas.raws(t), aas.raws(rest))
    case AgTel{x, i, ty, rest}:
      Nat.add(aas.raws(ty), aas.raws(rest))
    case AgCl{tel, ps, body, ty, ca, rest}:
      Nat.add(Nat.add(aas.raws(tel), aas.raws(ps)), Nat.add(Nat.add(aas.raws(body), aas.raws(ty)), aas.raws(rest)))
    case AgPArg{i, x, p, rest}:
      Nat.add(aas.raws(p), aas.raws(rest))
    case AgPDot{t}:
      aas.raws(t)
    case AgPCon{q, r, ps}:
      aas.raws(ps)
    case AgPLit{l}:
      aas.raws(l)
    case AgCase{i, n, b}:
      aas.raws(b)
    case AgDone{xs, t}:
      aas.raws(t)
    case AgBranches{cp, cs, eta, lits, ca}:
      Nat.add(Nat.add(aas.raws(cs), aas.raws(eta)), Nat.add(aas.raws(lits), aas.raws(ca)))
    case AgBr{q, n, t, rest}:
      Nat.add(aas.raws(t), aas.raws(rest))
    case AgLBr{l, t, rest}:
      Nat.add(Nat.add(aas.raws(l), aas.raws(t)), aas.raws(rest))
    case AgRaw{c, x}:
      1n
    case _:
      0n

def aas.d.raws(d: AgD) -> Nat:
  match d:
    case AgDFun{p, r, w, e, t, mu, cls, tree}:
      Nat.add(aas.raws(cls), aas.raws(tree))
    case AgDRec{p, c, nm, ind, fs, tel, eta, pm}:
      aas.raws(tel)
    case AgDData{p, ix, cs, s}:
      aas.raws(s)
    case AgDPrim{nm, cls, tree}:
      Nat.add(aas.raws(cls), aas.raws(tree))
    case _:
      0n

# the AgRaw nodes of a definition's type and details
def aas.decl.raws(d: AgDecl) -> Nat:
  match d:
    case AgDecl{q, nm, mo, f, l, l0, l1, k, m, fl, lang, ty, dd}:
      Nat.add(aas.raws(ty), aas.d.raws(dd))
