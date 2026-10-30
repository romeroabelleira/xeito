defmodule Xeito.Client.ConfigTest do
  # Changes environment variables.
  use ExUnit.Case, async: false

  alias Xeito.Client.Config

  setup do
    saved = Map.new(~w(XEITO_TUI_CONFIG XDG_CONFIG_HOME), &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {name, value} <- saved, do: if(value, do: System.put_env(name, value), else: System.delete_env(name))
    end)
  end

  test "path/0: $XEITO_TUI_CONFIG, else $XDG_CONFIG_HOME/xeito, else ~/.config/xeito" do
    System.put_env("XEITO_TUI_CONFIG", "/x/tui.json")
    assert Config.path() == "/x/tui.json"

    System.delete_env("XEITO_TUI_CONFIG")
    System.put_env("XDG_CONFIG_HOME", "/xdg")
    assert Config.path() == "/xdg/xeito/tui.json"

    System.delete_env("XDG_CONFIG_HOME")
    assert Config.path() == Path.expand("~/.config/xeito/tui.json")
  end

  @tag :tmp_dir
  test "load/1 and save/2: preferences are merged over the defaults; a file that is not JSON reads as them",
       %{tmp_dir: root} do
    file = Path.join(root, "cfg/tui.json")

    assert %{"status_bar" => %{"visible" => true, "hidden" => []}} =
             Config.load(file)

    :ok =
      Config.save(
        %{"status_bar" => %{"visible" => false, "hidden" => ["cpu"]}},
        file
      )

    assert %{"status_bar" => %{"visible" => false, "hidden" => ["cpu"]}} =
             Config.load(file)

    File.write!(file, "not json")
    assert %{"status_bar" => %{"visible" => true}} = Config.load(file)
  end
end
