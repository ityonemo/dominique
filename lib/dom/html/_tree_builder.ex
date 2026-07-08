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

  # "generate implied end tags" (§13.2.6.3): while the current node is one of
  # these, pop it. An optional exception name is excluded from the set.
  @implied_end_tags ~w(dd dt li optgroup option p rb rp rt rtc)

  # "have an element in scope" default scope set (§13.2.4.2): elements that
  # terminate the upward scope search. (Foreign-content members deferred to
  # tier 5; all HTML-namespace here since we have no namespace model yet.)
  @scope_markers ~w(applet caption html table td th marquee object template)

  # "in button scope" adds "button"; "in list item scope" adds "ol"/"ul".
  @button_scope_markers ["button" | @scope_markers]
  @list_item_scope_markers ~w(ol ul) ++ @scope_markers

  @doc "Builds a document tree from a decoded token list (§13.2.6.4)."
  @spec build([struct()]) :: Node.t()
  def build(tokens) do
    state = %__MODULE__{document: DOM.new(), mode: :initial}
    tokens |> Enum.reduce(state, &step/2) |> eof() |> Map.fetch!(:document)
  end

  # A character token may carry a run of text; the spec processes one character
  # at a time, so split into leading whitespace + the rest where a mode treats
  # them differently. Modes that treat all characters the same handle the whole
  # run in one clause.
  defp step(%Token.Character{} = token, state), do: process_characters(state.mode, token, state)
  defp step(token, state), do: process(state.mode, token, state)

  # End-of-file: the pre-body insertion modes imply the missing elements (so an
  # empty or head-only document still yields <html><head><body>). Each mode's EOF
  # rule follows its "anything else" path; we chain the implied elements.
  defp eof(%__MODULE__{mode: :initial} = state), do: eof(%{state | mode: :before_html})

  defp eof(%__MODULE__{mode: :before_html} = state) do
    html = create_element_for(%Token.StartTag{name: "html"}, state)
    append(state.document, html)
    eof(%{state | open_elements: [html], mode: :before_head})
  end

  defp eof(%__MODULE__{mode: :before_head} = state) do
    {head, state} = insert_html_element(%Token.StartTag{name: "head"}, state)
    eof(%{state | head: head, mode: :in_head})
  end

  defp eof(%__MODULE__{mode: :in_head} = state), do: eof(%{pop(state) | mode: :after_head})

  defp eof(%__MODULE__{mode: :after_head} = state) do
    {_body, state} = insert_html_element(%Token.StartTag{name: "body"}, state)
    %{state | mode: :in_body}
  end

  defp eof(state), do: state

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
  # §13.2.6.4.7  The "in body" insertion mode (tier 2 — in-body repairs)
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

  # A start tag whose tag name is one of the "in head" tags (base/link/meta/…/
  # title/style/script/…): process using the "in head" rules.
  defp process(:in_body, %Token.StartTag{name: name} = token, state)
       when name in ~w(base basefont bgsound link meta) or name in @rawtext do
    process(:in_head, token, state)
  end

  # A start tag "hr": if a p is in button scope, close it; insert an HTML
  # element, immediately pop it (void), acknowledge self-closing; frameset-ok
  # not ok.
  defp process(:in_body, %Token.StartTag{name: "hr"} = token, state) do
    {_el, state} = insert_html_element(token, close_p_if_button_scope(state))
    %{pop(state) | frameset_ok: false}
  end

  # A start tag "image": a parse error — act as if it were "img".
  defp process(:in_body, %Token.StartTag{name: "image"} = token, state) do
    process(:in_body, %{token | name: "img"}, state)
  end

  # A start tag "pre"/"listing": close a p element in button scope, insert an
  # HTML element; a following newline character is dropped (§13.2.6.4.7 — handled
  # by the tokenizer/text step is deferred); frameset-ok not ok.
  defp process(:in_body, %Token.StartTag{name: name} = token, state)
       when name in ~w(pre listing) do
    {_el, state} = insert_html_element(token, close_p_if_button_scope(state))
    %{state | frameset_ok: false}
  end

  # A start tag "form": if there is a form element pointer and no template on the
  # stack, ignore (parse error). Otherwise close a p in button scope, insert, and
  # set the form element pointer.
  defp process(:in_body, %Token.StartTag{name: "form"} = token, state) do
    if state.form do
      state
    else
      {form, state} = insert_html_element(token, close_p_if_button_scope(state))
      %{state | form: form}
    end
  end

  # A start tag for a void element: insert an HTML element, immediately pop it,
  # acknowledge the self-closing flag.
  defp process(:in_body, %Token.StartTag{name: name} = token, state) when name in @void do
    {_el, state} = insert_html_element(token, state)
    pop(state)
  end

  # A start tag for "address, article, aside, …, div, dl, …, p, section, …"
  # (the block-level group): if the stack has a p element in button scope, close
  # it; then insert an HTML element.
  defp process(:in_body, %Token.StartTag{name: name} = token, state)
       when name in ~w(address article aside blockquote center details dialog dir
                       div dl fieldset figcaption figure footer header hgroup main
                       menu nav ol p section summary ul) do
    {_el, state} = insert_html_element(token, close_p_if_button_scope(state))
    state
  end

  # A start tag "h1".."h6": close a p element in button scope; if the current
  # node is itself a heading, pop it (parse error); insert an HTML element.
  defp process(:in_body, %Token.StartTag{name: name} = token, state)
       when name in ~w(h1 h2 h3 h4 h5 h6) do
    state = close_p_if_button_scope(state)
    state = if heading?(current_node(state)), do: pop(state), else: state
    {_el, state} = insert_html_element(token, state)
    state
  end

  # A start tag "li": frameset-ok not ok (deferred); walk the stack popping
  # generate-implied-end-tags-style from any open "li", closing it; then close a
  # p element in button scope and insert.
  defp process(:in_body, %Token.StartTag{name: "li"} = token, state) do
    state = close_list_item(state, ["li"])
    state = close_p_if_button_scope(state)
    {_el, state} = insert_html_element(token, state)
    state
  end

  # A start tag "dd"/"dt": as "li" but keyed on dd/dt.
  defp process(:in_body, %Token.StartTag{name: name} = token, state)
       when name in ~w(dd dt) do
    state = close_list_item(state, ~w(dd dt))
    state = close_p_if_button_scope(state)
    {_el, state} = insert_html_element(token, state)
    state
  end

  # A start tag "button": if a button is in scope, generate implied end tags and
  # pop through the button (parse error); reconstruct (tier 4); insert; frameset-
  # ok not ok.
  defp process(:in_body, %Token.StartTag{name: "button"} = token, state) do
    state =
      if has_in_scope?(state, "button", @scope_markers) do
        state |> generate_implied_end_tags() |> pop_through("button")
      else
        state
      end

    {_el, state} = insert_html_element(token, state)
    state
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

  # An end tag for a block-level element ("address, …, div, …, ul, …"): if it is
  # in scope, generate implied end tags then pop through it (else parse error,
  # ignore).
  defp process(:in_body, %Token.EndTag{name: name}, state)
       when name in ~w(address article aside blockquote button center details
                       dialog dir div dl fieldset figcaption figure footer header
                       hgroup listing main menu nav ol pre section summary ul) do
    if has_in_scope?(state, name, @scope_markers) do
      state |> generate_implied_end_tags() |> pop_through(name)
    else
      state
    end
  end

  # An end tag "form" (no template on the stack — templates are a later tier):
  # let node be the form pointer and clear it; if node is null or not in scope,
  # ignore; otherwise generate implied end tags and remove node from the stack.
  defp process(:in_body, %Token.EndTag{name: "form"}, state) do
    node = state.form
    state = %{state | form: nil}

    if node && has_in_scope?(state, "form", @scope_markers) do
      state
      |> generate_implied_end_tags()
      |> then(&%{&1 | open_elements: drop_including(&1.open_elements, node)})
    else
      state
    end
  end

  # An end tag "p": if there is no p element in button scope, insert one (parse
  # error) then close it; otherwise close a p element.
  defp process(:in_body, %Token.EndTag{name: "p"}, state) do
    state =
      if has_in_scope?(state, "p", @button_scope_markers) do
        state
      else
        {_el, state} = insert_html_element(%Token.StartTag{name: "p"}, state)
        state
      end

    close_p_element(state)
  end

  # An end tag "li": if in list-item scope, generate implied end tags except li,
  # then pop through the li (else parse error, ignore).
  defp process(:in_body, %Token.EndTag{name: "li"}, state) do
    if has_in_scope?(state, "li", @list_item_scope_markers) do
      state |> generate_implied_end_tags("li") |> pop_through("li")
    else
      state
    end
  end

  # An end tag "dd"/"dt": if in scope, generate implied end tags except it, then
  # pop through it (else parse error, ignore).
  defp process(:in_body, %Token.EndTag{name: name}, state) when name in ~w(dd dt) do
    if has_in_scope?(state, name, @scope_markers) do
      state |> generate_implied_end_tags(name) |> pop_through(name)
    else
      state
    end
  end

  # An end tag "h1".."h6": if any heading is in scope, generate implied end tags
  # then pop through the first heading on the stack (else parse error, ignore).
  defp process(:in_body, %Token.EndTag{name: name}, state) when name in ~w(h1 h2 h3 h4 h5 h6) do
    if any_heading_in_scope?(state) do
      state |> generate_implied_end_tags() |> pop_through_heading()
    else
      state
    end
  end

  # Any other end tag: walk the stack from the current node; on a node whose name
  # matches, generate implied end tags (except that name) and pop through it; on
  # a "special" element, stop (parse error, ignore). (Non-special elements not
  # matching are the adoption-agency's job — tier 4; here we walk past them.)
  defp process(:in_body, %Token.EndTag{name: name}, state) do
    any_other_end_tag(state, name, state.open_elements)
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

  # Pop the stack down to and INCLUDING the first element named `name`. (Callers
  # guarantee it is present via a scope check.)
  defp pop_through(state, name) do
    %{state | open_elements: pop_to(state.open_elements, name)}
  end

  # Pop down to and including the first heading (h1..h6) on the stack.
  defp pop_through_heading(%__MODULE__{open_elements: [el | rest]} = state) do
    if heading?(el),
      do: %{state | open_elements: rest},
      else: pop_through_heading(%{state | open_elements: rest})
  end

  # ==========================================================================
  # §13.2.6.3 / §13.2.4.2  Implied-end-tag and scope algorithms
  # ==========================================================================

  # "Generate implied end tags": while the current node is an implied-end-tag
  # element (optionally excluding `except`), pop it.
  defp generate_implied_end_tags(state, except \\ nil) do
    node = current_node(state)
    name = Node.node_name(node)

    if name in @implied_end_tags and name != except do
      generate_implied_end_tags(pop(state), except)
    else
      state
    end
  end

  # "Close a p element" (§13.2.6.4.7): generate implied end tags except p, then
  # pop through the p element.
  defp close_p_element(state) do
    state |> generate_implied_end_tags("p") |> pop_through("p")
  end

  # If a p element is in button scope, close it (used by block-level start tags).
  defp close_p_if_button_scope(state) do
    if has_in_scope?(state, "p", @button_scope_markers), do: close_p_element(state), else: state
  end

  # "li"/"dd"/"dt" start tags (§13.2.6.4.7): walk the stack from the current
  # node; on a `names` element, generate implied end tags (except it) and pop
  # through it, stopping. Stop early (without closing) on a "special" element
  # that is not address/div/p.
  defp close_list_item(state, names), do: close_list_item(state, names, state.open_elements)

  defp close_list_item(state, names, [node | rest]) do
    name = Node.node_name(node)

    cond do
      name in names -> state |> generate_implied_end_tags(name) |> pop_through(name)
      special?(name) and name not in ~w(address div p) -> state
      :else -> close_list_item(state, names, rest)
    end
  end

  defp close_list_item(state, _names, []), do: state

  # "Have an element named `name` in scope", parameterized by the terminating
  # marker set: walk the stack; a match returns true, a marker returns false.
  defp has_in_scope?(state, name, markers), do: in_scope?(state.open_elements, name, markers)

  defp in_scope?([el | rest], name, markers) do
    node_name = Node.node_name(el)

    cond do
      node_name == name -> true
      node_name in markers -> false
      :else -> in_scope?(rest, name, markers)
    end
  end

  defp in_scope?([], _name, _markers), do: false

  # "Have a heading (h1..h6) in scope" (for the heading end tag): walk the stack;
  # any heading returns true, a default-scope marker returns false.
  defp any_heading_in_scope?(state), do: heading_in_scope?(state.open_elements)

  defp heading_in_scope?([el | rest]) do
    name = Node.node_name(el)

    cond do
      heading?(el) -> true
      name in @scope_markers -> false
      :else -> heading_in_scope?(rest)
    end
  end

  defp heading_in_scope?([]), do: false

  # "Any other end tag" loop (§13.2.6.4.7): walk from the current node; a matching
  # element closes (generate implied end tags except it, pop through it); a
  # "special" element stops the loop (parse error, ignore).
  defp any_other_end_tag(state, name, [el | rest]) do
    node_name = Node.node_name(el)

    cond do
      node_name == name ->
        state
        |> generate_implied_end_tags(name)
        |> then(&%{&1 | open_elements: drop_including(&1.open_elements, el)})

      special?(node_name) ->
        state

      :else ->
        any_other_end_tag(state, name, rest)
    end
  end

  defp any_other_end_tag(state, _name, []), do: state

  # Drop stack entries up to and including `el` (by identity).
  defp drop_including([el | rest], el), do: rest
  defp drop_including([_ | rest], el), do: drop_including(rest, el)

  defp heading?(node), do: Node.node_name(node) in ~w(h1 h2 h3 h4 h5 h6)

  # "Special" category elements (§13.2.6.4.7 — subset relevant to tier 2's end-tag
  # loop; the full list grows as later tiers add table/foreign handling).
  @special ~w(address applet area article aside base basefont bgsound blockquote
              body br button caption center col colgroup dd details dir div dl dt
              embed fieldset figcaption figure footer form frame frameset h1 h2 h3
              h4 h5 h6 head header hgroup hr html iframe img input keygen li link
              listing main marquee menu meta nav noembed noframes noscript object
              ol p param plaintext pre script section select source style summary
              table tbody td template textarea tfoot th thead title tr track ul
              wbr xmp)

  defp special?(name), do: name in @special

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
