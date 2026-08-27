defmodule Dobro.App.Auth.TenantContextTest do
  use ExUnit.Case, async: true

  alias Dobro.App.Auth.TenantContext

  describe "partition_key/1" do
    test "nil tenant is global" do
      assert TenantContext.partition_key(nil) == "global"
    end

    test "keys by immutable tenant id" do
      tenant = TenantContext.new(id: 61, identifier: "sdadas")
      assert TenantContext.partition_key(tenant) == "id:61"
    end

    test "uses id for payload-scoped tenants without identifier" do
      tenant = TenantContext.new(id: 61)
      assert TenantContext.partition_key(tenant) == "id:61"
    end

    test "raises when id is missing" do
      assert_raise ArgumentError, ~r/requires :id/, fn ->
        TenantContext.partition_key(TenantContext.new(identifier: "whizz-funerals"))
      end
    end

    test "different tenant ids do not share a partition key" do
      assert TenantContext.partition_key(TenantContext.new(id: 60)) !=
               TenantContext.partition_key(TenantContext.new(id: 61))
    end

    test "identifier is ignored when id is present" do
      assert TenantContext.partition_key(TenantContext.new(id: 61, identifier: "a")) ==
               TenantContext.partition_key(TenantContext.new(id: 61, identifier: "b"))
    end
  end
end
