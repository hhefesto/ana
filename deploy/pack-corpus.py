#!/usr/bin/env python3
"""pack-corpus.py — concatenate short documents so they survive windowing.

The trainer cuts each document into NON-OVERLAPPING windows of exactly
`contextSize` tokens (FormalTransformer.Data.fullWindows) and discards the
remainder, so a document shorter than one window contributes nothing at all
and every document donates its tail to the floor.  That is survivable at
context 256 and ruinous at 1024: measured over 300,000 documents of
run/mixed-corpus.jsonl, 51.3% of documents fall under the ~4.4 KB needed for a
single window and only 75.5% of all bytes survive the cut, against 93.5% at
context 256.  Measured over a uniform sample of 388,027 documents (every 25th
across all 9.7M of run/mixed-corpus.jsonl), against the same corpus packed to
128 KB -- percentage of bytes that land inside a full window:

                   ctx 256   ctx 512   ctx 1024
    unpacked         82.9%     69.8%      51.9%   (82.4% of documents yield
    packed 128 KB    99.6%     99.2%      98.3%    no window at all at 1024)

At context 1024 that is the difference between ~3.6B and ~7B usable tokens on
this corpus.  Beware measuring it on the head of a file: Wikipedia is
article-ordered with a stub tail, so the first documents run 2.2x larger than
the corpus mean and a head sample understates the loss by half.

The residue after packing is the per-document tail, which is why a bigger
target is always slightly better and why chasing the last percent is not worth
making documents so large that the 90/10 split (a hash of document position)
becomes coarse.  128 KB clears 98% while keeping twice as many documents as
256 KB.

Pair the target with plan-corpus.sh's PER so a shard stays near the ~272 MB of
text the 32,000-document shards of the v2 run proved safe to plan in RAM: at a
128 KB target that is PER=2000, not the 32,000 of an unpacked corpus.

--group-key packs only within a group (repositories, for code corpora), so a
window never straddles two unrelated projects.  Groups must arrive contiguous;
a group that reappears later simply starts a new packed document, which costs
a little packing efficiency and nothing in correctness.
"""

import argparse
import json
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", type=int, default=131072,
                        help="pack until the accumulated text reaches this many bytes (default 131072)")
    parser.add_argument("--prefix", default="pack",
                        help="document id prefix (default 'pack')")
    parser.add_argument("--group-key", default=None,
                        help="only pack documents sharing this JSON field's value")
    parser.add_argument("--separator", default="\n\n",
                        help="text placed between packed pieces (default a blank line)")
    parser.add_argument("--stats", action="store_true",
                        help="write a one-line summary to stderr when done")
    args = parser.parse_args()

    if args.target <= 0:
        parser.error("--target must be positive")

    separator = args.separator
    emitted = 0
    consumed = 0
    held: list[str] = []
    held_bytes = 0
    held_group = None
    out = sys.stdout

    def flush() -> None:
        nonlocal held, held_bytes, held_group, emitted
        if not held:
            return
        record = {"id": "%s-%08d" % (args.prefix, emitted), "text": separator.join(held)}
        out.write(json.dumps(record, ensure_ascii=False))
        out.write("\n")
        emitted += 1
        held = []
        held_bytes = 0
        held_group = None

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        record = json.loads(line)
        text = record.get("text", "")
        if not text:
            continue
        consumed += 1
        group = record.get(args.group_key) if args.group_key else None
        # A group change closes the current pack even when it is nearly empty:
        # mixing repositories inside one window is exactly what --group-key is
        # asked to prevent.
        if held and args.group_key is not None and group != held_group:
            flush()
        if not held:
            held_group = group
        held.append(text)
        held_bytes += len(text.encode("utf-8")) + len(separator)
        if held_bytes >= args.target:
            flush()
    flush()

    if args.stats:
        sys.stderr.write("pack-corpus: %d documents in, %d packed documents out\n"
                         % (consumed, emitted))
    return 0


if __name__ == "__main__":
    sys.exit(main())
