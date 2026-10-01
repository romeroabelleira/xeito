defmodule Mix.Tasks.Xeito.ChatTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Xeito.Chat

  test "a typed line becomes a review answer, a prompt, or nothing" do
    assert Chat.request_for("y", "ses-1") == %{"cmd" => "approve", "session" => "ses-1"}
    assert Chat.request_for("n", "ses-1") == %{"cmd" => "deny", "session" => "ses-1"}
    assert Chat.request_for("/help", "ses-1") == %{"cmd" => "prompt", "session" => "ses-1", "text" => "/help"}
    assert Chat.request_for("", "ses-1") == nil
  end

  test "opening starts a session in the workspace, or attaches to one" do
    cwd = Path.expand("w")
    assert Chat.open_request(cwd: "w") == %{"cmd" => "start", "cwd" => cwd}
    assert Chat.open_request(session: "ses-1", cwd: "w") == %{"cmd" => "attach", "session" => "ses-1", "cwd" => cwd}
    assert Chat.open_request([]) == %{"cmd" => "start", "cwd" => Path.expand(".")}
  end
end
