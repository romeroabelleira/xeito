defmodule Xeito.Session.InputTest do
  @moduledoc "The system prompt a session builds from the project's AGENTS.md."
  use ExUnit.Case, async: true

  alias Xeito.Machines.Chat
  alias Xeito.Session.Input

  @moduletag :tmp_dir

  test "without AGENTS.md, the default system prompt", %{tmp_dir: dir} do
    assert Input.system_prompt(dir) == Chat.default_system()
  end

  test "AGENTS.md follows the default prompt whole", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "AGENTS.md"), "Use tabs.")
    assert Input.system_prompt(dir) == Chat.default_system() <> "\nProject context (AGENTS.md):\n\nUse tabs."
  end

  test "a longer AGENTS.md is cut at 16 KiB, and the model is told so", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "AGENTS.md"), String.duplicate("a", 16_384) <> "THE REST")
    prompt = Input.system_prompt(dir)
    refute prompt =~ "THE REST"
    assert prompt =~ String.duplicate("a", 16_384) <> "\n\n[AGENTS.md continues: cut at 16384 bytes here."
  end

  test "exactly 16 KiB is not cut", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "AGENTS.md"), String.duplicate("a", 16_384))
    refute Input.system_prompt(dir) =~ "AGENTS.md continues"
  end
end
