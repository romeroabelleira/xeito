# Dialyzer warnings accepted on purpose; keep this list short and explained.
[
  # The CRAP gate (test/support, analysed when MIX_ENV=test as in CI) calls :cover, from OTP's
  # tools application, whose modules carry no type information Dialyzer can read here.
  {"test/support/xeito/crap.ex", :unknown_function}
]
