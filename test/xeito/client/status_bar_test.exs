defmodule Xeito.Client.StatusBarTest do
  use ExUnit.Case, async: true

  alias Xeito.Client.StatusBar

  # Only the named segments, on one wide line.
  defp only(names, monitor, workspace \\ nil),
    do: StatusBar.line(StatusBar.new(), monitor, workspace, StatusBar.segments() -- names, 500)

  defp models(models), do: only(~w(models), %{"models" => models})

  describe "the models segment" do
    test "the large tier: loaded (with its unload countdown), idle, down, or not configured" do
      loaded = %{"configured" => true, "up" => true, "loaded" => [%{"name" => "big", "unload_in_s" => 125}]}
      assert models(%{"large" => loaded}) == "large big unload 2:05"
      assert models(%{"large" => %{"configured" => true, "up" => true, "loaded" => [%{"name" => "big"}]}}) == "large big"
      assert models(%{"large" => %{"configured" => true, "up" => true, "loaded" => []}}) == "large idle (not loaded)"
      assert models(%{"large" => %{"configured" => true, "up" => false}}) == "large ✗ down"
      assert models(%{"large" => %{"configured" => false}}) == ""
    end

    test "the small tier with its busy slots, and System One: up or down" do
      assert models(%{"small" => %{"configured" => true, "up" => true, "slots" => 2, "busy" => 1}}) == "small ✓ 1/2"
      assert models(%{"small" => %{"configured" => true, "up" => true}}) == "small ✓"
      assert models(%{"small" => %{"configured" => true, "up" => false}}) == "small ✗"
      assert models(%{"system_one" => %{"configured" => true, "up" => true}}) == "S1 ✓"
      assert models(%{"system_one" => %{"configured" => true, "up" => false}}) == "S1 ✗"
    end

    test "nothing before the monitor's first snapshot" do
      assert only(~w(models), nil) == ""
    end
  end

  test "before the monitor's first snapshot, the GPU segment says it is waiting" do
    assert only(~w(gpu), nil) == "status: waiting for the daemon's monitor…"
  end

  test "a missing workspace is flagged in the git segment" do
    assert only(~w(git), nil, %{"missing" => true}) == "⚠ workspace missing"
  end
end
