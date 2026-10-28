# The GitHub survey of Bend repositories (run 6, 2026-10-28)

    python3 -I survey.py OUT                       # code search `extension:bend size:A..B`, bisected to <= 1000 hits
    python3 -I classify.py OUT KNOWN exclude.txt   # unknown repositories: Bend 2, Bend 1 or no marker
    python3 -I mkcfg.py RUN5CFG NEW.tsv OUT.cfg     # run 6's collect config

- `survey.py`: one code-search request every 6.5 s (the API allows 10 a minute); OUT/files.tsv
  (repo, path, sha) and OUT/repos.tsv (repo, hits).  10-28: 41,113 files in 385 repositories, 59
  leaves, 58 minutes.
- `marks.py`: a file is Bend 2 if it has any Bend 2 marker (`import Base` or a `.bend` import,
  `0n` literals, a typed arrow to a Bend 2 type, `is`, proofs, `&2`), else Bend 1 if it has a
  Bend 1 one (`u24`, `switch`, `bend x =`, `fork(`, `when`, `Ctr/Name`, `object`, HVM rules).
  On run 5's 2,357 files and port's 898: all Bend 2; on 40 of HigherOrderCO/Bend1's: none.
- `classify.py`: GitHub's GraphQL API, 10 repositories a request: metadata and the first, middle
  and last .bend file's text; a repository is Bend 2 if any sample is.  KNOWN is every name the
  corpus holds (runs 2-5's PINS and the corpus files' ids; run6 used /tmp/bx/survey6/known2.txt,
  1,201 names).  10-28: of 272 unknown repositories 166 Bend 2 (76 of them in the corpus by id but
  in no PINS file: never grown), 61 Bend 1, 45 no marker.
- `run6-new.tsv`: mkcfg's input (87 `repo`, 75 `growth`), `run6-classes.tsv` classify's table,
  `run6-repos.tsv` the survey's repositories and hits.
