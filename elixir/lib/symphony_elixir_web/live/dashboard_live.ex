defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Pipeline
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    delivery = if socket.assigns.live_action == :delivery, do: Pipeline.delivery_tasks()
    {:noreply, assign(socket, :delivery, delivery)}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class={if @live_action == :index, do: "dashboard-shell operations-dashboard", else: "dashboard-shell"}>
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Compralaentrada Observability
            </p>
            <h1 class="hero-title">
              <%= if @live_action == :delivery, do: "Delivery", else: "Operations Dashboard" %>
            </h1>
            <p class="hero-copy">
              <%= if @live_action == :delivery do %>
                Pipeline issues and their current tracker state.
              <% else %>
                Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
              <% end %>
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <nav class="dashboard-nav" aria-label="Dashboard views">
        <.link
          navigate="/"
          class="subtle-button"
          aria-current={if @live_action == :index, do: "page"}
        >
          Operations
        </.link>
        <.link
          navigate="/delivery"
          class="subtle-button"
          aria-current={if @live_action == :delivery, do: "page"}
        >
          Delivery
        </.link>
      </nav>

      <%= if @live_action == :delivery do %>
        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Pipeline tasks</h2>
              <p class="section-copy">Current tracker information for issues in the pipeline.</p>
            </div>
          </div>

          <%= case @delivery do %>
            <% {:ok, []} -> %>
              <p class="empty-state">No pipeline tasks yet.</p>
            <% {:ok, tasks} -> %>
              <div class="table-wrap">
                <table class="data-table">
                  <thead>
                    <tr>
                      <th>Issue</th>
                      <th>Title</th>
                      <th>Tracker status</th>
                      <th>Latest phase result</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for row <- tasks do %>
                      <% tracker_issue = row["tracker_issue"] %>
                      <% issue = tracker_issue["issue"] %>
                      <% lookup_message = if tracker_issue["lookup"] == "error", do: "Tracker unavailable", else: "Issue not found" %>
                      <% current_state = if issue, do: issue["state"], else: lookup_message %>
                      <% phase_result = row["latest_phase_result"] %>
                      <tr>
                        <td>
                          <.issue_identifier
                            identifier={if(issue, do: issue["identifier"], else: row["task"]["issue_id"])}
                            url={if(issue, do: issue["url"])}
                          />
                        </td>
                        <td><%= if issue, do: issue["title"], else: lookup_message %></td>
                        <td>
                          <span class={state_badge_class(current_state)}><%= current_state %></span>
                        </td>
                        <td>
                          <%= if phase_result do %>
                            <%= phase_result.phase %> · <%= phase_result.result["outcome"] %>
                          <% else %>
                            No phase recorded
                          <% end %>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% {:error, _reason} -> %>
              <div class="error-card" role="status">
                <h2 class="error-title">Delivery unavailable</h2>
                <p class="error-copy">Pipeline tasks could not be loaded.</p>
              </div>
          <% end %>
        </section>
      <% else %>
      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Blocked</p>
            <p class="metric-value numeric"><%= @payload.counts.blocked %></p>
            <p class="metric-detail">Issues paused for operator input or approval.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Current runtime activity, ordered newest first.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <ol class="session-timeline" aria-label="Active sessions ordered by latest activity">
              <li :for={entry <- sort_by_recent_activity(@payload.running)} class="session-timeline-item">
                <span class="session-timeline-marker" aria-hidden="true"></span>
                <article class="session-timeline-entry">
                  <header class="session-timeline-header">
                    <div class="issue-stack">
                      <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                      <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                    </div>
                    <span class={state_badge_class(entry.state, true)}>
                      <%= entry.state %>
                    </span>
                  </header>

                  <p class="session-timeline-activity">
                    <%= entry.last_message || to_string(entry.last_event || "No activity reported yet") %>
                  </p>

                  <div class="session-timeline-meta">
                    <div>
                      <span class="session-timeline-label">Duration</span>
                      <span class="numeric"><%= format_runtime_seconds(runtime_seconds_from_started_at(entry.started_at, @now)) %></span>
                    </div>
                    <div>
                      <span class="session-timeline-label">Latest activity</span>
                      <%= if entry.last_event_at do %>
                        <time class="mono numeric" datetime={entry.last_event_at}><%= entry.last_event_at %></time>
                      <% else %>
                        <span class="muted">No activity reported yet</span>
                      <% end %>
                    </div>
                    <div>
                      <span class="session-timeline-label">Model</span>
                      <span><%= entry.model || "No disponible" %></span>
                    </div>
                    <div>
                      <span class="session-timeline-label">Reasoning</span>
                      <span><%= entry.reasoning_effort || "No disponible" %></span>
                    </div>
                    <%= if entry[:pipeline_phase] do %>
                      <div>
                        <span class="session-timeline-label">Pipeline phase</span>
                        <span><%= entry.pipeline_phase %></span>
                      </div>
                    <% end %>
                  </div>
                </article>
              </li>
            </ol>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Blocked sessions</h2>
              <p class="section-copy">Issues paused because Codex requested operator input or approval.</p>
            </div>
          </div>

          <%= if @payload.blocked == [] do %>
            <p class="empty-state">No blocked sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 760px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Blocked at</th>
                    <th>Last update</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.blocked}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state || "Blocked")}>
                        <%= entry.state || "Blocked" %>
                      </span>
                    </td>
                    <td>
                      <%= if entry.session_id do %>
                        <button
                          type="button"
                          class="subtle-button"
                          data-label="Copy ID"
                          data-copy={entry.session_id}
                          onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                        >
                          Copy ID
                        </button>
                      <% else %>
                        <span class="muted">n/a</span>
                      <% end %>
                    </td>
                    <td class="mono"><%= entry.blocked_at || "n/a" %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  attr(:identifier, :string, required: true)
  attr(:url, :string, default: nil)

  defp issue_identifier(assigns) do
    assigns = assign(assigns, :href, external_issue_url(assigns.url))

    ~H"""
    <%= if @href do %>
      <a
        class="issue-id issue-id-link"
        href={@href}
        target="_blank"
        rel="noopener noreferrer"
        aria-label={"Open #{@identifier} in the issue tracker"}
      ><%= @identifier %></a>
    <% else %>
      <span class="issue-id"><%= @identifier %></span>
    <% end %>
    """
  end

  defp external_issue_url(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        url

      _ ->
        nil
    end
  end

  defp external_issue_url(_url), do: nil

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp sort_by_recent_activity(entries) do
    Enum.sort_by(entries, &(&1.last_event_at || &1.started_at || ""), :desc)
  end

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state, operations \\ false) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) or (operations and String.contains?(normalized, "building")) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
