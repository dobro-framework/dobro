defmodule Dobro.Integration.PatternTest do
  use ExUnit.Case, async: true

  alias Dobro.Integration.Pattern

  test "star matches one segment and hash matches the rest" do
    assert Pattern.match?(
             "my_bc.*",
             "my_bc.people_involved_name_updated"
           )

    assert Pattern.match?(
             "my_bc.case_status_transitioned",
             "my_bc.case_status_transitioned"
           )

    refute Pattern.match?(
             "my_bc.case_status_transitioned",
             "my_bc.people_involved_name_updated"
           )

    assert Pattern.match?(
             "my_bc.#",
             "my_bc.case_status_transitioned"
           )
  end

  test "a bare hash is rejected" do
    assert {:error, :bare_hash} = Pattern.compile("#")
    refute Pattern.match?("#", "my_bc.case_status_transitioned")
  end

  test "an exact key matches only itself" do
    key = "my_bc.people_involved_name_updated"
    assert Pattern.match?(key, key)
    refute Pattern.match?(key, "my_bc.people_involved_comments_updated")
  end

  test "covering is the exact key plus the patterns that match it" do
    key = "my_bc.case_created"
    patterns = Pattern.covering(key)

    assert key in patterns
    assert "my_bc.#" in patterns
    assert "my_bc.*" in patterns
    refute "people.#" in patterns
    refute "#" in patterns
    assert Enum.all?(patterns, &Pattern.match?(&1, key))
  end

  test "routing_key joins topic and snake_case event name" do
    assert Pattern.routing_key("my_bc", "case_status_transitioned") ==
             "my_bc.case_status_transitioned"
  end
end
