defmodule MatterExample.Device do
  use MatterEx.Device,
    vendor: :test,
    product: :matter_example

  endpoint(:light, :dimmable_light)
  endpoint(:temperature, :temperature_sensor)
  endpoint(:humidity, :humidity_sensor)
  endpoint(:illuminance, :light_sensor)
  endpoint(:occupancy, :occupancy_sensor)
  endpoint(:contact, :contact_sensor)
  endpoint(:air_quality, :air_quality_sensor)
end
