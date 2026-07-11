# Trusted Base

The trusted base is intentionally visible rather than hidden behind a claim of
total verification.

- Agda kernel and standard library.
- Law instances supplied to the small algebraic records.
- Analytic derivative witnesses supplied through `TrustedAnalytic`.
- Haskell `Double`, `Numeric.AD`, `binary`, and the runtime system.
- Futhark's `vjp2`, compiler, generated C/OpenCL runtime, and OpenCL stack.
- The numeric tolerance relation used by the conformance oracle.
- Filesystem atomic rename semantics for checkpoint and corpus replacement.
- The non-cryptographic dataset fingerprint is an accidental-mismatch detector,
  not a security boundary.

Generated kernels are derived from `backend/futhark/kernels.fut`; generated C,
headers, and JSON are not authoritative source files.
