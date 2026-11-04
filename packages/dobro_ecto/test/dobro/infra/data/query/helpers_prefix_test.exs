defmodule Dobro.Infra.Data.Query.HelpersPrefixTest do
  use ExUnit.Case, async: true

  alias Dobro.App.Auth.TenantContext
  alias Dobro.Infra.Data.Query.Helpers
  alias Dobro.Infra.Data.ReadRepo.Context

  test "resolve_prefix/2 returns nil for nil" do
    assert Helpers.resolve_prefix(nil, nil) == nil
  end

  test "resolve_prefix/2 returns binary prefixes as-is" do
    assert Helpers.resolve_prefix("shared", nil) == "shared"
  end

  test "resolve_prefix/2 :tenant raises without tenant context" do
    assert_raise ArgumentError, ~r/requires a tenant/, fn ->
      Helpers.resolve_prefix(:tenant, nil)
    end
  end

  test "prefix_repo_opts/1" do
    assert Helpers.prefix_repo_opts(nil) == []
    assert Helpers.prefix_repo_opts("acme") == [prefix: "acme"]
  end

  # Only exercise :tenant resolution when a resolver is configured in this package's tests.
  @tag :skip
  test "resolve_prefix/2 :tenant uses SchemaPrefix when configured" do
    context = Context.new(tenant: %TenantContext{id: 1, identifier: "acme"})
    assert is_binary(Helpers.resolve_prefix(:tenant, context))
  end
end
