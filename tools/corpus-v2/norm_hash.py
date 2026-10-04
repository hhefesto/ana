# the shared content key for "already seen": sha256 of the text with CRLF -> LF,
# trailing whitespace stripped from every line, and leading/trailing blank lines dropped
import hashlib
def key(text: str) -> str:
    t = "\n".join(l.rstrip() for l in text.replace("\r\n", "\n").split("\n")).strip("\n")
    return hashlib.sha256(t.encode("utf-8", "replace")).hexdigest()
