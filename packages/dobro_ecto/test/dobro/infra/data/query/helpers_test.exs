defmodule Dobro.Infra.Data.Query.HelpersTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  alias Dobro.App.Selection
  alias Dobro.Ecto.Test.Schemas.CategorySchema
  alias Dobro.Infra.Data.Query.{Helpers, Spec}
  alias Dobro.Infra.Data.ReadRepo.Context

  test "selection/1 reads from read repo context" do
    selection = %Selection{fields: MapSet.new([:id])}
    context = %Context{selection: selection}

    assert Helpers.selection(context) == selection
  end

  test "apply_preloads/3 skips association when not selected" do
    preloads = [
      %{name: :tenant, schema: Dobro.Ecto.Test.Schemas.TenantSchema, fields: [:id, :name]}
    ]

    query = from(c in CategorySchema)
    selection = %Selection{fields: MapSet.new([:id]), associations: %{}}

    result = Helpers.apply_preloads(query, preloads, selection)

    refute inspect(result) =~ "tenant"
  end

  test "needed_fields/3 includes embedded contract fields selected as associations" do
    spec = %Spec{
      module: __MODULE__,
      type: :one,
      schema: CategorySchema,
      fields: %{
        id: {:column, :office, :id},
        name: {:column, :office, :name},
        address: {:expr, dynamic(true)}
      }
    }

    selection = %Selection{
      fields: MapSet.new([:id, :name]),
      associations: %{address: %Selection{fields: MapSet.new([:address_line1, :town])}}
    }

    assert :address in Helpers.needed_fields(spec, selection, nil)
  end

  test "needed_fields/3 loads all declared fields when selection includes computed fields" do
    spec = %Spec{
      module: __MODULE__,
      type: :list,
      schema: CategorySchema,
      fields: %{
        id: {:column, :user, :id},
        email: {:column, :user, :email},
        invitation_created_at: {:column, :user, :invitation_created_at},
        password_changed_at: {:column, :user, :password_changed_at}
      }
    }

    selection = %Selection{
      fields: MapSet.new([:id, :email, :status])
    }

    needed = Helpers.needed_fields(spec, selection, nil)

    assert :invitation_created_at in needed
    assert :password_changed_at in needed
    refute :status in needed
  end

  test "needed_fields/3 projects only selected fields when selection is covered by spec" do
    spec = %Spec{
      module: __MODULE__,
      type: :list,
      schema: CategorySchema,
      fields: %{
        id: {:column, :user, :id},
        email: {:column, :user, :email},
        invitation_created_at: {:column, :user, :invitation_created_at}
      }
    }

    selection = %Selection{fields: MapSet.new([:id, :email])}

    assert MapSet.new(Helpers.needed_fields(spec, selection, nil)) ==
             MapSet.new([:id, :email])
  end
end
