import Base

# AD/Trusted.agda: the trusted-analytic interface a backend must supply.
#
# Analytic validity is never derived here: a scalar type comes with a
# derivative relation and the derivatives of exp and rsqrt, and the laws
# relating them are FIELDS -- assumptions a backend states, not theorems
# this specification proves.  Bend2's F32 is axiomatic ("nothing about
# floating point can be proven"), so for the executable carrier this record
# is exactly the trusted base: the semiring laws of Algebra.bend and these
# derivative facts are what the F32 model assumes and the Nat/Bool
# instances of the specification cannot supply.
type TrustedAnalytic<-S: Data> is Type:
  TrustedAnalytic{
    has_derivative: (S -> S) -> (S -> S) -> Type,
    mul: S -> S -> S,
    rsqrt_scale: S,
    exp: S -> S,
    rsqrt: S -> S,
    exp_d: S -> S,
    rsqrt_d: S -> S,
    -exp_derivative: has_derivative(exp, exp_d),
    -rsqrt_derivative: has_derivative(rsqrt, rsqrt_d),
    -exp_d_law: @+x:S -> {exp_d(x) == exp(x) : S},
    -rsqrt_d_law: @+x:S -> {rsqrt_d(x) == mul(mul(mul(rsqrt_scale, rsqrt(x)), rsqrt(x)), rsqrt(x)) : S}}
