defmodule Xeito.SessionSystemPromptTest do
  @moduledoc "The system prompt a session builds from the project's AGENTS.md."
  use ExUnit.Case, async: true

  alias Xeito.Machines.Chat
  alias Xeito.Session

  setup do
    dir = Path.join(System.tmp_dir!(), "xeito-sys-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "without AGENTS.md, the default system prompt", %{dir: dir} do
    assert Session.system_prompt(dir) == Chat.default_system()
  end

  test "AGENTS.md follows the default prompt whole", %{dir: dir} do
    File.write!(Path.join(dir, "AGENTS.md"), "Use tabs.")
    assert Session.system_prompt(dir) == Chat.default_system() <> "\nProject context (AGENTS.md):\n\nUse tabs."
  end

  test "a longer AGENTS.md is cut at 16 KiB, and the model is told so", %{dir: dir} do
    File.write!(Path.join(dir, "AGENTS.md"), String.duplicate("a", 16_384) <> "THE REST")
    prompt = Session.system_prompt(dir)
    refute prompt =~ "THE REST"
    assert prompt =~ String.duplicate("a", 16_384) <> "\n\n[AGENTS.md continues: cut at 16384 bytes here."
  end

  test "exactly 16 KiB is not cut", %{dir: dir} do
    File.write!(Path.join(dir, "AGENTS.md"), String.duplicate("a", 16_384))
    refute Session.system_prompt(dir) =~ "AGENTS.md continues"
  end
end
