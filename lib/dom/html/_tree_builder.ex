defmodule DOM.HTML.TreeBuilder do
  @moduledoc false

  # The WHATWG HTML tree-construction algorithm (§13.2.6): a stateful
  # insertion-mode state machine that reduces the tokenizer's token stream into a
  # DOM tree. Public entry is DOM.HTML.parse/1.
  #
  # This is a faithful transcription of the spec: each `process(mode, token,
  # state)` clause corresponds to one (or a group of identical) token-rules of an
  # insertion mode, cited by section number in a comment. Rules with identical
  # actions are grouped. It is a pure reduce (not a GenServer); it drives the DOM
  # GenServer through the public build API.
  #
  # Spec: https://html.spec.whatwg.org/multipage/parsing.html#tree-construction

  alias DOM.Element
  alias DOM.HTML.Token
  alias DOM.Node

  defstruct [
    :document,
    :mode,
    :original_mode,
    :head,
    :form,
    open_elements: [],
    frameset_ok: true
  ]

  # Elements parsed with the "generic raw text" (rawtext) or "generic RCDATA"
  # element parsing algorithms — both switch to the "text" insertion mode.
  @rawtext ~w(style script noframes noscript title textarea xmp iframe noembed)

  # Void elements: a start tag with no children and no end tag.
  @void ~w(area base br col embed hr img input keygen link meta param source track wbr)

  @doc "Builds a document tree from a decoded token list (§13.2.6.4)."
  @spec build([struct()]) :: Node.t()
  def build(tokens) do
    state = %__MODULE__{document: DOM.new(), mode: :initial}
    tokens |> Enum.reduce(state, &step/2) |> Map.fetch!(:document)
  end

  # A character token may carry a run of text; the spec processes one character
  # at a time, so split into leading whitespace + the rest where a mode treats
  # them differently. Modes that treat all characters the same handle the whole
  # run in one clause.
  defp step(%Token.Character{} = token, state), do: process_characters(state.mode, token, state)
  defp step(token, state), do: process(state.mode, token, state)

  # Reprocess a token in `mode` after a mode switch — dispatches by token type so
  # character tokens go through process_characters (the spec's "reprocess the
  # token" always re-runs the full per-mode handling).
  defp reprocess(mode, %Token.Character{} = token, state),
    do: process_characters(mode, token, state)

  defp reprocess(mode, token, state), do: process(mode, token, state)

  # ==========================================================================
  # §13.2.6.4.1  The "initial" insertion mode
  # ==========================================================================

  # A comment token: insert a comment as the last child of the Document.
  defp process(:initial, %Token.Comment{} = token, state) do
    append(state.document, comment(token, state))
    state
  end

  # A DOCTYPE token: append a DocumentType node to the Document (name/public/
  # system, empty string when missing). (Quirks-mode detection is deferred.)
  defp process(:initial, %Token.Doctype{} = token, state) do
    doctype =
      DOM.create_document_type(
        state.document,
        token.name || "",
        token.public_id || "",
        token.system_id || ""
      )

    append(state.document, doctype)
    %{state | mode: :before_html}
  end

  # Anything else: switch to "before html", then reprocess the token.
  defp process(:initial, token, state),
    do: reprocess(:before_html, token, %{state | mode: :before_html})

  # ==========================================================================
  # §13.2.6.4.2  The "before html" insertion mode
  # ==========================================================================

  # A DOCTYPE token: parse error, ignore.
  defp process(:before_html, %Token.Doctype{}, state), do: state

  # A comment token: insert a comment as the last child of the Document.
  defp process(:before_html, %Token.Comment{} = token, state) do
    append(state.document, comment(token, state))
    state
  end

  # A start tag whose tag name is "html": create an element for the token, append
  # it to the Document, push it onto the stack. Switch to "before head".
  defp process(:before_html, %Token.StartTag{name: "html"} = token, state) do
    html = create_element_for(token, state)
    append(state.document, html)
    %{state | open_elements: [html], mode: :before_head}
  end

  # An end tag other than head/body/html/br: parse error, ignore.
  defp process(:before_html, %Token.EndTag{name: name}, state)
       when name not in ~w(head body html br),
       do: state

  # Anything else: create an "html" element, append to Document, push. Switch to
  # "before head", then reprocess the token.
  defp process(:before_html, token, state) do
    html = create_element_for(%Token.StartTag{name: "html"}, state)
    append(state.document, html)
    reprocess(:before_head, token, %{state | open_elements: [html], mode: :before_head})
  end

  # ==========================================================================
  # §13.2.6.4.3  The "before head" insertion mode
  # ==========================================================================

  # A comment token: insert a comment.
  defp process(:before_head, %Token.Comment{} = token, state) do
    insert_comment(token, state)
    state
  end

  # A DOCTYPE token: parse error, ignore.
  defp process(:before_head, %Token.Doctype{}, state), do: state

  # A start tag whose tag name is "html": process using the "in body" rules.
  defp process(:before_head, %Token.StartTag{name: "html"} = token, state) do
    process(:in_body, token, state)
  end

  # A start tag whose tag name is "head": insert an HTML element for the token,
  # set the head element pointer, switch to "in head".
  defp process(:before_head, %Token.StartTag{name: "head"} = token, state) do
    {head, state} = insert_html_element(token, state)
    %{state | head: head, mode: :in_head}
  end

  # An end tag other than head/body/html/br: parse error, ignore.
  defp process(:before_head, %Token.EndTag{name: name}, state)
       when name not in ~w(head body html br),
       do: state

  # Anything else: insert an implied "head" element, set the head pointer, switch
  # to "in head", then reprocess the token.
  defp process(:before_head, token, state) do
    {head, state} = insert_html_element(%Token.StartTag{name: "head"}, state)
    reprocess(:in_head, token, %{state | head: head, mode: :in_head})
  end

  # ==========================================================================
  # §13.2.6.4.4  The "in head" insertion mode
  # ==========================================================================

  # A comment token: insert a comment.
  defp process(:in_head, %Token.Comment{} = token, state) do
    insert_comment(token, state)
    state
  end

  # A DOCTYPE token: parse error, ignore.
  defp process(:in_head, %Token.Doctype{}, state), do: state

  # A start tag whose tag name is "html": process using the "in body" rules.
  defp process(:in_head, %Token.StartTag{name: "html"} = token, state) do
    process(:in_body, token, state)
  end

  # base/basefont/bgsound/link/meta: insert an HTML element, immediately pop it,
  # acknowledge the self-closing flag. (Void — never has children.)
  defp process(:in_head, %Token.StartTag{name: name} = token, state)
       when name in ~w(base basefont bgsound link meta) do
    {_el, state} = insert_html_element(token, state)
    pop(state)
  end

  # title (RCDATA) / noframes/style/noscript (rawtext) / script: follow the
  # generic rawtext/RCDATA element parsing algorithm — insert the element and
  # switch to "text" mode, saving the current mode.
  defp process(:in_head, %Token.StartTag{name: name} = token, state)
       when name in @rawtext do
    {_el, state} = insert_html_element(token, state)
    %{state | original_mode: :in_head, mode: :text}
  end

  # An end tag whose tag name is "head": pop the head element, switch to "after
  # head".
  defp process(:in_head, %Token.EndTag{name: "head"}, state) do
    %{pop(state) | mode: :after_head}
  end

  # An end tag other than body/html/br: parse error, ignore.
  defp process(:in_head, %Token.EndTag{name: name}, state)
       when name not in ~w(body html br),
       do: state

  # Anything else: pop the head element, switch to "after head", reprocess.
  defp process(:in_head, token, state) do
    reprocess(:after_head, token, %{pop(state) | mode: :after_head})
  end

  # ==========================================================================
  # §13.2.6.4.6  The "after head" insertion mode
  # ==========================================================================

  # A comment token: insert a comment.
  defp process(:after_head, %Token.Comment{} = token, state) do
    insert_comment(token, state)
    state
  end

  # A DOCTYPE token: parse error, ignore.
  defp process(:after_head, %Token.Doctype{}, state), do: state

  # A start tag whose tag name is "html": process using the "in body" rules.
  defp process(:after_head, %Token.StartTag{name: "html"} = token, state) do
    process(:in_body, token, state)
  end

  # A start tag whose tag name is "body": insert an HTML element, set frameset-ok
  # to "not ok", switch to "in body".
  defp process(:after_head, %Token.StartTag{name: "body"} = token, state) do
    {_body, state} = insert_html_element(token, state)
    %{state | frameset_ok: false, mode: :in_body}
  end

  # An end tag other than body/html/br: parse error, ignore.
  defp process(:after_head, %Token.EndTag{name: name}, state)
       when name not in ~w(body html br),
       do: state

  # Anything else: insert an implied "body" element, switch to "in body",
  # reprocess.
  defp process(:after_head, token, state) do
    {_body, state} = insert_html_element(%Token.StartTag{name: "body"}, state)
    reprocess(:in_body, token, %{state | mode: :in_body})
  end

  # ==========================================================================
  # §13.2.6.4.7  The "in body" insertion mode (partial — tier 1)
  # ==========================================================================

  # A comment token: insert a comment.
  defp process(:in_body, %Token.Comment{} = token, state) do
    insert_comment(token, state)
    state
  end

  # A DOCTYPE token: parse error, ignore.
  defp process(:in_body, %Token.Doctype{}, state), do: state

  # A start tag whose tag name is "html": (tier 1) parse error, ignore.
  defp process(:in_body, %Token.StartTag{name: "html"}, state), do: state

  # A start tag for a void element: insert an HTML element, immediately pop it,
  # acknowledge the self-closing flag.
  defp process(:in_body, %Token.StartTag{name: name} = token, state) when name in @void do
    {_el, state} = insert_html_element(token, state)
    pop(state)
  end

  # A start tag for a rawtext/RCDATA element: insert + switch to "text".
  defp process(:in_body, %Token.StartTag{name: name} = token, state) when name in @rawtext do
    {_el, state} = insert_html_element(token, state)
    %{state | original_mode: :in_body, mode: :text}
  end

  # Any other start tag: reconstruct active formatting elements (tier 4 — no-op
  # here), then insert an HTML element for the token.
  defp process(:in_body, %Token.StartTag{} = token, state) do
    {_el, state} = insert_html_element(token, state)
    state
  end

  # An end tag whose tag name is "body"/"html": switch to "after body". ("html"
  # additionally reprocesses; tier 1 treats them alike.)
  defp process(:in_body, %Token.EndTag{name: name}, state) when name in ~w(body html) do
    %{state | mode: :after_body}
  end

  # Any other end tag (tier 1 simplification): pop the stack to the named element
  # if present. (The full "generate implied end tags" + scope handling is tier 2.)
  defp process(:in_body, %Token.EndTag{name: name}, state) do
    %{state | open_elements: pop_to(state.open_elements, name)}
  end

  # ==========================================================================
  # The "text" insertion mode (§13.2.6.4.8)
  # ==========================================================================

  # An end tag: pop the current node, switch back to the original insertion mode.
  defp process(:text, %Token.EndTag{}, state), do: %{pop(state) | mode: state.original_mode}

  # ==========================================================================
  # §13.2.6.4.19  The "after body" insertion mode (partial — tier 1)
  # ==========================================================================

  # A comment token: insert as the last child of the first element (the html
  # element).
  defp process(:after_body, %Token.Comment{} = token, state) do
    append(List.last(state.open_elements) || state.document, comment(token, state))
    state
  end

  # A DOCTYPE token: parse error, ignore.
  defp process(:after_body, %Token.Doctype{}, state), do: state

  # An end tag whose tag name is "html": switch to "after after body".
  defp process(:after_body, %Token.EndTag{name: "html"}, state) do
    %{state | mode: :after_after_body}
  end

  # Anything else: parse error, switch to "in body", reprocess.
  defp process(:after_body, token, state),
    do: reprocess(:in_body, token, %{state | mode: :in_body})

  # ==========================================================================
  # §13.2.6.4.22  The "after after body" insertion mode (partial — tier 1)
  # ==========================================================================

  # A comment token: insert as the last child of the Document.
  defp process(:after_after_body, %Token.Comment{} = token, state) do
    append(state.document, comment(token, state))
    state
  end

  defp process(:after_after_body, %Token.Doctype{}, state), do: state

  # Anything else: parse error, switch to "in body", reprocess.
  defp process(:after_after_body, token, state) do
    reprocess(:in_body, token, %{state | mode: :in_body})
  end

  # Not-yet-implemented modes: ignore (later tiers add clauses above this).
  defp process(_mode, _token, state), do: state

  # ==========================================================================
  # Character-token handling per mode (whitespace vs. the rest)
  # ==========================================================================

  # "initial"/"before html": whitespace characters are ignored; the non-whitespace
  # remainder runs the mode's "anything else" (the process/3 clause, which for a
  # character token performs the implied element + reprocess in the next mode).
  defp process_characters(mode, %Token.Character{data: data} = token, state)
       when mode in [:initial, :before_html] do
    case strip_leading_whitespace(data) do
      "" -> state
      rest -> process(mode, %{token | data: rest}, state)
    end
  end

  # "before head"/"in head"/"after head": leading whitespace is inserted; the
  # non-whitespace remainder runs the mode's "anything else" (process/3).
  defp process_characters(mode, %Token.Character{data: data} = token, state)
       when mode in [:before_head, :in_head, :after_head] do
    {ws, rest} = split_leading_whitespace(data)
    state = if ws != "", do: insert_characters(ws, state), else: state
    if rest == "", do: state, else: process(mode, %{token | data: rest}, state)
  end

  # "in body"/"text": insert the character run as-is. (in_body reconstructs active
  # formatting first — tier 4.)
  defp process_characters(mode, %Token.Character{data: data}, state)
       when mode in [:in_body, :text] do
    insert_characters(data, state)
  end

  # "after body"/"after after body": whitespace processed "in body"; anything
  # else reprocesses in "in body".
  defp process_characters(mode, token, state) when mode in [:after_body, :after_after_body] do
    reprocess(:in_body, token, %{state | mode: :in_body})
  end

  defp process_characters(_mode, _token, state), do: state

  # ==========================================================================
  # Tree-construction algorithms (spec-named)
  # ==========================================================================

  # "Insert an HTML element for the token": create it, append at the appropriate
  # place (the current node), push onto the stack. Returns {element, state}.
  defp insert_html_element(token, state) do
    element = create_element_for(token, state)
    append(current_node(state), element)
    {element, %{state | open_elements: [element | state.open_elements]}}
  end

  # "Insert a comment": as the last child of the current node.
  defp insert_comment(token, state), do: append(current_node(state), comment(token, state))

  # "Insert a character": into the current node, coalescing with a trailing Text
  # node so a contiguous run is one Text node.
  defp insert_characters(data, state) do
    parent = current_node(state)

    case parent |> Node.child_nodes() |> List.last() do
      %Node{type: :text} = text -> Node.set_text_content(text, Node.value(text) <> data)
      _ -> append(parent, DOM.create_text_node(state.document, data))
    end

    state
  end

  # "Create an element for the token": element + its attributes.
  defp create_element_for(token, state) do
    element = DOM.create_element(state.document, token.name)

    Enum.each(token.attributes, fn {name, value} ->
      Element.set_attribute(element, name, value)
    end)

    element
  end

  defp comment(token, state), do: DOM.create_comment(state.document, token.data)

  # ==========================================================================
  # Stack helpers
  # ==========================================================================

  # The current node = the bottommost (top-of-stack, list head) open element; the
  # Document when the stack is empty.
  defp current_node(%__MODULE__{open_elements: [current | _]}), do: current
  defp current_node(%__MODULE__{open_elements: [], document: document}), do: document

  # Pop the current node off the stack.
  defp pop(%__MODULE__{open_elements: [_ | rest]} = state), do: %{state | open_elements: rest}
  defp pop(%__MODULE__{open_elements: []} = state), do: state

  # Pop down to and including the first element named `name` (no-op if absent —
  # returns the original stack).
  defp pop_to(stack, name), do: pop_to(stack, name, stack)

  defp pop_to([el | rest], name, original) do
    if Node.node_name(el) == name, do: rest, else: pop_to(rest, name, original)
  end

  defp pop_to([], _name, original), do: original

  defp append(parent, child), do: Node.append_child(parent, child)

  # ==========================================================================
  # Whitespace helpers
  # ==========================================================================

  defp strip_leading_whitespace(data), do: String.trim_leading(data, "\t\n\f\r ")

  defp split_leading_whitespace(data) do
    rest = strip_leading_whitespace(data)
    ws_len = byte_size(data) - byte_size(rest)
    {binary_part(data, 0, ws_len), rest}
  end
end
