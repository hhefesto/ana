# condense an export line for reading: (q "A.B.c" W H) -> A.B.c, drop el sorts,
# INFO -> h/v/i markers
local $/ = "\n";
while (<STDIN>) {
  s/\(q "([^"]+)" \d+ \d+\)/$1/g;
  s/\(el (?:\((?:[^()]|\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\))*\)|\w+) /(: /g;
  s/ visible relevant w / v /g; s/ hidden relevant w / h /g; s/ instance relevant w / i /g;
  s/\(apply v /(@ /g; s/\(apply h /(@h /g;
  print;
}
