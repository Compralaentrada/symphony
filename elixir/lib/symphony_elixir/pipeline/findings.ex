defmodule SymphonyElixir.Pipeline.Findings do
  @moduledoc false

  # shortcut: recognized resolution prefixes only; upgrade when resolutions carry IDs separately.
  @spec resolved?(term(), term()) :: boolean()
  def resolved?(finding_id, resolutions) when is_binary(finding_id) and is_list(resolutions) do
    Enum.any?(resolutions, fn
      ^finding_id ->
        true

      resolution when is_binary(resolution) ->
        String.starts_with?(resolution, [finding_id <> " — resolved:", finding_id <> ": Resuelto;", finding_id <> ": Resuelto:"])

      _ ->
        false
    end)
  end

  def resolved?(_finding_id, _resolutions), do: false
end
