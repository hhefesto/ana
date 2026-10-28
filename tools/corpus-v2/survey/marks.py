import re
B1 = {'u24':r'\b[uif]24\b','switch':r'^\s*switch\b','bendkw':r'^\s*bend \w','fork':r'\bfork\(','when':r'^\s*when\b','slash':r'\b[A-Z]\w*/[A-Z]\w*','return':r'^\s+return\b','object':r'^object\b','lam':r'\blambda\b|λ','with':r'^\s*with \w+:','hvm':r'^\(\w.*\)\s*=','open':r'^\s*open \w'}
B2 = {'nat':r'\b\d+n\b','arrow2':r'->\s*(Nat|U32|I32|F32|Bool|String|Char|List<|Set\b|Type\b|Unit\b|Maybe<|Pair<|Vec<)','import':r'^import (Base\b|\S+\.bend\b)','is':r'^\s*type \w+.*\bis\b|\bis Data\b','proof':r'@unsafe|\?goal|ALL PROOFS|^law |^prop ','amp':r'&\d|<&','sigma':r'\bΣ|\bSigma\b'}
def score(t):
    a = {k for k, p in B1.items() if re.search(p, t, re.M)}
    b = {k for k, p in B2.items() if re.search(p, t, re.M)}
    return a, b
def kind(t):
    a, b = score(t)
    if b: return 2
    if a & {'u24','switch','bendkw','fork','when','slash','object','hvm','open','with'}: return 1
    return 0
