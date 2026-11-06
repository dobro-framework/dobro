defmodule Dobro.Integration.PatternTest do
  use ExUnit.Case, async: true

  alias Dobro.Integration.Pattern

  test "star matches one segment and hash matches the rest" do
    assert Pattern.match?(
             "funeral_planning.*",
             "funeral_planning.people_involved_next_of_kin_updated"
           )

    assert Pattern.match?(
             "funeral_planning.case_status_transitioned",
             "funeral_planning.case_status_transitioned"
           )

    refute Pattern.match?(
             "funeral_planning.case_status_transitioned",
             "funeral_planning.people_involved_next_of_kin_updated"
           )

    assert Pattern.match?(
             "funeral_planning.#",
             "funeral_planning.case_status_transitioned"
           )
  end

  test "a bare hash is rejected" do
    assert {:error, :bare_hash} = Pattern.compile("#")
    refute Pattern.match?("#", "funeral_planning.case_status_transitioned")
  end

  test "an exact key matches only itself" do
    key = "funeral_planning.people_involved_next_of_kin_updated"
    assert Pattern.match?(key, key)
    refute Pattern.match?(key, "funeral_planning.people_involved_comments_updated")
  end

  test "routing_key joins topic and snake_case event name" do
    assert Pattern.routing_key("funeral_planning", "case_status_transitioned") ==
             "funeral_planning.case_status_transitioned"
  end
end
