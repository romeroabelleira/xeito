defmodule Xeito.UndoTest do
  use ExUnit.Case, async: true

  alias Xeito.Undo

  setup do
    ws = Path.join(System.tmp_dir!(), "xeito-undo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf(ws) end)
    %{ws: ws}
  end

  defp put(ws, path, text) do
    file = Path.join(ws, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, text)
  end

  defp get(ws, path), do: File.read(Path.join(ws, path))

  # One agent step: `fun` changes the workspace.
  defp step(ws, id, label, fun, opts \\ []), do: Undo.step(ws, id, label, fun, opts)

  defp git(ws, args), do: ws |> then(&System.cmd("git", args, cd: &1, stderr_to_stdout: true)) |> elem(0)

  test "steps are undone newest first and redone oldest first", %{ws: ws} do
    put(ws, "a.txt", "0\n")

    assert :result =
             step(ws, "ses-a/t1/e1", "edit a.txt", fn ->
               put(ws, "a.txt", "1\n")
               :result
             end)

    step(ws, "ses-a/t1/e2", "write sub/b.txt", fn -> put(ws, "sub/b.txt", "b\n") end)
    step(ws, "ses-a/t2/e1", "bash rm a.txt", fn -> File.rm!(Path.join(ws, "a.txt")) end)

    assert [%{id: "ses-a/t2/e1", label: "bash rm a.txt"}, %{id: "ses-a/t1/e2"}, %{id: "ses-a/t1/e1"}] =
             Undo.steps(ws, "ses-a")

    assert {:ok, [%{label: "bash rm a.txt"}, %{label: "write sub/b.txt"}]} = Undo.undo(ws, "ses-a", 2)
    assert get(ws, "a.txt") == {:ok, "1\n"}
    assert get(ws, "sub/b.txt") == {:error, :enoent}
    assert [%{id: "ses-a/t1/e1"}] = Undo.steps(ws, "ses-a")

    assert {:ok, [%{label: "write sub/b.txt"}]} = Undo.redo(ws, "ses-a", 1)
    assert get(ws, "sub/b.txt") == {:ok, "b\n"}
    assert {:ok, [%{label: "bash rm a.txt"}]} = Undo.redo(ws, "ses-a", 1)
    assert get(ws, "a.txt") == {:error, :enoent}

    assert {:ok, [_, _, _]} = Undo.undo(ws, "ses-a", 3)
    assert get(ws, "a.txt") == {:ok, "0\n"}
    assert Undo.steps(ws, "ses-a") == []
  end

  test "a step that changes nothing is not a step", %{ws: ws} do
    put(ws, "a.txt", "0\n")
    step(ws, "ses-a/t1/e1", "bash ls", fn -> :ok end)
    assert Undo.steps(ws, "ses-a") == []
    assert Undo.undo(ws, "ses-a", 1) == {:error, :nothing_to_undo}
    assert Undo.redo(ws, "ses-a", 1) == {:error, :nothing_to_redo}
  end

  test "more steps than there are is an error, and nothing changes", %{ws: ws} do
    step(ws, "ses-a/t1/e1", "write a.txt", fn -> put(ws, "a.txt", "1\n") end)
    assert Undo.undo(ws, "ses-a", 2) == {:error, {:only, 1}}
    assert get(ws, "a.txt") == {:ok, "1\n"}
  end

  test "what the user changed since is kept; a step whose lines they changed is refused", %{ws: ws} do
    put(ws, "a.txt", "0\n")
    step(ws, "ses-a/t1/e1", "edit a.txt", fn -> put(ws, "a.txt", "1\n") end)
    step(ws, "ses-a/t1/e2", "write b.txt", fn -> put(ws, "b.txt", "b\n") end)
    put(ws, "mine.txt", "mine\n")
    put(ws, "a.txt", "user\n")

    assert Undo.undo(ws, "ses-a", 2) == {:error, {:conflict, %{id: "ses-a/t1/e1", label: "edit a.txt"}}}
    assert get(ws, "b.txt") == {:ok, "b\n"}
    assert get(ws, "a.txt") == {:ok, "user\n"}

    assert {:ok, [%{label: "write b.txt"}]} = Undo.undo(ws, "ses-a", 1)
    assert get(ws, "b.txt") == {:error, :enoent}
    assert get(ws, "mine.txt") == {:ok, "mine\n"}
  end

  test "without a snapshot of the workspace now (too many files), nothing is undone", %{ws: ws} do
    step(ws, "ses-a/t1/e1", "write a.txt", fn -> put(ws, "a.txt", "a\n") end)
    put(ws, "b.txt", "b\n")
    assert Undo.undo(ws, "ses-a", 1, max_files: 1) == {:error, :unavailable}
    assert get(ws, "a.txt") == {:ok, "a\n"}
    assert [_] = Undo.steps(ws, "ses-a")
  end

  test "a new step clears what could be redone", %{ws: ws} do
    step(ws, "ses-a/t1/e1", "write a.txt", fn -> put(ws, "a.txt", "1\n") end)
    {:ok, _} = Undo.undo(ws, "ses-a", 1)
    step(ws, "ses-a/t2/e1", "write b.txt", fn -> put(ws, "b.txt", "b\n") end)
    assert Undo.redo(ws, "ses-a", 1) == {:error, :nothing_to_redo}
  end

  test "each session undoes only its own steps", %{ws: ws} do
    step(ws, "ses-a/t1/e1", "write a.txt", fn -> put(ws, "a.txt", "a\n") end)
    step(ws, "ses-b/t1/e1", "write b.txt", fn -> put(ws, "b.txt", "b\n") end)

    assert {:ok, [%{label: "write a.txt"}]} = Undo.undo(ws, "ses-a", 1)
    assert get(ws, "a.txt") == {:error, :enoent}
    assert get(ws, "b.txt") == {:ok, "b\n"}
  end

  test "in a git project, the project's own index, HEAD and stash are untouched", %{ws: ws} do
    git(ws, ~w(init -q))
    put(ws, ".gitignore", "ignored.txt\n")
    put(ws, "a.txt", "0\n")
    git(ws, ~w(add -A))
    git(ws, ~w(-c user.name=t -c user.email=t@t commit -q -m init))
    head = git(ws, ~w(rev-parse HEAD))

    step(ws, "ses-a/t1/e1", "edit a.txt", fn -> put(ws, "a.txt", "1\n") end)
    {:ok, _} = Undo.undo(ws, "ses-a", 1)

    assert git(ws, ~w(rev-parse HEAD)) == head
    assert git(ws, ~w(status --porcelain)) == ""
    assert git(ws, ~w(stash list)) == ""
  end

  test "files the project ignores are captured (.env); ignored directories and .xeito are not", %{ws: ws} do
    put(ws, ".gitignore", ".env\nout/\n*.log\n")

    step(ws, "ses-a/t1/e1", "bash setup", fn ->
      put(ws, ".env", "SECRET=1\n")
      put(ws, "sub/run.log", "log\n")
      put(ws, "out/build", "built\n")
    end)

    step(ws, "ses-a/t1/e2", "write out/more", fn -> put(ws, "out/more", "x\n") end)
    step(ws, "ses-a/t1/e3", "write .xeito/x", fn -> put(ws, ".xeito/x", "x\n") end)
    assert [%{id: "ses-a/t1/e1"}] = Undo.steps(ws, "ses-a")

    {:ok, _} = Undo.undo(ws, "ses-a", 1)
    assert get(ws, ".env") == {:error, :enoent}
    assert get(ws, "sub/run.log") == {:error, :enoent}
    assert get(ws, "out/build") == {:ok, "built\n"}
  end

  test "an ignored file the agent deletes comes back on undo; one over the size limit is left out", %{ws: ws} do
    # .env is exactly at the limit, so it is captured.
    secret = String.duplicate("s", 1_000)
    put(ws, ".gitignore", ".env\n*.bin\n")
    put(ws, ".env", secret)
    put(ws, "big.bin", String.duplicate("x", 1_001))
    step(ws, "ses-a/t1/e1", "bash rm .env", fn -> File.rm!(Path.join(ws, ".env")) end, max_file_bytes: 1_000)

    assert [%{skipped: []}] = Undo.steps(ws, "ses-a")
    {:ok, _} = Undo.undo(ws, "ses-a", 1, max_file_bytes: 1_000)
    assert get(ws, ".env") == {:ok, secret}
  end

  test "ignored files count toward the file limit", %{ws: ws} do
    put(ws, ".gitignore", "*.log\n")
    for i <- 1..3, do: put(ws, "#{i}.log", "#{i}\n")
    step(ws, "ses-a/t1/e1", "write a.txt", fn -> put(ws, "a.txt", "a\n") end, max_files: 3)
    assert Undo.steps(ws, "ses-a") == []
    refute File.exists?(Path.join(ws, ".xeito/undo.git/index"))
  end

  describe "the file limit: a workspace with more files than `max_files` has no undo" do
    defp edit_f1(ws, id, max), do: step(ws, id, "edit f1.txt", fn -> put(ws, "f1.txt", "#{id}\n") end, max_files: max)

    test "up to the limit, steps are recorded; over it, the step runs and nothing is copied", %{ws: ws} do
      for i <- 1..3, do: put(ws, "f#{i}.txt", "#{i}\n")
      edit_f1(ws, "ses-a/t1/e1", 2)
      assert get(ws, "f1.txt") == {:ok, "ses-a/t1/e1\n"}
      assert Undo.steps(ws, "ses-a") == []
      refute File.exists?(Path.join(ws, ".xeito/undo.git/index"))

      edit_f1(ws, "ses-a/t1/e2", 3)
      assert [%{id: "ses-a/t1/e2"}] = Undo.steps(ws, "ses-a")
    end

    test "files already captured count, and so do new ones", %{ws: ws} do
      for i <- 1..2, do: put(ws, "f#{i}.txt", "#{i}\n")
      edit_f1(ws, "ses-a/t1/e1", 2)
      for i <- 3..4, do: put(ws, "f#{i}.txt", "#{i}\n")
      edit_f1(ws, "ses-a/t1/e2", 2)
      assert [%{id: "ses-a/t1/e1"}] = Undo.steps(ws, "ses-a")
    end

    test "files the project ignores do not count", %{ws: ws} do
      put(ws, ".gitignore", "big/\n")
      put(ws, "f1.txt", "1\n")
      for i <- 1..3, do: put(ws, "big/#{i}", "#{i}\n")
      edit_f1(ws, "ses-a/t1/e1", 2)
      assert [%{id: "ses-a/t1/e1"}] = Undo.steps(ws, "ses-a")
    end
  end

  test "steps that cancel out undo to the workspace as it is", %{ws: ws} do
    step(ws, "ses-a/t1/e1", "write a.txt", fn -> put(ws, "a.txt", "a\n") end)
    step(ws, "ses-a/t1/e2", "bash rm a.txt", fn -> File.rm!(Path.join(ws, "a.txt")) end)

    assert Undo.undo(ws, "ses-a", 2) ==
             {:ok,
              [
                %{id: "ses-a/t1/e2", label: "bash rm a.txt", skipped: [], git: nil, outside: []},
                %{id: "ses-a/t1/e1", label: "write a.txt", skipped: [], git: nil, outside: []}
              ]}

    assert get(ws, "a.txt") == {:error, :enoent}
  end

  describe "retention: the store does not grow without bound" do
    defp store(ws), do: Path.join(ws, ".xeito/undo.git")

    # Whether the store holds a file version with this content.
    defp stored?(ws, text) do
      file = Path.join(System.tmp_dir!(), "xeito-blob-#{System.unique_integer([:positive])}")
      File.write!(file, text)
      {sha, 0} = System.cmd("git", ["hash-object", file])
      File.rm!(file)

      {_, status} =
        System.cmd("git", ["--git-dir", store(ws), "cat-file", "-e", String.trim(sha)], stderr_to_stdout: true)

      status == 0
    end

    test "forget/2 drops a session's steps; gc/1 then frees the file versions only they held", %{ws: ws} do
      step(ws, "ses-a/t1/e1", "write a.txt", fn -> put(ws, "a.txt", "only in ses-a\n") end)
      step(ws, "ses-a/t1/e2", "bash rm a.txt", fn -> File.rm!(Path.join(ws, "a.txt")) end)
      step(ws, "ses-b/t1/e1", "write b.txt", fn -> put(ws, "b.txt", "b\n") end)
      {:ok, _} = Undo.undo(ws, "ses-b", 1)

      assert :ok = Undo.forget(ws, "ses-a")
      assert Undo.steps(ws, "ses-a") == []
      assert stored?(ws, "only in ses-a\n")

      assert :ok = Undo.gc(ws)
      refute stored?(ws, "only in ses-a\n")
      assert stored?(ws, "b\n")
      assert {:ok, [%{id: "ses-b/t1/e1"}]} = Undo.redo(ws, "ses-b", 1)
    end

    test "forget and gc of a workspace without a store do nothing", %{ws: ws} do
      assert :ok = Undo.forget(ws, "ses-a")
      assert :ok = Undo.gc(ws)
      refute File.exists?(store(ws))
    end

    test "a session keeps at least its last max_steps steps; older ones are dropped in batches", %{ws: ws} do
      for i <- 1..5 do
        step(ws, "ses-a/t1/e#{i}", "write #{i}.txt", fn -> put(ws, "#{i}.txt", "#{i}\n") end, max_steps: 2)
        assert length(Undo.steps(ws, "ses-a")) == if(i <= 4, do: i, else: 2)
      end

      assert Undo.undo(ws, "ses-a", 3) == {:error, {:only, 2}}
      assert {:ok, [%{id: "ses-a/t1/e5"}, %{id: "ses-a/t1/e4"}]} = Undo.undo(ws, "ses-a", 2)
      assert {get(ws, "3.txt"), get(ws, "4.txt")} == {{:ok, "3\n"}, {:error, :enoent}}
    end

    test "a file over max_file_bytes is not captured, and the step names it", %{ws: ws} do
      write = fn ->
        put(ws, "small.txt", "s\n")
        put(ws, "edge.bin", String.duplicate("e", 1_000))
        put(ws, "big.bin", String.duplicate("x", 1_001))
      end

      step(ws, "ses-a/t1/e1", "bash make", write, max_file_bytes: 1_000)
      assert [%{label: "bash make", skipped: ["big.bin"]}] = Undo.steps(ws, "ses-a")

      assert {:ok, [%{skipped: ["big.bin"]}]} = Undo.undo(ws, "ses-a", 1)
      assert get(ws, "small.txt") == {:error, :enoent}
      assert get(ws, "edge.bin") == {:error, :enoent}
      assert get(ws, "big.bin") == {:ok, String.duplicate("x", 1_001)}
    end

    test "a captured file that grew over the limit cannot be undone, and nothing changes", %{ws: ws} do
      step(ws, "ses-a/t1/e1", "write f.txt", fn -> put(ws, "f.txt", "small\n") end, max_file_bytes: 1_000)

      step(ws, "ses-a/t1/e2", "bash grow", fn -> put(ws, "f.txt", String.duplicate("y", 2_000)) end,
        max_file_bytes: 1_000
      )

      assert [%{skipped: ["f.txt"]}, %{skipped: []}] = Undo.steps(ws, "ses-a")
      assert {:error, {:conflict, %{id: "ses-a/t1/e2"}}} = Undo.undo(ws, "ses-a", 1)
      assert get(ws, "f.txt") == {:ok, String.duplicate("y", 2_000)}
    end
  end

  describe "the project's git: commits the agent made" do
    setup %{ws: ws} do
      git(ws, ~w(init -q -b main))
      put(ws, "base.txt", "base\n")
      commit(ws, "base")
      %{base: head(ws)}
    end

    defp commit(ws, message) do
      git(ws, ~w(add -A))
      git(ws, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", message])
    end

    defp head(ws), do: String.trim(git(ws, ~w(rev-parse HEAD)))

    test "a commit is undone by moving its branch back; its files go too when the step wrote them", %{ws: ws, base: base} do
      step(ws, "ses-a/t1/e1", "bash write and commit", fn ->
        put(ws, "a.txt", "a\n")
        commit(ws, "agent")
      end)

      after_commit = head(ws)
      assert [%{git: %{ref: "refs/heads/main", from: ^base, to: ^after_commit}}] = Undo.steps(ws, "ses-a")

      assert {:ok, [%{git: %{ref: "refs/heads/main"}}]} = Undo.undo(ws, "ses-a", 1)
      assert head(ws) == base
      assert get(ws, "a.txt") == {:error, :enoent}
      assert git(ws, ~w(status --porcelain)) == ""

      assert {:ok, _} = Undo.redo(ws, "ses-a", 1)
      assert head(ws) == after_commit
      assert get(ws, "a.txt") == {:ok, "a\n"}
      assert git(ws, ~w(status --porcelain)) == ""
    end

    test "a step that only committed leaves the changes in the working tree, unstaged", %{ws: ws, base: base} do
      put(ws, "user.txt", "mine\n")
      step(ws, "ses-a/t1/e1", "bash git commit", fn -> commit(ws, "agent") end)

      assert {:ok, _} = Undo.undo(ws, "ses-a", 1)
      assert head(ws) == base
      assert get(ws, "user.txt") == {:ok, "mine\n"}
      assert git(ws, ~w(status --porcelain)) == "?? user.txt\n"
    end

    test "a pushed commit is not undone, and nothing changes", %{ws: ws} do
      step(ws, "ses-a/t1/e1", "bash commit", fn ->
        put(ws, "a.txt", "a\n")
        commit(ws, "agent")
      end)

      pushed = head(ws)
      git(ws, ["update-ref", "refs/remotes/origin/main", pushed])

      assert Undo.undo(ws, "ses-a", 1) == {:error, {:git, %{id: "ses-a/t1/e1", label: "bash commit"}, {:pushed, pushed}}}
      assert head(ws) == pushed
      assert get(ws, "a.txt") == {:ok, "a\n"}
    end

    test "a branch that moved since the step is not moved back", %{ws: ws} do
      step(ws, "ses-a/t1/e1", "bash commit", fn ->
        put(ws, "a.txt", "a\n")
        commit(ws, "agent")
      end)

      put(ws, "later.txt", "later\n")
      commit(ws, "user")
      later = head(ws)

      assert {:error, {:git, %{id: "ses-a/t1/e1"}, :branch_moved}} = Undo.undo(ws, "ses-a", 1)
      assert head(ws) == later
    end

    test "HEAD moved another way (a checkout) is a step that cannot be undone", %{ws: ws} do
      step(ws, "ses-a/t1/e1", "bash git checkout -b other", fn -> git(ws, ~w(checkout -q -b other)) end)

      assert [%{git: :moved}] = Undo.steps(ws, "ses-a")
      assert {:error, {:git, %{id: "ses-a/t1/e1"}, :moved}} = Undo.undo(ws, "ses-a", 1)
      assert String.trim(git(ws, ~w(branch --show-current))) == "other"
    end

    test "several commits over several steps go back together", %{ws: ws, base: base} do
      for i <- 1..2 do
        step(ws, "ses-a/t1/e#{i}", "bash commit #{i}", fn ->
          put(ws, "#{i}.txt", "#{i}\n")
          commit(ws, "agent #{i}")
        end)
      end

      assert {:ok, [_, _]} = Undo.undo(ws, "ses-a", 2)
      assert head(ws) == base
      assert git(ws, ~w(status --porcelain)) == ""
    end

    test "an empty commit is undone without touching what the user staged", %{ws: ws, base: base} do
      step(ws, "ses-a/t1/e1", "bash commit --allow-empty", fn ->
        git(ws, ~w(-c user.name=t -c user.email=t@t commit -q --allow-empty -m empty))
      end)

      put(ws, "staged.txt", "s\n")
      git(ws, ~w(add staged.txt))

      assert {:ok, _} = Undo.undo(ws, "ses-a", 1)
      assert head(ws) == base
      assert git(ws, ~w(status --porcelain)) == "A  staged.txt\n"
    end

    test "commits on a detached HEAD are a move undo leaves to git", %{ws: ws} do
      git(ws, ~w(checkout -q --detach))

      step(ws, "ses-a/t1/e1", "bash commit", fn ->
        put(ws, "a.txt", "a\n")
        commit(ws, "detached")
      end)

      assert [%{git: :moved}] = Undo.steps(ws, "ses-a")
    end

    test "move/2 does not move a branch that moved after the plan was made", %{ws: ws, base: base} do
      step(ws, "ses-a/t1/e1", "bash commit", fn ->
        put(ws, "a.txt", "a\n")
        commit(ws, "agent")
      end)

      [step] = Undo.steps(ws, "ses-a")
      {:ok, move} = Undo.Branch.plan(ws, [step], :undo)
      put(ws, "b.txt", "b\n")
      commit(ws, "user")
      later = head(ws)

      assert Undo.Branch.move(ws, move) == {:error, :changed}
      assert head(ws) == later
      refute head(ws) == base
    end
  end

  describe "named paths outside the workspace (`:outside`)" do
    setup %{ws: ws} do
      outside = ws <> "-outside"
      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf(outside) end)
      %{outside: outside, notes: Path.join(outside, "notes.txt")}
    end

    test "a file the step changed is restored by undo, and put back by redo", %{ws: ws, notes: notes} do
      File.write!(notes, "old\n")
      step(ws, "ses-a/t1/e1", "bash sed notes", fn -> File.write!(notes, "new\n") end, outside: [notes])

      assert [%{outside: [^notes]}] = Undo.steps(ws, "ses-a")
      assert {:ok, [%{outside: [^notes]}]} = Undo.undo(ws, "ses-a", 1)
      assert File.read!(notes) == "old\n"
      assert {:ok, _} = Undo.redo(ws, "ses-a", 1)
      assert File.read!(notes) == "new\n"
    end

    test "a file the step created is removed by undo; one it deleted comes back", %{
      ws: ws,
      outside: outside,
      notes: notes
    } do
      created = Path.join(outside, "sub/new.txt")
      File.write!(notes, "kept\n")

      step(
        ws,
        "ses-a/t1/e1",
        "bash",
        fn ->
          File.mkdir_p!(Path.dirname(created))
          File.write!(created, "new\n")
          File.rm!(notes)
        end,
        outside: [created, notes]
      )

      assert {:ok, _} = Undo.undo(ws, "ses-a", 1)
      refute File.exists?(created)
      assert File.read!(notes) == "kept\n"
      assert {:ok, _} = Undo.redo(ws, "ses-a", 1)
      assert File.read!(created) == "new\n"
      refute File.exists?(notes)
    end

    test "named paths the step did not change are not part of it", %{ws: ws, notes: notes} do
      File.write!(notes, "same\n")
      step(ws, "ses-a/t1/e1", "bash nothing", fn -> :ok end, outside: [notes])
      assert Undo.steps(ws, "ses-a") == []

      step(ws, "ses-a/t1/e2", "write a.txt", fn -> put(ws, "a.txt", "a\n") end, outside: [notes])
      assert [%{outside: []}] = Undo.steps(ws, "ses-a")
    end

    test "an outside file changed since is not restored, and nothing changes", %{ws: ws, notes: notes} do
      File.write!(notes, "old\n")

      step(
        ws,
        "ses-a/t1/e1",
        "bash both",
        fn ->
          File.write!(notes, "new\n")
          put(ws, "a.txt", "a\n")
        end,
        outside: [notes]
      )

      File.write!(notes, "user\n")
      assert Undo.undo(ws, "ses-a", 1) == {:error, {:outside_changed, %{id: "ses-a/t1/e1", label: "bash both"}, notes}}
      assert File.read!(notes) == "user\n"
      assert get(ws, "a.txt") == {:ok, "a\n"}
    end

    test "steps over the same file go back to before the oldest", %{ws: ws, notes: notes} do
      File.write!(notes, "0\n")
      for i <- 1..2, do: step(ws, "ses-a/t1/e#{i}", "bash #{i}", fn -> File.write!(notes, "#{i}\n") end, outside: [notes])

      assert {:ok, [_, _]} = Undo.undo(ws, "ses-a", 2)
      assert File.read!(notes) == "0\n"
    end

    test "a directory, or a file over the size limit, is not backed up", %{ws: ws, outside: outside, notes: notes} do
      File.write!(notes, "small\n")

      step(ws, "ses-a/t1/e1", "bash grow", fn -> File.write!(notes, String.duplicate("x", 20)) end,
        outside: [notes],
        max_file_bytes: 10
      )

      step(ws, "ses-a/t1/e2", "bash mkdir", fn -> File.mkdir_p!(Path.join(outside, "d/e")) end,
        outside: [Path.join(outside, "d")]
      )

      assert Undo.steps(ws, "ses-a") == []

      # Exactly at the limit is still backed up.
      File.write!(notes, String.duplicate("e", 10))
      step(ws, "ses-a/t1/e3", "bash edge", fn -> File.write!(notes, "z") end, outside: [notes], max_file_bytes: 10)
      assert {:ok, _} = Undo.undo(ws, "ses-a", 1)
      assert File.read!(notes) == String.duplicate("e", 10)
    end

    test "backups outlive gc as long as their step is kept", %{ws: ws, notes: notes} do
      File.write!(notes, "old\n")
      step(ws, "ses-a/t1/e1", "bash sed notes", fn -> File.write!(notes, "new\n") end, outside: [notes])
      Undo.gc(ws)

      assert {:ok, _} = Undo.undo(ws, "ses-a", 1)
      assert File.read!(notes) == "old\n"
    end
  end
end
