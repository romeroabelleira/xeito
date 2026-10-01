# Used by "mix format"
locals_without_parens = [
  # Xeito.Machine
  initial: 1,
  state: 2,
  state: 3,
  final: 1,
  on: 2,
  decide: 1,
  decide: 2,
  # Xeito.Decision
  instructions: 1,
  input: 1,
  input: 2,
  value: 2,
  rule: 1,
  rule: 2,
  deciders: 1,
  min_confidence: 1,
  severity: 2,
  policy: 1
]

[
  plugins: [Styler],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
