defmodule TelemetryMetricsAppsignal do
  @moduledoc """
  AppSignal Reporter for [`Telemetry.Metrics`](https://github.com/beam-telemetry/telemetry_metrics) definitions.

  Provide a list of metric definitions to the `init/2` function. It's recommended to
  run TelemetryMetricsAppsignal under a supervision tree, either in your main application
  or as recommended [here](https://hexdocs.pm/phoenix/telemetry.html#the-telemetry-supervisor).

      def start_link(_arg) do
        children = [
          {TelemetryMetricsAppsignal, [metrics: metrics()]}
        ...
        ]
        Supervisor.init(children, strategy: :one_for_one)
      end

      defp metrics, do:
        [
          summary("phoenix.endpoint.stop.duration"),
          last_value("vm.memory.total"),
          counter("my_app.my_server.call.exception")
        ]


  The following table shows how `Telemetry.Metrics` metrics map to AppSignal metrics:
  | Telemetry.Metrics     | AppSignal |
  |-----------------------|-----------|
  | `last_value`          | [guage](https://docs.appsignal.com/metrics/custom.html#gauge) |
  | `counter`             | [counter](https://docs.appsignal.com/metrics/custom.html#counter) |
  | `sum`                 | [guage](https://docs.appsignal.com/metrics/custom.html#gauge) |
  | `summary`             | [measurement](https://docs.appsignal.com/metrics/custom.html#measurement) |
  | `distribution`        | Not supported |
  """
  use GenServer
  require Logger

  alias Telemetry.Metrics.Counter
  alias Telemetry.Metrics.LastValue
  alias Telemetry.Metrics.Sum
  alias Telemetry.Metrics.Summary

  @appsignal Application.compile_env(:telemetry_metrics_appsignal, :appsignal, Appsignal)

  @type metric ::
          Counter.t()
          | LastValue.t()
          | Sum.t()
          | Summary.t()

  @spec start_link([metric]) :: :ignore | {:error, any} | {:ok, pid}
  def start_link(opts) do
    server_opts = Keyword.take(opts, [:name])

    metrics =
      opts[:metrics] ||
        raise ArgumentError, "the :metrics option is required by #{inspect(__MODULE__)}"

    GenServer.start_link(__MODULE__, metrics, server_opts)
  end

  @impl true
  @spec init([metric]) :: {:ok, [any]}
  def init(metrics) do
    Process.flag(:trap_exit, true)
    groups = Enum.group_by(metrics, & &1.event_name)

    for {event, metrics} <- groups do
      id = {__MODULE__, event, self()}
      :telemetry.attach(id, event, &handle_event/4, metrics)
    end

    {:ok, Map.keys(groups)}
  end

  @impl true
  def terminate(_, events) do
    for event <- events do
      :telemetry.detach({__MODULE__, event, self()})
    end

    :ok
  end

  defp handle_event(event_name, measurements, metadata, metrics) do
    for metric <- metrics do
      try do
        if measurement = extract_measurement(metric, measurements) do
          tags = extract_tags(metric, metadata)

          event_name
          |> Enum.join(".")
          |> send_metric(metric, measurement, tags)
        end
      rescue
        e ->
          Logger.error("Could not format metric #{inspect(metric)}")
          Logger.error(Exception.format(:error, e, __STACKTRACE__))
      end
    end
  end

  defp send_metric(event_name, _metric = %Counter{}, _measurement, tags) do
    call_appsignal(:increment_counter, event_name, 1, tags)
  end

  defp send_metric(event_name, _metric = %Summary{}, measurement, tags) do
    call_appsignal(:add_distribution_value, event_name, measurement, tags)
  end

  defp send_metric(event_name, _metric = %LastValue{}, measurement, tags) do
    call_appsignal(:set_gauge, event_name, measurement, tags)
  end

  defp send_metric(event_name, _metric = %Sum{}, measurement, tags) do
    call_appsignal(:increment_counter, event_name, measurement, tags)
  end

  defp send_metric(_event_name, metric, _measurements, _tags) do
    Logger.warn("Ignoring unsupported metric #{inspect(metric)}")
  end

  defp call_appsignal(function_name, event_name, measurement, tags)
       when is_binary(event_name) and is_number(measurement) and is_map(tags) do
    apply(@appsignal, function_name, [event_name, measurement, tags])
  end

  defp call_appsignal(function_name, event_name, measurement, tags) do
    Logger.warn("""
    Attempted to send metrics invalid with AppSignal library: \
    #{inspect(function_name)}(\
    #{inspect(event_name)}, \
    #{inspect(measurement)}, \
    #{inspect(tags)}\
    )
    """)
  end

  defp extract_measurement(metric, measurements) do
    case metric.measurement do
      fun when is_function(fun, 1) -> fun.(measurements)
      key -> measurements[key]
    end
  end

  defp extract_tags(metric, metadata) do
    tag_values = metric.tag_values.(metadata)
    Map.take(tag_values, metric.tags)
  end
end
