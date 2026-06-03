defmodule MatterExample.FakeSensor do
  @moduledoc """
  Periodically updates the fake temperature sensor endpoint.
  """

  use GenServer
  require Logger

  @interval_ms 5_000
  @temperature_endpoint :temperature
  @humidity_endpoint :humidity
  @illuminance_endpoint :illuminance
  @occupancy_endpoint :occupancy
  @contact_endpoint :contact
  @air_quality_endpoint :air_quality
  @attribute :measured_value

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, @interval_ms)
    base = Keyword.get(opts, :base_centidegrees, 2_100)
    Process.send_after(self(), :tick, 500)
    {:ok, %{interval_ms: interval_ms, base: base, step: 0}}
  end

  @impl true
  def handle_info(:tick, state) do
    temperature = fake_temperature(state.base, state.step)
    humidity = fake_humidity(4_500, state.step)
    illuminance = fake_illuminance(100, state.step)
    occupied = fake_occupancy(state.step)
    contact_open = fake_contact_open(state.step)
    air_quality = fake_air_quality(state.step)

    update(@temperature_endpoint, @attribute, temperature)
    update(@humidity_endpoint, @attribute, humidity)
    update(@illuminance_endpoint, @attribute, illuminance)
    update(@occupancy_endpoint, :occupancy, occupied)
    update(@contact_endpoint, :state_value, contact_open)
    update(@air_quality_endpoint, :air_quality, air_quality)

    Logger.info(
      "fake sensors updated: temp=#{format_temperature(temperature)} humidity=#{format_humidity(humidity)} illuminance=#{format_illuminance(illuminance)} occupancy=#{occupied} contact_open=#{contact_open} air_quality=#{air_quality}"
    )

    Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, %{state | step: state.step + 1}}
  end

  def fake_temperature(base, step) do
    offset = rem(step, 12) * 25
    direction = if rem(div(step, 12), 2) == 0, do: 1, else: -1
    base + direction * offset
  end

  def fake_humidity(base, step) do
    offset = rem(step, 10) * 150
    direction = if rem(div(step, 10), 2) == 0, do: 1, else: -1
    base + direction * offset
  end

  def fake_illuminance(base_lux, step) do
    lux = base_lux + rem(step, 8) * 50
    round(10_000 * :math.log10(lux) + 1)
  end

  def fake_occupancy(step), do: if(rem(step, 4) in [0, 1], do: 1, else: 0)

  def fake_contact_open(step), do: rem(step, 6) >= 3

  def fake_air_quality(step), do: rem(step, 5) + 1

  defp update(endpoint, attribute, value) do
    case MatterExample.Device.update_attribute(endpoint, attribute, value) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "fake sensor update failed for #{endpoint}.#{attribute}: #{inspect(reason)}"
        )
    end
  end

  defp format_temperature(value) do
    "#{Float.round(value / 100, 2)} C"
  end

  defp format_humidity(value) do
    "#{Float.round(value / 100, 2)}% RH"
  end

  defp format_illuminance(value) do
    lux = :math.pow(10, (value - 1) / 10_000)
    "#{Float.round(lux, 1)} lux"
  end
end
