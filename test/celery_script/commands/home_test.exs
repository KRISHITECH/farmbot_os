defmodule Farmbot.CeleryScript.Command.HomeTest do
  use ExUnit.Case, async: false

  # alias Farmbot.CeleryScript.Ast
  alias Farmbot.CeleryScript.Command

  setup_all do
    Farmbot.Serial.HandlerTest.wait_for_serial_available()
    :ok
  end

  setup do
    Process.sleep(100)
    :ok
  end

  test "makes sure we have serial" do
    assert Farmbot.Serial.Handler.available?() == true
  end

  test "homes all axises" do
    Command.home(%{axis: "all"}, [])
    Process.sleep(500)
    [x, y, z] = Farmbot.BotState.get_current_pos
    assert x == 0
    assert y == 0
    assert z == 0
  end

  test "homes x" do
    [_x, y, z] = Farmbot.BotState.get_current_pos
    Command.home(%{axis: "x"}, [])
    Process.sleep(500)
    [new_x, new_y, new_z] = Farmbot.BotState.get_current_pos
    assert new_x == 0
    assert y == new_y
    assert z == new_z
  end

  test "homes y" do
    [x, _y, z] = Farmbot.BotState.get_current_pos
    Command.home(%{axis: "y"}, [])
    Process.sleep(500)
    [new_x, new_y, new_z] = Farmbot.BotState.get_current_pos
    assert x == new_x
    assert new_y == 0
    assert z == new_z
  end

  test "homes z" do
    [x, y, _z] = Farmbot.BotState.get_current_pos
    Command.home(%{axis: "z"}, [])
    Process.sleep(500)
    [new_x, new_y, new_z] = Farmbot.BotState.get_current_pos
    assert x == new_x
    assert y == new_y
    assert new_z == 0
  end
end
