defmodule DOM.TokenList do
  @moduledoc """
  The `classList` DOMTokenList over an element's `class` attribute. Functions take
  the element handle (there is no live sub-object in the handle model).

  Reads parse the current `class` value into its ordered, deduplicated token set
  WITHOUT rewriting the attribute; mutations recompute the token set and write it
  back space-joined (so extra whitespace/duplicates are normalized), matching the
  browser's DOMTokenList behavior.
  """

  alias DOM.Element
  alias DOM.Node

  @doc "The element's class tokens, in order, deduplicated."
  @spec tokens(Node.t()) :: [String.t()]
  def tokens(%Node{type: :element} = element) do
    (Element.get_attribute(element, "class") || "") |> String.split() |> Enum.uniq()
  end

  @doc "The number of tokens."
  @spec length(Node.t()) :: non_neg_integer()
  def length(%Node{} = element), do: element |> tokens() |> Kernel.length()

  @doc "The token at `index`, or `nil`."
  @spec item(Node.t(), non_neg_integer()) :: String.t() | nil
  def item(%Node{} = element, index), do: element |> tokens() |> Enum.at(index)

  @doc "Whether `token` is present."
  @spec contains(Node.t(), String.t()) :: boolean()
  def contains(%Node{} = element, token), do: token in tokens(element)

  @doc "Adds each of `new_tokens` (dedup, append order preserved). Rewrites `class`."
  @spec add(Node.t(), [String.t()]) :: :ok
  def add(%Node{} = element, new_tokens) do
    write(element, tokens(element) ++ new_tokens)
  end

  @doc "Removes each of `drop` from the token set. Rewrites `class`."
  @spec remove(Node.t(), [String.t()]) :: :ok
  def remove(%Node{} = element, drop) do
    write(element, tokens(element) -- drop)
  end

  @doc """
  Toggles `token`: removes it when present, adds it when absent. `force: true` only
  adds, `force: false` only removes. Returns whether the token is present after.
  """
  @spec toggle(Node.t(), String.t(), boolean() | nil) :: boolean()
  def toggle(%Node{} = element, token, force \\ nil) do
    present = contains(element, token)
    add? = if is_nil(force), do: not present, else: force

    if add?, do: add(element, [token]), else: remove(element, [token])
    add?
  end

  @doc "Replaces `old` with `new` (only if `old` is present), returning whether it did."
  @spec replace(Node.t(), String.t(), String.t()) :: boolean()
  def replace(%Node{} = element, old, new) do
    current = tokens(element)

    if old in current do
      write(element, Enum.map(current, &if(&1 == old, do: new, else: &1)) |> Enum.uniq())
      true
    else
      false
    end
  end

  # Serialize a deduped token list back into the `class` attribute (space-joined).
  defp write(element, tokens) do
    Element.set_attribute(element, "class", tokens |> Enum.uniq() |> Enum.join(" "))
  end
end
