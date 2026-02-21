defmodule Matterlix.Cluster.ConcentrationMeasurement do
  @moduledoc """
  Matter Concentration Measurement base module.

  Provides factory functions for PM2.5 (0x042A), PM10 (0x042D),
  CO2 (0x040D), TVOC (0x042E), and other concentration sensors.
  MeasuredValue is in µg/m³ or ppm depending on the specific cluster.
  """

  defmacro __using__(opts) do
    cluster_id = Keyword.fetch!(opts, :cluster_id)
    cluster_name = Keyword.fetch!(opts, :cluster_name)

    quote do
      use Matterlix.Cluster, id: unquote(cluster_id), name: unquote(cluster_name)

      # MeasuredValue: concentration in cluster-specific units
      attribute 0x0000, :measured_value, :float, default: 0.0
      # MinMeasuredValue
      attribute 0x0001, :min_measured_value, :float, default: 0.0
      # MaxMeasuredValue
      attribute 0x0002, :max_measured_value, :float, default: 1000.0
      # MeasurementUnit: 0=PPM, 1=PPB, 2=PPT, 3=mg/m³, 4=µg/m³
      attribute 0x0008, :measurement_unit, :enum8, default: 0
      # MeasurementMedium: 0=Air, 1=Water, 2=Soil
      attribute 0x0009, :measurement_medium, :enum8, default: 0
      # LevelIndication: 0=Unknown, 1=Low, 2=Medium, 3=High, 4=Critical
      attribute 0x000A, :level_indication, :enum8, default: 0
      attribute 0xFFFC, :feature_map, :uint32, default: 0x01
      attribute 0xFFFD, :cluster_revision, :uint16, default: 3
    end
  end
end

defmodule Matterlix.Cluster.PM25ConcentrationMeasurement do
  @moduledoc "PM2.5 Concentration Measurement cluster (0x042A)."
  use Matterlix.Cluster.ConcentrationMeasurement, cluster_id: 0x042A, cluster_name: :pm25_concentration_measurement
end

defmodule Matterlix.Cluster.PM10ConcentrationMeasurement do
  @moduledoc "PM10 Concentration Measurement cluster (0x042D)."
  use Matterlix.Cluster.ConcentrationMeasurement, cluster_id: 0x042D, cluster_name: :pm10_concentration_measurement
end

defmodule Matterlix.Cluster.CarbonDioxideConcentrationMeasurement do
  @moduledoc "Carbon Dioxide Concentration Measurement cluster (0x040D)."
  use Matterlix.Cluster.ConcentrationMeasurement, cluster_id: 0x040D, cluster_name: :carbon_dioxide_concentration_measurement
end

defmodule Matterlix.Cluster.TotalVolatileOrganicCompoundsConcentrationMeasurement do
  @moduledoc "TVOC Concentration Measurement cluster (0x042E)."
  use Matterlix.Cluster.ConcentrationMeasurement, cluster_id: 0x042E, cluster_name: :tvoc_concentration_measurement
end
