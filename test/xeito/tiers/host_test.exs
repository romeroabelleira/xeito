defmodule Xeito.Tiers.HostTest do
  use ExUnit.Case, async: true

  alias Xeito.Tiers.Host

  # This machine has one address besides loopback; names resolve through the test's table.
  @own [{198, 51, 100, 3}, {0xFD00, 0, 0, 0, 0, 0, 0, 7}]
  @names %{
    "box.test" => [{198, 51, 100, 3}],
    "elsewhere.test" => [{192, 0, 2, 7}],
    "both.test" => [{127, 0, 0, 1}, {192, 0, 2, 7}]
  }

  defp local?(url, allowed \\ []), do: Host.local?(url, own: @own, allowed: allowed, resolve: &Map.get(@names, &1, []))

  describe "local?/2: whether a URL's host is this machine" do
    test "loopback addresses and names are" do
      assert local?("http://127.0.0.1:8000")
      assert local?("http://127.8.9.10:8000/v1")
      assert local?("http://[::1]:8000")
      assert local?("http://localhost:11434")
      assert local?("http://LocalHost:11434")
      assert local?("http://colibri.localhost:8000")
    end

    test "one of the machine's own addresses is" do
      assert local?("http://198.51.100.3:8000")
      assert local?("http://[fd00::7]:8000")
    end

    test "another machine's address is not, even one next to ours" do
      refute local?("http://198.51.100.4:8000")
      refute local?("http://192.0.2.7:8000")
      refute local?("http://128.0.0.1:8000")
      refute local?("http://[fd00::8]:8000")
      refute local?("http://[::2]:8000")
    end

    test "a name is, when every address it resolves to is this machine" do
      assert local?("http://box.test:8000")
      refute local?("http://elsewhere.test:8000")
      refute local?("http://both.test:8000")
    end

    test "a name that does not resolve is not, nor one that only ends like localhost" do
      refute local?("http://unknown.test:8000")
      refute local?("http://notlocalhost:8000")
    end

    test "a listed host is, by name or address, whatever its case" do
      assert local?("http://colibri:8000", ["colibri"])
      assert local?("http://Colibri:8000", ["ollama", "colibri"])
      assert local?("http://192.0.2.7:8000", ["192.0.2.7"])
      refute local?("http://colibri2:8000", ["colibri"])
    end

    test "a URL without a host is not" do
      refute local?("/run/model.sock")
      refute local?("")
    end
  end

  describe "allowed/1: the hosts XEITO_LOCAL_HOSTS lists" do
    test "a comma list, trimmed and lower-cased; unset is none" do
      assert Host.allowed(nil) == []
      assert Host.allowed("Colibri, 192.0.2.7,,") == ["colibri", "192.0.2.7"]
    end
  end

  describe "resolve/2: a name's addresses" do
    test "both families count, so a name with an address elsewhere in either is not this machine" do
      lookup = fn
        ~c"dual.test", :inet -> {:ok, [{127, 0, 0, 1}]}
        ~c"dual.test", :inet6 -> {:ok, [{0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}]}
        ~c"four.test", :inet -> {:ok, [{192, 0, 2, 7}]}
        _name, _family -> {:error, :nxdomain}
      end

      assert Host.resolve("dual.test", lookup) == [{127, 0, 0, 1}, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}]
      assert Host.resolve("four.test", lookup) == [{192, 0, 2, 7}]
      assert Host.resolve("none.test", lookup) == []
      refute Host.local?("http://dual.test", own: [], resolve: &Host.resolve(&1, lookup))
    end

    test "a URL with an empty host is not this machine" do
      refute Host.local?("http://:8000", own: [], resolve: fn "" -> [] end)
    end
  end

  test "own_addresses/0 holds what the machine's interfaces have" do
    assert Enum.all?(Host.own_addresses(), &is_tuple/1)
    assert {127, 0, 0, 1} in Host.own_addresses()
  end

  test "without options, loopback is local and a documentation address is not" do
    assert Host.local?("http://127.0.0.1:1")
    refute Host.local?("http://192.0.2.7:1")
  end
end
