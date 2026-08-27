defmodule Dobro.Config do
  @moduledoc """
  Cross-package configuration for Dobro libraries.

  Configure in your host application:

      config :dobro_spec,
        otp_app: :my_app,
        adapter_registry: MyApp.AdapterRegistry

      config :dobro_ecto,
        repo: MyApp.Repo,
        tenant_resolver: MyApp.TenantResolver

      config :dobro_runtime,
        pubsub: MyApp.PubSub,
        outbox_relay: [enabled: false, batch_size: 100, poll_interval_ms: 1_000]

      config :dobro_cqrs,
        execution_strategy: :actor_when_identified,
        persistence_strategy: :stateful,
        event_delivery_strategy: :pubsub

  When `dobro_runtime` is not used, omit the runtime config.
  `dobro_cqrs` defaults to synchronous execution and write-only persistence.
  """

  @doc "OTP application used for port adapter overrides via `Application.get_env/2`."
  @spec otp_app() :: atom()
  def otp_app do
    Application.get_env(:dobro_spec, :otp_app, :dobro_spec)
  end

  @doc "Root adapter registry module."
  @spec adapter_registry!() :: module()
  def adapter_registry! do
    Application.fetch_env!(:dobro_spec, :adapter_registry)
  end

  @doc "Ecto repo module for read/write operations."
  @spec repo!() :: module()
  def repo! do
    Application.fetch_env!(:dobro_ecto, :repo)
  end

  @doc "Phoenix PubSub server for domain event delivery."
  @spec pubsub!() :: module()
  def pubsub! do
    Application.fetch_env!(:dobro_runtime, :pubsub)
  end

  @doc "Optional tenant resolver for schema-prefix multi-tenancy."
  @spec tenant_resolver() :: module() | nil
  def tenant_resolver do
    Application.get_env(:dobro_ecto, :tenant_resolver)
  end
end
