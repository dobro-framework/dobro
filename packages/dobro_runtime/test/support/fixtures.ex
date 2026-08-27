defmodule Dobro.Runtime.TestFixtures do
  @moduledoc false

  defmodule Record do
    @moduledoc false
    defstruct [:id, :version]
  end

  defmodule RecordDeleted do
    @moduledoc false
    defstruct [:payload]
  end
end
