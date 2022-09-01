defmodule Tesla.Middleware.OpenTelemetry do
  @moduledoc """
  Creates OpenTelemetry spans and injects tracing headers into HTTP requests

  When used with `Tesla.Middleware.PathParams`, the span name will be created
  based on the provided path. Without it, the span name follow OpenTelemetry
  standards and use just the method name, if not being overriden by opts.

  NOTE: This middleware needs to come before `Tesla.Middleware.PathParams`

  ## Options

    - `:span_name` - override span name (string)
    - `:skip_propagation` - omit propagation headers in the http call (boolean)

  """
  require OpenTelemetry.Tracer
  @behaviour Tesla.Middleware

  def call(env, next, opts) do
    span_name = Keyword.get(opts, :span_name, get_span_name(env))
    skip_propagation? = Keyword.get(opts, :skip_propagation, false)

    OpenTelemetry.Tracer.with_span span_name, %{kind: :client} do
      env
      |> inject_headers(skip_propagation?)
      |> Tesla.run(next)
      |> set_span_attributes()
      |> handle_result()
    end
  end

  defp get_span_name(env) do
    case env.opts[:path_params] do
      nil -> "HTTP #{http_method(env.method)}"
      _ -> URI.parse(env.url).path
    end
  end

  defp inject_headers(env, true = _skip_propagation?), do: env

  defp inject_headers(env, _skip_propagation?) do
    Tesla.put_headers(env, :otel_propagator_text_map.inject([]))
  end

  defp set_span_attributes({_, %Tesla.Env{} = env} = result) do
    OpenTelemetry.Tracer.set_attributes(build_attrs(env))

    result
  end

  defp set_span_attributes(result) do
    result
  end

  defp handle_result({:ok, %Tesla.Env{status: status} = env}) when status > 400 do
    OpenTelemetry.Tracer.set_status(OpenTelemetry.status(:error, ""))

    {:ok, env}
  end

  defp handle_result({:error, {Tesla.Middleware.FollowRedirects, :too_many_redirects}} = result) do
    OpenTelemetry.Tracer.set_status(OpenTelemetry.status(:error, ""))

    result
  end

  defp handle_result({:ok, env}) do
    {:ok, env}
  end

  defp handle_result(result) do
    OpenTelemetry.Tracer.set_status(OpenTelemetry.status(:error, ""))

    result
  end

  defp build_attrs(%Tesla.Env{
         method: method,
         url: url,
         status: status_code,
         headers: headers,
         query: query
       }) do
    url = Tesla.build_url(url, query)
    uri = URI.parse(url)

    attrs = %{
      "http.method": http_method(method),
      "http.url": url,
      "http.target": uri.path,
      "http.host": uri.host,
      "http.scheme": uri.scheme,
      "http.status_code": status_code
    }

    maybe_append_content_length(attrs, headers)
  end

  defp maybe_append_content_length(attrs, headers) do
    case Enum.find(headers, fn {k, _v} -> k == "content-length" end) do
      nil ->
        attrs

      {_key, content_length} ->
        Map.put(attrs, :"http.response_content_length", content_length)
    end
  end

  defp http_method(method) do
    method
    |> Atom.to_string()
    |> String.upcase()
  end
end
