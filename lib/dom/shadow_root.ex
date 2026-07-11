defmodule DOM.ShadowRoot do
  @moduledoc """
  Operations on a shadow root handle (`%DOM.Node{type: :shadow_root}`). A shadow
  root is a detached root tree hosted by an element; build its tree with the
  generic `DOM.Node` mutators (`append_child`/`insert_before`) — this module adds
  the shadow-root-specific `innerHTML`, `host`, and `mode`.
  """

  alias DOM.Node
  alias DOM.NodeData.Table

  @doc "The shadow tree serialized as HTML (its children)."
  @spec inner_html(Node.t()) :: String.t()
  def inner_html(%Node{type: :shadow_root} = shadow) do
    DOM._shadow_inner_html(shadow.server, shadow.node_id)
  end

  @doc "Replace the shadow tree by fragment-parsing `html` into the shadow root."
  @spec set_inner_html(Node.t(), String.t()) :: :ok
  def set_inner_html(%Node{type: :shadow_root} = shadow, html) do
    DOM._shadow_set_inner_html(shadow.server, shadow.node_id, html)
  end

  @doc "The shadow root's host element."
  @spec host(Node.t()) :: Node.t()
  def host(%Node{type: :shadow_root} = shadow), do: DOM._shadow_host(shadow)

  @doc "The shadow root's mode (`:open` or `:closed`)."
  @spec mode(Node.t()) :: :open | :closed
  def mode(%Node{type: :shadow_root} = shadow) do
    DOM._atomic_ets_op(shadow.server, fn nodes, _index ->
      Table.shadow_mode(nodes, shadow.node_id)
    end)
  end
end
