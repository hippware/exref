defmodule Exref do
  @moduledoc false

  @doc false
  defmacro __using__(opts) do
    quote do
      Module.register_attribute(__MODULE__, :ignore_xref, persist: true)
      Module.put_attribute(__MODULE__, :ignore_xref, unquote(opts)[:ignore])
    end
  end
end
