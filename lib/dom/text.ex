defmodule DOM.Text do
  @moduledoc """
  Operations intrinsic to Text nodes (the `CharacterData`/`Text` surface beyond
  the generic `DOM.Node` reads). Guarded on `%DOM.Node{type: :text}`, so calling
  them on another node kind fails fast.
  """

  alias DOM.Node

  @doc """
  Split the text node at `offset` (§ splitText): the original keeps characters
  `0..offset`, and a new Text node holding the remainder is inserted as the
  original's immediate next sibling. Returns the new node. Live-range boundaries
  in the original past `offset` move into the new node. Raises `IndexSizeError`
  when `offset` exceeds the length.
  """
  @spec split_text(Node.t(), non_neg_integer()) :: Node.t()
  def split_text(%Node{type: :text} = text, offset) when is_integer(offset) and offset >= 0 do
    DOM._text_split(text.server, text.node_id, offset)
  end

  @doc """
  The concatenated data of the contiguous run of Text-node siblings that includes
  `text` (the run stops at any non-Text sibling or the parent's edge).
  """
  @spec whole_text(Node.t()) :: String.t()
  def whole_text(%Node{type: :text} = text) do
    DOM._text_whole_text(text.server, text.node_id)
  end
end
