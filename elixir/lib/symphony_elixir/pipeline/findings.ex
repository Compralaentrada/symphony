defmodule SymphonyElixir.Pipeline.Findings do
  @moduledoc false

  # shortcut: exact IDs or `<id> — resolved:` only; upgrade when resolutions carry IDs separately.
  @spec resolved?(term(), term()) :: boolean()
  def resolved?(finding_id, resolutions) when is_binary(finding_id) and is_list(resolutions) do
    Enum.any?(resolutions, fn
      ^finding_id -> true
      resolution when is_binary(resolution) -> String.starts_with?(resolution, finding_id <> " — resolved:")
      _ -> false
    end)
  end

  def resolved?(_finding_id, _resolutions), do: false
end
