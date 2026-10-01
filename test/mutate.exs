# Sources held to zero surviving mutants (`mix xeito.mutate`, run by `mix ci`), with the tests
# that cover them. Security and decision logic first: a surviving mutant there is a rule no test
# pins down.
%{
  "lib/xeito/decisions/risk.ex" => ["test/xeito/decision_test.exs"]
}
