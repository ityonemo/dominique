defmodule DOM.CharacterData do
  @moduledoc """
  The CharacterData string API for Text and Comment nodes: `length`,
  `substring_data`, `append_data`, `insert_data`, `delete_data`, `replace_data`.
  Each is guarded on `type: :text | :comment`, so calling one on another kind fails
  fast. `replace_data` is the primitive — the others express in terms of it — and
  every mutation adjusts live Range boundaries in the node (per the DOM's
  replace-data steps).
  """

  # CharacterData.length shadows Kernel.length/1 (unused here — we use String.length).
  import Kernel, except: [length: 1]

  alias DOM.Node

  @chardata [:text, :comment]

  @doc "The number of code units in the node's data."
  @spec length(Node.t()) :: non_neg_integer()
  def length(%Node{type: type} = node) when type in @chardata do
    node |> Node.value() |> String.length()
  end

  @doc """
  `count` code units of the node's data starting at `offset`. Raises
  `DOM.IndexSizeError` when `offset` exceeds the length; a `count` past the end is
  clamped.
  """
  @spec substring_data(Node.t(), non_neg_integer(), non_neg_integer()) :: String.t()
  def substring_data(%Node{type: type} = node, offset, count) when type in @chardata do
    value = Node.value(node)
    if offset > String.length(value), do: raise(DOM.IndexSizeError)
    value |> String.slice(offset, count)
  end

  @doc "Appends `data` to the node's data."
  @spec append_data(Node.t(), String.t()) :: :ok
  def append_data(%Node{type: type} = node, data) when type in @chardata do
    replace_data(node, length(node), 0, data)
  end

  @doc "Inserts `data` at `offset`."
  @spec insert_data(Node.t(), non_neg_integer(), String.t()) :: :ok
  def insert_data(%Node{type: type} = node, offset, data) when type in @chardata do
    replace_data(node, offset, 0, data)
  end

  @doc "Deletes `count` code units at `offset`."
  @spec delete_data(Node.t(), non_neg_integer(), non_neg_integer()) :: :ok
  def delete_data(%Node{type: type} = node, offset, count) when type in @chardata do
    replace_data(node, offset, count, "")
  end

  @doc """
  Replaces `count` code units at `offset` with `data`. Raises `DOM.IndexSizeError`
  when `offset` exceeds the length; a `count` past the end is clamped. Adjusts live
  Range boundaries in the node.
  """
  @spec replace_data(Node.t(), non_neg_integer(), non_neg_integer(), String.t()) :: :ok
  def replace_data(%Node{type: type} = node, offset, count, data) when type in @chardata do
    DOM._char_data_replace(node.server, node.node_id, offset, count, data)
  end
end
