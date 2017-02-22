defmodule Farmbot.Updates.Handler do
  alias Farmbot.Auth
  alias Farmbot.BotState
  require Logger
  #TODO(connor): please  refactor this into a target specific module.

  @moduledoc """
    Bunch of stuff to do updates.
  """

  @type update_output
  :: {:update, String.t | nil}
  | {:error,  String.t | atom}
  | :no_updates

  @doc """
    Another shortcut for the shorcut
  """
  @spec check_and_download_updates(:os | :fw)
  :: :ok | {:error, atom} | :no_updates
  def check_and_download_updates(something) do
    Logger.info ">> Is checking for updates: #{inspect something}"
    case check_updates(something) do
      {:error, reason} ->
        Logger.info """
          >> encountered an error checking for updates: #{inspect reason}.
          """
      {:update, url} ->
        install_update(something, url)
      :no_updates ->
        Logger.info(">> is already on the latest operating system version.",
          channels: [:toast], type: :success)
    end
  end

  @spec install_update(:fw, String.t) :: no_return
  defp install_update(:fw, url) do
    Logger.info ">> found a firmware update!"
    File.rm("/tmp/update.hex")
    file = Downloader.run(url, "/tmp/update.hex")
    Logger.info """
      >> is installing a firmware update. I may act weird for a moment
      """,
      channels: [:toast]
    GenServer.cast(Farmbot.Serial.Handler, {:update_fw, file, self()})
    receive do
      :done ->
        Logger.info ">> is done installing a firmware update!", type: :success,
          channels: [:toast]
      {:error, reason} ->
        Logger.error """
          >> encountered an error installing firmware update!: #{inspect reason}
          """,
          channels: [:toast]
    end
  end

  @spec check_updates(any) :: no_return
  def check_updates(:fw) do
    with {:ok, token} <- Auth.get_token,
    do: check_updates(
          token.unencoded.fw_update_server,
          BotState.get_fw_version,
          ".hex")
  end

  @doc """
    Uses Github Release api to check for an update.
    If there is an update on URL, it returns the asset with the given extension
    for said update.
  """
  @spec check_updates(String.t, String.t, String.t) :: update_output
  def check_updates(url, current_version, extension) do
    resp = HTTPoison.get url, ["User-Agent": "FarmbotOLD"]
    with {:assets, new_version, assets} <- parse_resp(resp),
         true <- is_updates?(current_version, new_version),
         do: get_dl_url(assets, extension)
  end

  @spec get_dl_url([any,...] | map, String.t)
  :: {:update, String.t} | {:error, atom}
  defp get_dl_url(assets, extension)
  when is_list(assets) do
    Enum.find_value(assets, {:error, :no_assets},
      fn asset ->
        url = get_dl_url(asset)
        if String.contains?(url, extension) do
          {:update, url}
        else
          nil
        end
      end)
  end

  defp get_dl_url(asset) when is_map(asset) do
    Map.get(asset, "browser_download_url")
  end

  @doc """
    Checks if two strings are the same lol
  """
  @spec is_updates?(String.t, String.t) :: :no_updates | true
  def is_updates?(current, new) do
    if current == new do
      :no_updates
    else
      true
    end
  end
  @doc """
    Parses the httpotion response.
  """

  @spec parse_resp(HTTPoison.Response.t) :: {:assets, Strint.t, String.t}
  def parse_resp(
    {:ok, %HTTPoison.Response{
      body: body,
      status_code: 200}})
  do
    json = Poison.decode!(body)
    "v" <> new_version = Map.get(json, "tag_name")
    assets = Map.get(json, "assets")
    {:assets, new_version, assets}
  end

  # If we happen to get something weird from httpotion
  @spec parse_resp(any) :: {:error, :bad_resp}
  def parse_resp(_), do: {:error, :bad_resp}

  def do_update_check do
    Logger.info ">> is checking for updates."

    # check configuration.
    case BotState.get_config(:os_auto_update) do
      true -> Farmbot.System.Updates.check_and_download_updates()
      _ -> Logger.warn ">> won't check for operating system updates."
    end

    case BotState.get_config(:fw_auto_update) do
      true -> check_and_download_updates(:fw)
      _ -> Logger.warn ">> won't check for firmware updates."
    end
  end
end
