# Lean v4.34.0, the one release Bend's `--verdict` accepts (bend2/safe.ts:
# LEAN_VERSION "4.34.0"; the user 2026-11-12: Lean 4.34 in the devShell).
# nixpkgs went 4.30.0 -> 4.34.1 -> 4.35.0 and never shipped 4.34.0, so this
# is nixpkgs' own lean4 package (as of NixOS/nixpkgs d20c388674aa, 4.35.0)
# with the version, the source hash and the vendored mimalloc tag of v4.34.0
# (its CMakeLists.txt: GIT_TAG v3.4.4). Built from source, once.
{
  lib,
  stdenv,
  cmake,
  cctools,
  fetchFromGitHub,
  gitMinimal,
  gmp,
  cadical,
  leangz,
  makeWrapper,
  openssl,
  pkg-config,
  libuv,
  enableMimalloc ? true,
  perl,
  versionCheckHook,
}:
let
  cadical' = cadical.override { version = "2.1.3"; };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "lean4";
  version = "4.34.0";

  __structuredAttrs = true;
  strictDeps = true;

  src = fetchFromGitHub {
    owner = "leanprover";
    repo = "lean4";
    tag = "v${finalAttrs.version}";
    hash = "sha256-cFFGnIeQd+cLtw13jinmO5tMAEW7fpmU2cujk4gQdqs=";
  };

  postPatch =
    let
      pattern = "\${LEAN_BINARY_DIR}/../mimalloc/src/mimalloc";
    in
    ''
      substituteInPlace \
        src/CMakeLists.txt \
        src/runtime/CMakeLists.txt \
        stage0/src/CMakeLists.txt \
        stage0/src/runtime/CMakeLists.txt \
        --replace-fail '${pattern}' '${finalAttrs.mimalloc-src}'
    ''
    # Remove tests that fails in sandbox.
    # It expects `sourceRoot` to be a git repository.
    + ''
      rm -rf src/lake/examples/git/
    '';

  preConfigure = ''
    patchShebangs stage0/src/bin/ src/bin/
  '';

  nativeBuildInputs = [
    cadical'
    cmake
    pkg-config
    makeWrapper
    leangz # Provides leantar
    gitMinimal
  ]
  ++ lib.optionals stdenv.hostPlatform.isDarwin [
    cctools.libtool
  ];

  buildInputs = [
    gmp
    libuv
    openssl
  ];

  postInstall = ''
    wrapProgram $out/bin/lean \
      --prefix PATH : ${cadical'}/bin
  '';

  nativeCheckInputs = [
    gitMinimal
    perl
  ];

  # the mimalloc v4.34.0's CMakeLists.txt names (nixpkgs vendors it: even a
  # slight version change can change Lean's performance a lot)
  mimalloc-src = fetchFromGitHub {
    owner = "microsoft";
    repo = "mimalloc";
    tag = "v3.4.4";
    hash = "sha256-CJ2sOio5cttIG27ZiotaES9X+ymHR5HXWK/O0JUjlC4=";
  };

  cmakeFlags = [
    (lib.cmakeBool "USE_GITHASH" false)
    (lib.cmakeBool "INSTALL_LICENSE" false)
    (lib.cmakeBool "INSTALL_CADICAL" false)
    (lib.cmakeBool "USE_MIMALLOC" enableMimalloc)
    (lib.cmakeFeature "FETCHCONTENT_SOURCE_DIR_MIMALLOC" finalAttrs.mimalloc-src.outPath)
  ];

  nativeInstallCheckInputs = [
    versionCheckHook
  ];
  doInstallCheck = true;

  meta = {
    description = "Automatic and interactive theorem prover (v4.34.0, for Bend's --verdict)";
    homepage = "https://leanprover.github.io/";
    license = lib.licenses.asl20;
    platforms = lib.platforms.all;
    mainProgram = "lean";
  };
})
