defmodule Dobro.AI.ToolContractTest do
  use ExUnit.Case, async: true

  alias Dobro.AI.ToolContract

  defmodule ListImportsQuery do
    use Dobro.App.Query
    use Dobro.App.Definition

    schema do
      field :tenant_id, :id
    end
  end

  defmodule GetEntryQuery do
    use Dobro.App.Query
    use Dobro.App.Definition

    schema do
      field :id, :id, required: true
    end
  end

  defmodule ArchiveApi do
    def __queries__(:list_imports), do: {ListImportsQuery, []}
    def __queries__(:get_entry), do: {GetEntryQuery, []}
  end

  test "required_fields reads schema metadata" do
    refute "tenant_id" in ToolContract.required_fields({ArchiveApi, :list_imports})
    assert "id" in ToolContract.required_fields({ArchiveApi, :get_entry})
  end

  test "validate_required rejects missing fields" do
    assert :ok = ToolContract.validate_required(%{}, {ArchiveApi, :list_imports})

    assert :ok =
             ToolContract.validate_required(%{tenant_id: 2}, {ArchiveApi, :list_imports})
  end

  test "classify_success detects empty list results" do
    assert :not_found = ToolContract.classify_success(%{items: []}, "demo_list")
    assert :ok = ToolContract.classify_success(%{items: [%{id: 1}]}, "demo_list")
  end

  test "halt_result? recognizes contract halt payloads" do
    assert ToolContract.halt_result?(%{
             "ok" => false,
             "reason" => "missing_required",
             "fields" => ["tenant_id"]
           })

    assert ToolContract.halt_result?(%{
             "ok" => false,
             "reason" => "not_found"
           })

    assert ToolContract.halt_result?(%{
             "ok" => false,
             "error" => %{"reason" => "scope_error", "message" => "Tenant required"}
           })

    refute ToolContract.halt_result?(%{"ok" => true, "items" => []})
  end
end
