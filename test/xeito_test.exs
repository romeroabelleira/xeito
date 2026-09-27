defmodule XeitoTest do
  use ExUnit.Case, async: true
  doctest Xeito

  test "every top-level namespace is a loadable, documented module" do
    for mod <- Xeito.namespaces() do
      assert Code.ensure_loaded?(mod), "#{inspect(mod)} is not loadable"
      assert {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(mod)
      assert doc =~ "docs/architecture/"
    end
  end
end
