defmodule Dobro.AI.JsonSchemaTest do
  use ExUnit.Case, async: true

  defmodule SampleQuery do
    use Dobro.App.Query
    use Dobro.App.Definition

    schema do
      field :identifier, :string, required: true, description: "Template identifier."
      field :tenant_id, :id
    end
  end

  test "builds object schema from query payload" do
    schema = Dobro.AI.JsonSchema.from_schema(SampleQuery.__schema__())

    assert schema["type"] == "object"
    assert schema["required"] == ["identifier"]
    assert schema["properties"]["identifier"]["type"] == "string"
    assert schema["properties"]["identifier"]["description"] == "Template identifier."
    assert schema["properties"]["tenant_id"]["type"] == "integer"
  end
end
