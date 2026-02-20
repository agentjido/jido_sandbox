defmodule Jido.WorkspaceTest do
  use ExUnit.Case, async: false

  alias Jido.Workspace

  @moduletag :contract

  setup do
    workspace = Workspace.new()
    Process.put(:workspace_under_test, workspace)

    on_exit(fn ->
      case Process.get(:workspace_under_test) do
        %Jido.Workspace.Workspace{} = current ->
          _ = Workspace.close(current)
          :ok

        _ ->
          :ok
      end
    end)

    {:ok, workspace: workspace}
  end

  describe "artifact operations" do
    test "writes, reads, lists, and deletes files", %{workspace: workspace} do
      {:ok, workspace} = Workspace.write(workspace, "/hello.txt", "Hello, World!")
      Process.put(:workspace_under_test, workspace)

      assert {:ok, "Hello, World!"} = Workspace.read(workspace, "/hello.txt")

      assert {:ok, ["hello.txt"]} = Workspace.list(workspace, "/")

      {:ok, workspace} = Workspace.delete(workspace, "/hello.txt")
      Process.put(:workspace_under_test, workspace)

      assert {:error, :file_not_found} = Workspace.read(workspace, "/hello.txt")
    end

    test "creates and uses directories", %{workspace: workspace} do
      {:ok, workspace} = Workspace.mkdir(workspace, "/artifacts")
      {:ok, workspace} = Workspace.write(workspace, "/artifacts/note.md", "# Note")
      Process.put(:workspace_under_test, workspace)

      assert {:ok, ["note.md"]} = Workspace.list(workspace, "/artifacts")
      assert {:ok, "# Note"} = Workspace.read(workspace, "/artifacts/note.md")
    end
  end

  describe "snapshot and restore" do
    test "restores workspace tree to prior state", %{workspace: workspace} do
      {:ok, workspace} = Workspace.write(workspace, "/original.txt", "original")
      {:ok, workspace} = Workspace.mkdir(workspace, "/nested")
      {:ok, workspace} = Workspace.write(workspace, "/nested/a.txt", "a")

      {:ok, snapshot_id, workspace} = Workspace.snapshot(workspace)

      {:ok, workspace} = Workspace.delete(workspace, "/original.txt")
      {:ok, workspace} = Workspace.write(workspace, "/nested/new.txt", "new")
      Process.put(:workspace_under_test, workspace)

      assert {:error, :file_not_found} = Workspace.read(workspace, "/original.txt")
      assert {:ok, "new"} = Workspace.read(workspace, "/nested/new.txt")

      {:ok, workspace} = Workspace.restore(workspace, snapshot_id)
      Process.put(:workspace_under_test, workspace)

      assert {:ok, "original"} = Workspace.read(workspace, "/original.txt")
      assert {:ok, "a"} = Workspace.read(workspace, "/nested/a.txt")
      assert {:error, :file_not_found} = Workspace.read(workspace, "/nested/new.txt")
    end

    test "returns unknown snapshot for missing id", %{workspace: workspace} do
      assert {:error, :unknown_snapshot} = Workspace.restore(workspace, "snap-404")
    end
  end

  describe "shell session integration" do
    test "runs commands in workspace session", %{workspace: workspace} do
      assert {:ok, "/\n", workspace} = Workspace.run(workspace, "pwd")
      Process.put(:workspace_under_test, workspace)

      assert is_binary(Workspace.session_id(workspace))

      assert {:ok, output, workspace} = Workspace.run(workspace, "write /from_shell.txt hi")
      assert output =~ "wrote"
      Process.put(:workspace_under_test, workspace)

      assert {:ok, "hi"} = Workspace.read(workspace, "/from_shell.txt")
    end
  end
end
