defmodule Jido.Workspace.SchemasTest do
  use ExUnit.Case, async: true

  alias Jido.Workspace.Schemas

  describe "validate_path/1" do
    test "accepts absolute paths" do
      assert {:ok, "/foo/bar"} = Schemas.validate_path("/foo/bar")
    end

    test "rejects relative paths" do
      assert {:error, {:invalid_path, message}} = Schemas.validate_path("foo/bar")
      assert message =~ "absolute"
    end

    test "rejects traversal paths" do
      assert {:error, {:invalid_path, message}} = Schemas.validate_path("/foo/../bar")
      assert message =~ "traversal"
    end
  end

  describe "validate_workspace_id/1" do
    test "accepts non-empty workspace ids" do
      assert {:ok, "my-workspace"} = Schemas.validate_workspace_id("my-workspace")
    end

    test "rejects blank workspace ids" do
      assert {:error, {:invalid_workspace_id, _}} = Schemas.validate_workspace_id("   ")
    end
  end

  describe "validate_command/1" do
    test "accepts non-empty commands" do
      assert {:ok, "pwd"} = Schemas.validate_command("pwd")
    end

    test "rejects blank commands" do
      assert {:error, {:invalid_command, _}} = Schemas.validate_command("   ")
    end
  end
end
