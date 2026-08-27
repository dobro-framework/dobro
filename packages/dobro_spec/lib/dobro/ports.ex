defmodule Dobro.Ports do
  @moduledoc """
  Ports for the Dobro framework
  """

  defmodule EventHandler do
    @moduledoc """
    Port for handling events
    """
    use Dobro.Spec.Port

    @callback handle(struct()) :: :ok | {:error, any()}
  end
end
