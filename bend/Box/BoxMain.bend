import Base
import ./OnBox.bend as Ob

# bend-box: the driver on a rented GPU box (bend/Box/OnBox.bend has the
# modes; 2026-10-14, the plan's Phase 1b).  It ships as C and is built on
# the box with its own clang, as traind is:
#
#   bend bend/Box/BoxMain.bend -o box.c
#   clang -std=c11 -O3 box.c -lpthread -lm -o bend-box
#
# (`bend-ops stage box` does both), so a box needs no nix and no root.

def main() -> IO(Unit):
  do IO<Unit>:
    # IO.args leads with the program as invoked (eval-both starts itself again)
    argv : List<String> <- IO.args()
    +xs : List<&2, String> = Ob.obx.l2(argv)
    Ob.obx.main(Maybe.default(&2, String, List.head(&2, String, xs), "bend-box"), List.drop(&2, String, xs, 1n))
