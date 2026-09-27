# Used by "mix format"
locals_without_parens = [initial: 1, state: 2, state: 3, final: 1, on: 2, decide: 1]

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
