defmodule NetTestTest do
  use ExUnit.Case
  doctest NetTest

  test "greets the world" do
    assert NetTest.hello() == :world
  end
end
