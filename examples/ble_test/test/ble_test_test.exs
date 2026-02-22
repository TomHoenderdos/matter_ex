defmodule BleTestTest do
  use ExUnit.Case
  doctest BleTest

  test "greets the world" do
    assert BleTest.hello() == :world
  end
end
