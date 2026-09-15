defmodule Dobro.Runtime.AggregateActorTest do
  use ExUnit.Case, async: true

  alias Dobro.App.Auth.TenantContext
  alias Dobro.Runtime.AggregateActor

  defmodule SampleAggregate do
  end

  describe "actor_key/3" do
    test "global scope uses a global tenant partition" do
      assert AggregateActor.actor_key(SampleAggregate, nil, %{id: 1}) ==
               {:aggregate_actor, SampleAggregate, "global", "id:1"}
    end

    test "keys by tenant id so different tenants get distinct actors" do
      name_60 =
        AggregateActor.actor_key(
          SampleAggregate,
          TenantContext.new(id: 60, identifier: "whizz-funerals"),
          %{id: 2}
        )

      name_61 =
        AggregateActor.actor_key(
          SampleAggregate,
          TenantContext.new(id: 61, identifier: "sdadas"),
          %{id: 2}
        )

      assert name_60 != name_61
    end

    test "identifier renames do not change the actor key" do
      identity = %{id: 2}

      assert AggregateActor.actor_key(
               SampleAggregate,
               TenantContext.new(id: 61, identifier: "old"),
               identity
             ) ==
               AggregateActor.actor_key(
                 SampleAggregate,
                 TenantContext.new(id: 61, identifier: "new"),
                 identity
               )
    end

    test "identity map key order does not affect the actor key" do
      tenant = TenantContext.new(id: 1, identifier: "acme")

      assert AggregateActor.actor_key(SampleAggregate, tenant, %{id: 2, office_id: 9}) ==
               AggregateActor.actor_key(SampleAggregate, tenant, %{office_id: 9, id: 2})
    end

    test "raises when tenant id is missing" do
      assert_raise ArgumentError, ~r/requires :id/, fn ->
        AggregateActor.actor_key(
          SampleAggregate,
          TenantContext.new(identifier: "sdadas"),
          %{id: 2}
        )
      end
    end
  end
end
