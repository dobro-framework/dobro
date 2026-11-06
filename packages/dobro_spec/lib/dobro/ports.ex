defmodule Dobro.Ports do
  @moduledoc """
  Ports for the Dobro framework
  """

  defmodule EventHandler do
    @moduledoc """
    Port for handling domain events from one aggregate stream.
    """
    use Dobro.Spec.Port

    @callback handle(struct()) :: :ok | {:error, any()}
  end

  defmodule IntegrationEventHandler do
    @moduledoc """
    Port for handling public integration events selected by a routing-key pattern.

    `handle/1` receives the integration event map. The handler does not choose
    how that map was delivered.
    """
    use Dobro.Spec.Port

    @callback handle(map()) :: :ok | {:error, any()}
  end
end
