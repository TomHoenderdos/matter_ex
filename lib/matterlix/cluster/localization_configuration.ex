defmodule Matterlix.Cluster.LocalizationConfiguration do
  @moduledoc """
  Matter Localization Configuration cluster (0x002B).

  Configures the device's language/locale. ActiveLocale is a BCP-47
  locale string (e.g. "en-US"). SupportedLocales lists available options.

  Required on endpoint 0 for devices with user-facing strings.
  """

  use Matterlix.Cluster, id: 0x002B, name: :localization_configuration

  attribute 0x0000, :active_locale, :string, default: "en-US", writable: true
  attribute 0x0001, :supported_locales, :list, default: ["en-US"]
  attribute 0xFFFC, :feature_map, :uint32, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1
end
