import Base
import ../Extract.bend as X
import ../Sys.bend as S

# Extract: glibc's UTF-8 verdicts (iconv -f UTF-8 -t UTF-8 -c, status 0),
# jq -Rs's replacements, the license rules and the holdout bucket
# (`printf %s NAME | sha256sum | cut -c1-6`, mod 100).  Each line prints
# `ok NAME` or `FAIL NAME`.

def verdict(+name: String, ok: Bool) -> String:
  Bool.pick(String, ok, "ok ", "FAIL ") ++ name

def same(a: Bool, b: Bool) -> Bool:
  match a b:
    case True{} True{}:
      True{}
    case False{} False{}:
      True{}
    case _ _:
      False{}

def utf(+name: String, xs: List<&2, U32>, want: Bool) -> String:
  verdict(name, same(X.utf.valid(xs), want))

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(utf("utf-2", [111, 107, 195, 169], True{}))
    IO.print(utf("utf-overlong2", [97, 192, 128, 98], False{}))
    IO.print(utf("utf-surrogate", [97, 237, 160, 128, 98], False{}))
    IO.print(utf("utf-past-10ffff", [97, 244, 144, 128, 128, 98], True{}))
    IO.print(utf("utf-fe", [97, 254, 98], False{}))
    IO.print(utf("utf-cut", [97, 195], False{}))
    IO.print(utf("utf-fffe", [97, 239, 191, 190, 98], True{}))
    IO.print(utf("utf-overlong3", [97, 224, 128, 175, 98], False{}))
    IO.print(utf("utf-lone-cont", [97, 128, 98], False{}))
    IO.print(utf("utf-f5", [97, 245, 128, 128, 128, 98], True{}))
    IO.print(utf("utf-5byte", [97, 248, 136, 128, 128, 128, 98], True{}))
    IO.print(utf("utf-5byte-overlong", [97, 248, 128, 128, 128, 128, 98], False{}))
    IO.print(utf("utf-6byte", [97, 253, 191, 191, 191, 191, 191, 98], True{}))
    IO.print(utf("utf-4cut", [97, 244, 144, 128, 98], False{}))
    IO.print(utf("utf-overlong4", [97, 240, 128, 128, 128, 98], False{}))
    IO.print(utf("utf-emoji", [97, 240, 159, 152, 128], True{}))
    IO.print(verdict("jq-past-10ffff", S.eq(X.jq.text([97, 244, 144, 128, 128, 98]), [97, 239, 191, 189, 98])))
    IO.print(verdict("jq-f5", S.eq(X.jq.text([97, 245, 128, 128, 128, 98]), [97, 239, 191, 189, 239, 191, 189, 239, 191, 189, 239, 191, 189, 98])))
    IO.print(verdict("jq-5byte", S.eq(X.jq.text([248, 136, 128, 128, 128]), [239, 191, 189, 239, 191, 189, 239, 191, 189, 239, 191, 189, 239, 191, 189])))
    IO.print(verdict("jq-emoji", S.eq(X.jq.text([97, 240, 159, 152, 128, 244, 143, 191, 191]), [97, 240, 159, 152, 128, 244, 143, 191, 191])))
    IO.print(verdict("license-line", S.eq(X.lic.value([S.b("name: x"), S.b("License:   BSD3\r"), S.b("license: MIT")]), S.b("BSD3"))))
    IO.print(verdict("license-permissive", Bool.and(Bool.and(X.permissive(S.b("BSD-3-Clause")), X.permissive(S.b("Apache 2.0"))), X.permissive(S.b("MIT ")))))
    IO.print(verdict("license-refused", Bool.not(Bool.or(Bool.or(X.permissive(S.b("GPL-3")), X.permissive(S.b("bsd3\t"))), X.permissive(Nil{})))))
    IO.print(verdict("text-mit", X.lic.text.ok(S.b("Copyright (c) 2020\n\nPermission is hereby granted, FREE of charge, to any person"))))
    IO.print(verdict("text-gpl", Bool.not(X.lic.text.ok(S.b("MIT License\nbut really: GNU General Public License")))))
    IO.print(verdict("text-spdx", Bool.not(X.lic.text.ok(S.b("SPDX-License-Identifier: MIT\nSPDX-License-Identifier: Apache-2.0 OR LGPL-2.1\nApache License")))))
    IO.print(verdict("text-spdx-lines", X.lic.text.ok(S.b("SPDX-License-Identifier: Apache-2.0\nApache License\nnot gpl here? gpl"))))
    IO.print(verdict("text-cc-by-sa", Bool.not(X.lic.text.ok(S.b("Attribution 4.0 International ShareAlike")))))
    IO.print(verdict("text-none", Bool.not(X.lic.text.ok(Nil{}))))
    IO.print(verdict("bucket", Bool.and(Bool.and(X.hold.bucket(S.b("cubical"), 7n), Bool.not(X.hold.bucket(S.b("cubical"), 6n))),
      Bool.and(X.hold.bucket(S.b("foo"), 93n), Bool.not(X.hold.bucket(S.b("foo"), 92n))))))
    IO.print(verdict("ext", Bool.and(Bool.and(X.ext.ok(S.b("a/B.HS")), X.ext.ok(S.b("x.lagda.md"))), Bool.not(Bool.or(X.ext.ok(S.b("a.hs.orig")), X.ext.ok(S.b("ahs")))))))
    IO.print(verdict("names", Bool.and(S.eq(X.before.last(X.before.last(S.b("foo-bar-1.0.tar.gz"), 46), 46), S.b("foo-bar-1.0")),
      S.eq(X.before.last(S.b("foo-bar-1.0"), 45), S.b("foo-bar")))))
