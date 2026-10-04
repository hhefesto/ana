# a training id -> the repository (or package) it came from, folded so forks and
# owner prefixes meet: hackage:pkg/.. -> pkg; repo:owner__name/.. or repo:name/.. -> name;
# curated:/own:name/.. -> name; hf:<dataset>:owner/repo/.. -> repo; other hf:<dataset>/.. -> hf:<dataset>
def repo_of(i: str) -> str:
    i = i.split("#", 1)[0]
    if i.startswith("hf:"):
        rest = i[3:]
        if ":" in rest:                       # hf:blastwind/github-code-haskell-file:owner/repo/path
            parts = rest.split(":", 1)[1].split("/")
            return parts[1].lower() if len(parts) > 1 else parts[0].lower()
        return "hf:" + rest.split("/")[0].lower()
    ns, _, rest = i.partition(":") if ":" in i else ("", "", i)
    name = rest.split("/", 1)[0]
    return name.split("__", 1)[-1].lower().removesuffix(".git")
def path_of(i: str) -> str:
    i = i.split("#", 1)[0]
    if i.startswith("hf:") and ":" in i[3:]:
        return "/".join(i[3:].split(":", 1)[1].split("/")[2:])
    rest = i.split(":", 1)[1] if ":" in i else i
    return rest.split("/", 1)[1] if "/" in rest else ""
