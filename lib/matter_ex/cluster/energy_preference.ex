defmodule MatterEx.Cluster.EnergyPreference do
  @moduledoc """
  Matter Energy Preference cluster (0x009B).

  Allows users to express energy vs. comfort trade-offs.
  EnergyBalances lists available profiles; CurrentEnergyBalance
  selects the active one.

  Optional on energy-manageable device endpoints.
  """

  use MatterEx.Cluster, id: 0x009B, name: :energy_preference

  # EnergyBalances: list of balance structs {step, label}
  attribute 0x0000, :energy_balances, :list, default: [
    %{step: 0, label: "Max Comfort"},
    %{step: 50, label: "Balanced"},
    %{step: 100, label: "Max Efficiency"}
  ]
  # CurrentEnergyBalance: index into EnergyBalances
  attribute 0x0001, :current_energy_balance, :uint8, default: 1, writable: true
  # EnergyPriorities: list of priority enums (0=Comfort, 1=Speed, 2=Efficiency, 3=WaterConsumption)
  attribute 0x0002, :energy_priorities, :list, default: [0, 2]
  attribute 0xFFFC, :feature_map, :uint32, default: 0x01
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1
end
