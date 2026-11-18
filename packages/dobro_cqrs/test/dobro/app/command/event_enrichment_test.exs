defmodule Dobro.App.Command.EventEnrichmentTest do
  use ExUnit.Case, async: true

  alias Dobro.App.Auth.TenantContext
  alias Dobro.App.Command.EventEnrichment
  alias Dobro.Domain.Messages.MessageIdentity
  alias Dobro.Infra.Data.WriteRepo.UnitOfWork

  defmodule Aggregate do
    defstruct [:id, :name]
  end

  defmodule Created do
    defstruct [:payload, :message_identity]
  end

  defmodule CreatedPayload do
    defstruct [:id, :name, :tenant_id]
  end

  defmodule AuthoredPayload do
    defstruct [:id, :author_user_id, :author_name, :occurred_at]
  end

  defmodule NoTenantPayload do
    defstruct [:id, :name]
  end

  defp message_identity, do: MessageIdentity.new!(%{id: "command-id"})
  defp event_identity, do: MessageIdentity.new!(%{id: "event-id"})

  defp unit_of_work do
    UnitOfWork.new(%{aggregate: %Aggregate{id: 42, name: "Acme"}, schema: nil})
  end

  test "fills nil payload ids from the persisted aggregate" do
    event = %Created{
      payload: %{id: nil, name: "Acme"},
      message_identity: event_identity()
    }

    assert [%Created{payload: %{id: 42}}] =
             EventEnrichment.enrich([event], message_identity(), unit_of_work())
  end

  test "leaves payload ids that are already set" do
    event = %Created{
      payload: %{id: 7, name: "Acme"},
      message_identity: event_identity()
    }

    assert [%Created{payload: %{id: 7}}] =
             EventEnrichment.enrich([event], message_identity(), unit_of_work())
  end

  test "stamps tenant_id from tenant context onto map payloads" do
    event = %Created{
      payload: %{id: nil, name: "Acme"},
      message_identity: event_identity()
    }

    tenant = TenantContext.new(%{id: 9, identifier: "acme"})

    assert [%Created{payload: %{id: 42, tenant_id: 9}}] =
             EventEnrichment.enrich([event], message_identity(), unit_of_work(), tenant)
  end

  test "stamps tenant_id onto struct payloads that declare the field" do
    event = %Created{
      payload: %CreatedPayload{id: nil, name: "Acme", tenant_id: nil},
      message_identity: event_identity()
    }

    tenant = TenantContext.new(%{id: 9, identifier: "acme"})

    assert [%Created{payload: %CreatedPayload{id: 42, tenant_id: 9}}] =
             EventEnrichment.enrich([event], message_identity(), unit_of_work(), tenant)
  end

  test "does not add tenant_id to struct payloads without the field" do
    event = %Created{
      payload: %NoTenantPayload{id: nil, name: "Acme"},
      message_identity: event_identity()
    }

    tenant = TenantContext.new(%{id: 9, identifier: "acme"})

    assert [%Created{payload: %NoTenantPayload{id: 42} = payload}] =
             EventEnrichment.enrich([event], message_identity(), unit_of_work(), tenant)

    refute Map.has_key?(payload, :tenant_id)
  end

  test "leaves an already-set tenant_id alone" do
    event = %Created{
      payload: %CreatedPayload{id: 7, name: "Acme", tenant_id: 3},
      message_identity: event_identity()
    }

    tenant = TenantContext.new(%{id: 9, identifier: "acme"})

    assert [%Created{payload: %CreatedPayload{tenant_id: 3}}] =
             EventEnrichment.enrich([event], message_identity(), unit_of_work(), tenant)
  end

  describe "stamp_actor/2" do
    @at ~U[2026-01-02 03:04:05Z]

    test "stamps the user author and time onto declared blank fields" do
      event = %Created{payload: %AuthoredPayload{id: 1}, message_identity: event_identity()}
      actor = %{type: "user", id: 5, first_name: "Ada", last_name: "Lovelace"}

      assert [
               %Created{
                 payload: %AuthoredPayload{
                   author_user_id: 5,
                   author_name: "Ada Lovelace",
                   occurred_at: @at
                 }
               }
             ] = EventEnrichment.stamp_actor([event], actor: actor, occurred_at: @at)
    end

    test "keeps values the aggregate already set" do
      earlier = ~U[2020-01-01 00:00:00Z]

      event = %Created{
        payload: %AuthoredPayload{author_user_id: 1, author_name: "Grace", occurred_at: earlier},
        message_identity: event_identity()
      }

      assert [
               %Created{
                 payload: %{author_user_id: 1, author_name: "Grace", occurred_at: ^earlier}
               }
             ] =
               EventEnrichment.stamp_actor([event],
                 actor: %{type: "user", id: 5, first_name: "Ada"},
                 occurred_at: @at
               )
    end

    test "prefers first and last name over the username" do
      actor = %{type: "user", id: 5, first_name: "Ada", last_name: "Lovelace", username: "ada"}
      assert {5, "Ada Lovelace"} = EventEnrichment.author(actor)
      assert {5, "Ada"} = EventEnrichment.author(%{actor | last_name: nil})
    end

    test "falls back to the username when the names are blank" do
      actor = %{type: "user", id: 5, first_name: nil, last_name: " ", username: "ada"}
      assert {5, "ada"} = EventEnrichment.author(actor)
    end

    test "names non-user actors without a user id" do
      event = %Created{payload: %AuthoredPayload{}, message_identity: event_identity()}

      assert [%Created{payload: %{author_user_id: nil, author_name: "admin@example.com"}}] =
               EventEnrichment.stamp_actor([event],
                 actor: %{type: "admin", id: 3, email: "admin@example.com"}
               )
    end

    test "does not add fields to payloads that do not declare them" do
      event = %Created{payload: %NoTenantPayload{id: 1}, message_identity: event_identity()}

      assert [%Created{payload: %NoTenantPayload{} = payload}] =
               EventEnrichment.stamp_actor([event], actor: %{type: "user", id: 5})

      refute Map.has_key?(payload, :author_user_id)
    end

    test "stamps the time even without an actor" do
      event = %Created{payload: %AuthoredPayload{}, message_identity: event_identity()}

      assert [%Created{payload: %{author_user_id: nil, occurred_at: %DateTime{}}}] =
               EventEnrichment.stamp_actor([event])
    end
  end
end
