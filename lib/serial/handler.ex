defmodule Farmbot.Serial.Handler do
  @moduledoc """
    Handles serial messages and keeping ports alive.
  """

  alias Nerves.UART
  alias Farmbot.Serial.Gcode.Handler, as: GcodeHandler
  alias Farmbot.Serial.Gcode.Parser, as: GcodeParser

  require Logger
  use GenServer
  @spec handle_call(any, any, any) :: {:reply, any, any}
  @spec handle_cast(any, any) :: {:noreply, any}
  @spec handle_info(any, any) :: {:noreply, any}
  @baud 115_200

  @spec init([]) :: {:ok, {pid, binary, pid}} | {:ok, nil}
  def init([]) do
    Process.flag(:trap_exit, true)
    {:ok, nerves} = UART.start_link
    {:ok, handler} = GcodeHandler.start_link(nerves)
    tty = open_serial(nerves)
    if tty do
      {:ok, {nerves, tty, handler}}
    else
      {:ok, nil}
    end
  end

  @doc """
    Start the Serial Handler
  """
  @spec start_link :: {:ok, pid}
  def start_link, do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
    Writes to a nerves uart tty. This only exists because
    I wanted to print what is being written
  """
  @lint false # something weird with `when`
  @spec write(binary, pid) :: no_return
  def write(str, caller) when is_bitstring(str),
    do: GenServer.cast(__MODULE__, {:write, str <> " Q0", caller})
  _ = @lint # HACK(Connor) fix credo compiler warning

  @doc """
    Estop the arduino. This is super hacky.
  """
  @spec e_stop :: no_return
  def e_stop, do: GenServer.call(__MODULE__, :e_stop)

  @doc """
    Checks if we have a serial connection
  """
  @spec available? :: boolean
  def available?, do: GenServer.call(__MODULE__, :available?)

  def handle_call(:available?, _, nil), do: {:reply, false, nil}
  def handle_call(:available?, _, {nerves, tty, handler}),
    do: {:reply, true, {nerves, tty, handler}}

  def handle_call(:e_stop, _from, {nerves, tty, _handler}) do
    UART.write(nerves, "E")
    UART.close(nerves)
    # Temp hack to try to stop a running command.
    UART.open(nerves, tty, speed: @baud, active: false)
    UART.close(nerves)
    {:reply, :ok, :crash}
  end

  def handle_call(:resume, _from, {nerves, :e_stop, handler}) do
    tty = open_serial(nerves)
    {:reply, :ok, {nerves, tty, handler}}
  end

  def handle_call(_, _from, nil), do: {:reply, :ok, nil}

  def handle_cast({:write, _str, caller}, {nerves, :e_stop, handler}) do
    send(caller, :e_stop)
    {:noreply, {nerves, :e_stop, handler}}
  end

  def handle_cast({:write, str, _caller}, {nerves, tty, handler}) do
    UART.write(nerves, str)
    {:noreply, {nerves, tty, handler}}
  end

  def handle_cast({:update_fw, hex_file, pid}, {nerves, tty, handler}) do
    # TODO Rewrite this with an Erlang Port
    UART.close(nerves)
    params =
      ["-v",
       "-patmega2560",
       "-cwiring",
       "-P/dev/#{tty}",
       "-b115200",
       "-D",
       "-Uflash:w:#{hex_file}:i"]

    "avrdude" |> System.cmd(params) |> parse_cmd(pid)
    new_tty = open_serial(nerves)
    {:noreply, {nerves, new_tty, handler}}
  end

  def handle_cast({:write, _str, caller}, nil) do
    send(caller, :done)
    {:noreply, nil}
  end

  def handle_cast(_, nil), do: {:noreply, nil}

  # WHEN A FULL SERIAL MESSAGE COMES IN.
  @lint false # i dont know why i have to do this?
  def handle_info({:nerves_uart, nerves_tty, message}, {pid, tty, handler})
  when is_binary(message) and nerves_tty == tty do
    gcode = GcodeParser.parse_code(String.strip(message))
    GenServer.cast(handler, gcode)
    {:noreply, {pid, tty, handler}}
  end

  def handle_info({:nerves_uart, _tty, {:partial, partial}}, state) do
    Logger.warn ">> got a partial gcode: #{partial}"
    {:noreply, state}
  end

  def handle_info({:nerves_uart, _tty, {:error, :eio}}, state) do
    Logger.error ">> Arduino disconnected! Please put it back.."
    {:noreply, state}
  end

  def handle_info({:nerves_uart, _tty, _event}, {nerves, :e_stop, handler}) do
    {:noreply, {nerves, :e_stop, handler}}
  end

  def handle_info({:nerves_uart, _tty, _event}, state) do
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, :normal}, state) do
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, _reason}, {nerves, tty, handler})
  when pid == handler do
      {:ok, restarted} = GcodeHandler.start_link(nerves)
      {:noreply,  {nerves, tty, restarted}}
  end

  def handle_info({:EXIT, pid, _}, {nerves, tty, handler})
  when pid == nerves do {:crashme,  {nerves, tty, handler}} end

  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}

  def handle_info(_event, state) do
    {:noreply, state}
  end

  # The output of a system cmd. #TODO turn this into an erlang port
  # For more better error handling
  @spec parse_cmd({String.t, integer}, pid) :: :ok
  defp parse_cmd({_, 0}, pid), do: send(pid, :done)
  defp parse_cmd({output, _}, pid), do: send(pid, {:error, output})

  @spec open_serial(pid, [], [binary, ...]) :: {:ok, binary}
  defp open_serial(_pid, [], tries) do
    Logger.error ">> could not auto detect serial port. " <>
    "i tried: #{inspect tries}"
    {:ok, nil}
  end

  @spec open_serial(pid, [binary,...], [binary,...]) :: {:ok, binary}
  defp open_serial(pid, ports, tries) do
    [{tty,_} | rest] = ports
    case UART.open(pid, tty, speed: @baud, active: true) do
      :ok -> {:ok, tty}
      _ -> open_serial(pid, rest, tries ++ [tty])
    end
  end

  @spec open_serial(pid) :: {:ok, binary}
  defp open_serial(pid) do
    {:ok, tty} = open_serial(pid, list_ttys(), []) # List of available ports
    UART.configure(pid, framing: {UART.Framing.Line,
                        separator: "\r\n"},
                        rx_framing_timeout: 500)
    tty
  end

  @spec list_ttys :: [String.t,...]
  defp list_ttys do
    UART.enumerate
    |> Map.drop(["ttyS0","ttyAMA0"])
    |> Map.to_list
  end

  @spec terminate(any, any) :: no_return
  def terminate(:restart, {nerves, _tty, handler}) do
    GenServer.stop(nerves, :normal)
    GenServer.stop(handler, :normal)
  end

  def terminate(_reason, _state), do: nil
end
