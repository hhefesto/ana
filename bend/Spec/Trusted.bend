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

# The log Spec/Distance.bend reads the trainer through (2026-11-17): at the
# executable carrier, -ln as a Log from probabilities (F32, *, 1) to costs
# (F32, +, 0), and the trainer head's per-prediction formula as -ln of the
# softmax: -ln(exp(l_t) / z) = ln z - l_t, with ln z the log-sum-exp the
# head computes as max + ln sum exp(l - max).  Assumed fields, as above:
# Bend2 proves nothing about F32, and at F32 these hold only up to rounding
# (tests/bradley.bend measures how far, on random weights and on a
# checkpoint).  Spec/Terminating.bend's stochastic law at F32, that the
# softmax's weights sum to one, is of the same kind.
type TrustedLog<-S: Data> is Type:
  TrustedLog{
    one: S,
    zero: S,
    mul: S -> S -> S,
    add: S -> S -> S,
    sub: S -> S -> S,
    div: S -> S -> S,
    exp: S -> S,
    ln: S -> S,
    nl: S -> S,
    -nl_def: @+x:S -> {nl(x) == sub(zero, ln(x)) : S},
    -nl_one: {nl(one) == zero : S},
    -nl_mul: @+x:S -> @+y:S -> {nl(mul(x, y)) == add(nl(x), nl(y)) : S},
    -nl_softmax: @+l:S -> @+z:S -> {nl(div(exp(l), z)) == sub(ln(z), l) : S}}
