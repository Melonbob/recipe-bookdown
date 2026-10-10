-- recipe.lua : pandoc Lua filter for the HTML (gitbook) build only.
--
-- The recipes are written with the LaTeX `cuisine` package
-- (\begin{recipe} ... \ingredient ... \newstep ... \end{recipe}).
-- LaTeX understands that; HTML output silently drops it. This filter turns
-- each recipe block into real HTML, and builds the "Browse by Type / Cook"
-- pages from the <!-- Type:X --> and <!-- Cook:Y --> comments in each recipe.
--
-- The PDF build does not use this filter, so the PDF is unchanged.

local stringify = pandoc.utils.stringify
local MDFMT = "markdown-tex_math_dollars-raw_tex"

------------------------------------------------------------------------
-- small helpers
-- NB: never use %s here; in a Windows locale it matches half of a UTF-8
-- non-breaking space and leaves invalid UTF-8 behind. [ \t\r\n] is explicit.
------------------------------------------------------------------------

local function trim(s) return (s:gsub("^[ \t\r\n]+", ""):gsub("[ \t\r\n]+$", "")) end

local function slug(s)
  s = s:lower():gsub("[^%w]+", "-"):gsub("^-+", ""):gsub("-+$", "")
  return s
end

local function warn(msg) io.stderr:write("[recipe.lua] " .. msg .. "\n") end

-- LaTeX comments: an unescaped % to end of line
local function strip_comments(text)
  local out = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    line = line:gsub("^%%.*$", ""):gsub("([^\\])%%.*$", "%1")
    out[#out + 1] = line
  end
  return table.concat(out, "\n")
end

------------------------------------------------------------------------
-- LaTeX fragment -> markdown -> pandoc inlines/blocks
------------------------------------------------------------------------

local VULGAR = {
  ["1/2"] = "½", ["1/3"] = "⅓", ["2/3"] = "⅔", ["1/4"] = "¼", ["3/4"] = "¾",
  ["1/5"] = "⅕", ["2/5"] = "⅖", ["3/5"] = "⅗", ["4/5"] = "⅘", ["1/6"] = "⅙",
  ["5/6"] = "⅚", ["1/8"] = "⅛", ["3/8"] = "⅜", ["5/8"] = "⅝", ["7/8"] = "⅞",
}
local function frac(n, d) return VULGAR[n .. "/" .. d] or (n .. "⁄" .. d) end

local ACCENTS = {
  ["'"] = { a = "á", e = "é", i = "í", o = "ó", u = "ú", A = "Á", E = "É", I = "Í", O = "Ó", U = "Ú" },
  ["`"] = { a = "à", e = "è", i = "ì", o = "ò", u = "ù", A = "À", E = "È" },
  ['"'] = { a = "ä", e = "ë", i = "ï", o = "ö", u = "ü" },
  ["^"] = { a = "â", e = "ê", i = "î", o = "ô", u = "û" },
  ["~"] = { n = "ñ", N = "Ñ" },
}

local function tex_to_md(s)
  -- fractions: \fr{1}{4}  \fr3/4  \fr12  \fr 12
  s = s:gsub("\\fr[ \t\r\n]*{(%d+)}[ \t\r\n]*{(%d+)}", frac)
  s = s:gsub("\\fr[ \t\r\n]*(%d+)/(%d+)", frac)
  s = s:gsub("\\fr[ \t\r\n]*(%d)(%d)", frac)
  -- degrees (\degrees and the \0 shorthand used in some recipes)
  s = s:gsub("[ \t\r\n]*\\degrees[ \t\r\n]*", "°")
  s = s:gsub("[ \t\r\n]*\\0[ \t\r\n]*", "°")
  -- accents: \'{e}  \'e
  s = s:gsub("\\(['`^\"~])[ \t\r\n]*{?(%a)}?", function(acc, l)
    local m = ACCENTS[acc]
    return (m and m[l]) or l
  end)
  -- simple formatting
  s = s:gsub("\\textit[ \t\r\n]*{([^}]*)}", "*%1*")
  s = s:gsub("\\emph[ \t\r\n]*{([^}]*)}", "*%1*")
  s = s:gsub("\\textbf[ \t\r\n]*{([^}]*)}", "**%1**")
  -- layout macros that mean nothing on the web
  s = s:gsub("\\rule[ \t\r\n]*{[^}]*}[ \t\r\n]*{[^}]*}", "")
  s = s:gsub("\\newpage", ""):gsub("\\par%f[%A]", "\n\n"):gsub("\\\\", "\n")
  -- anything left that looks like an unknown macro: drop it, but say so
  s = s:gsub("\\(%a+)", function(m)
    warn("unknown macro \\" .. m .. " (ignored)")
    return ""
  end)
  return trim(s)
end

local function md_blocks(s)
  s = tex_to_md(s)
  if s == "" then return pandoc.List() end
  return pandoc.read(s, MDFMT).blocks
end

local function md_inlines(s)
  local out = pandoc.List()
  for i, b in ipairs(md_blocks(s)) do
    if i > 1 then out:insert(pandoc.Space()) end
    if b.t == "Para" or b.t == "Plain" then out:extend(b.content) end
  end
  return out
end

------------------------------------------------------------------------
-- argument parsing for \begin{recipe} and \ingredient
------------------------------------------------------------------------

local function skip_ws(s, pos) return s:find("[^ \t]", pos) or (#s + 1) end

-- read a balanced [..] or {..} group starting exactly at pos
local function read_group(s, pos, open, close)
  if s:sub(pos, pos) ~= open then return nil end
  local depth = 0
  for i = pos, #s do
    local c = s:sub(i, i)
    if c == open then depth = depth + 1
    elseif c == close then
      depth = depth - 1
      if depth == 0 then return s:sub(pos + 1, i - 1), i + 1 end
    end
  end
  return nil
end

-- \ingredient[qty]{unit}{name}, but tolerant of the variants in the wild:
--   \ingredient{pinch}{salt}            (no qty)
--   \ingredient[to taste]{salt}         (name only)
--   \ingredient[1][can]{coconut milk}   (unit in brackets)
--   \ingredient{Scant cup}{}{walnuts}   (qty/unit/name all in braces)
--   \ingredient [1] {cup} {flour}       (spaces)
local function parse_ingredient(rest)
  local pos, br, gr = 1, {}, {}
  while true do
    pos = skip_ws(rest, pos)
    local g, np = read_group(rest, pos, "[", "]")
    if g and #gr == 0 then
      br[#br + 1] = g; pos = np
    else
      g, np = read_group(rest, pos, "{", "}")
      if g then gr[#gr + 1] = g; pos = np else break end
    end
  end
  local qty, unit, name = "", "", ""
  if #br >= 2 then
    qty, unit, name = br[1], br[2], gr[1] or ""
  elseif #br == 1 then
    qty = br[1]
    if #gr >= 2 then unit, name = gr[1], gr[2] else name = gr[1] or "" end
  else
    if #gr >= 3 then qty, unit, name = gr[1], gr[2], gr[3]
    elseif #gr == 2 then unit, name = gr[1], gr[2]
    else name = gr[1] or "" end
  end
  local trailing = trim(rest:sub(pos))
  if trailing ~= "" then name = name .. " " .. trailing end
  return { qty = trim(qty), unit = trim(unit), name = trim(name) }
end

------------------------------------------------------------------------
-- recipe environment -> pandoc blocks
------------------------------------------------------------------------

local function span(cls, inlines)
  return pandoc.Span(inlines, pandoc.Attr("", { cls }))
end

local function render_ingredient(ing)
  local parts = pandoc.List()
  local function add(cls, text)
    if text ~= "" then
      if #parts > 0 then parts:insert(pandoc.Space()) end
      parts:insert(span(cls, md_inlines(text)))
    end
  end
  add("recipe-qty", ing.qty)
  add("recipe-unit", ing.unit)
  add("recipe-name", ing.name)
  return { pandoc.Plain(parts) }
end

local function div(cls, content)
  return pandoc.Div(content, pandoc.Attr("", { cls }))
end

-- returns a list of blocks, or nil if this is not a recipe block
local function convert_recipe(text)
  text = strip_comments(text)
  local rest = text:match("^[ \t\r\n]*\\begin[ \t\r\n]*{recipe}(.*)$")
  if not rest then return nil end

  -- header: [label]{title}{servings}{time}
  local pos = skip_ws(rest, 1)
  local _, np = read_group(rest, pos, "[", "]")
  if np then pos = np end
  local args = {}
  for k = 1, 3 do
    pos = skip_ws(rest, pos)
    local g, n2 = read_group(rest, pos, "{", "}")
    if not g then break end
    args[k] = trim(g); pos = n2
  end
  local yield, time = args[2] or "", args[3] or ""
  local body = rest:sub(pos):gsub("\\end[ \t\r\n]*{recipe}[ \t\r\n]*$", "")

  -- Walk the body line by line, mirroring cuisine.sty's state machine so the
  -- web steps are numbered exactly like the PDF:
  --   * ingredients pile up in a box; text after them goes in a "method" box
  --   * the pair is flushed as one numbered step at the next \ingredient,
  --     \newstep/\newpage or \freeform, or at \end{recipe}
  --   * \newstep with an empty method still flushes if the recipe has had any
  --     ingredient so far (cuisine prints an empty numbered step then)
  --   * \freeform text is printed unnumbered and leaves the ingredient box alone
  local items = {}
  local ing_box, method, freeform = {}, {}, false
  local ingr_count, step_n = 0, 0
  local para

  local function display()
    if freeform then
      for _, m in ipairs(method) do
        if m.kind == "hr" then items[#items + 1] = { t = "hr" }
        else items[#items + 1] = { t = "note", text = m.text } end
      end
    else
      step_n = step_n + 1
      local texts = {}
      for _, m in ipairs(method) do
        if m.kind == "text" then texts[#texts + 1] = m.text end
      end
      items[#items + 1] = { t = "row", row = { step = step_n, ings = ing_box, texts = texts } }
      ing_box = {}
    end
    method = {}
  end
  local function flush_para()
    if para and trim(para) ~= "" then method[#method + 1] = { kind = "text", text = para } end
    para = nil
  end
  -- \newstep, \newpage and \freeform: finish the current step, then restart
  local function end_method()
    flush_para()
    if #method > 0 or ingr_count > 0 then display() end
    method = {}
  end

  for line in (body .. "\n"):gmatch("(.-)\n") do
    local t = trim(line)
    if t == "" then
      flush_para()
    elseif t:match("^\\ingredient") then
      flush_para()
      if #method > 0 then display() end
      ing_box[#ing_box + 1] = parse_ingredient(t:sub(12))
      ingr_count = ingr_count + 1
      freeform, method = false, {}
    elseif t:match("^\\freeform") then
      end_method()
      freeform = true
      local r = trim(t:sub(10))
      if r:match("^\\rule") then method[#method + 1] = { kind = "hr" }
      elseif r ~= "" then para = r end
    elseif t:match("^\\newstep") or t:match("^\\newpage") then
      end_method()
      freeform = false
      local r = trim(t:sub(9))
      if r ~= "" then para = r end
    elseif t:match("^\\rule") then
      flush_para()
      method[#method + 1] = { kind = "hr" }
    elseif t:match("^\\par%f[%A]") then
      flush_para()
    else
      if para then para = para .. "\n" .. t else para = t end
    end
  end
  flush_para()
  if #method > 0 then display() end

  -- render
  local out = pandoc.List()

  local meta = pandoc.List()
  if yield ~= "" then meta:insert(span("recipe-yield", md_inlines("Yield: " .. yield))) end
  if time ~= "" then meta:insert(span("recipe-time", md_inlines("Time: " .. time))) end
  if #meta > 0 then
    local inl = pandoc.List()
    for i, m in ipairs(meta) do
      if i > 1 then inl:insert(pandoc.Str(" · ")) end
      inl:insert(m)
    end
    out:insert(div("recipe-meta", { pandoc.Plain(inl) }))
  end

  for _, it in ipairs(items) do
    if it.t == "hr" then
      out:insert(pandoc.HorizontalRule())
    elseif it.t == "note" then
      out:insert(div("recipe-note", md_blocks(it.text)))
    else
      local row = it.row
      local cols = pandoc.List()
      local num = row.step and { pandoc.Plain({ pandoc.Str(tostring(row.step)) }) } or {}
      cols:insert(div("recipe-step-num", num))
      local ing_blocks = {}
      if #row.ings > 0 then
        local lis = {}
        for _, ing in ipairs(row.ings) do lis[#lis + 1] = render_ingredient(ing) end
        ing_blocks = { pandoc.BulletList(lis) }
      end
      cols:insert(div("recipe-ings", ing_blocks))
      local txt = pandoc.List()
      for _, tx in ipairs(row.texts) do txt:extend(md_blocks(tx)) end
      cols:insert(div("recipe-text", txt))
      out:insert(div("recipe-row", cols))
    end
  end
  return out
end

------------------------------------------------------------------------
-- Type / Cook tags and the browse pages
------------------------------------------------------------------------

local function scan_tags(block, ch)
  local function add(list, val)
    for _, v in ipairs(list) do if v == val then return end end
    list[#list + 1] = val
  end
  local function look(text)
    for kind, val in text:gmatch("<!%-%-[ \t\r\n]*(%a+)[ \t\r\n]*:[ \t\r\n]*(.-)[ \t\r\n]*%-%->") do
      kind = kind:lower()
      if val ~= "" then
        if kind == "type" then add(ch.types, val)
        elseif kind == "cook" then add(ch.cooks, val) end
      end
    end
  end
  block:walk({
    RawBlock = function(r) if r.format:match("html") then look(r.text) end end,
    RawInline = function(r) if r.format:match("html") then look(r.text) end end,
  })
  if block.t == "RawBlock" and block.format:match("html") then look(block.text) end
end

local function is_recipe_block(b)
  return b.t == "RawBlock" and b.format:match("tex")
      and b.text:match("^[ \t\r\n]*\\begin[ \t\r\n]*{recipe}") ~= nil
end

local function build_index(kind, chapters)
  local groups, keys = {}, {}
  local UNTAGGED = (kind == "type") and "Uncategorized" or "Unknown cook"
  for _, ch in ipairs(chapters) do
    if ch.recipe then
      local list = (kind == "type") and ch.types or ch.cooks
      if #list == 0 then list = { UNTAGGED } end
      for _, key in ipairs(list) do
        if not groups[key] then groups[key] = {}; keys[#keys + 1] = key end
        table.insert(groups[key], ch)
      end
    end
  end
  table.sort(keys, function(a, b)
    if a == UNTAGGED then return false end
    if b == UNTAGGED then return true end
    return a:lower() < b:lower()
  end)
  local out = pandoc.List()
  for _, key in ipairs(keys) do
    out:insert(pandoc.Header(2, key, pandoc.Attr(kind .. "-" .. slug(key), { "unnumbered" })))
    table.sort(groups[key], function(a, b) return a.title:lower() < b.title:lower() end)
    local items = {}
    for _, ch in ipairs(groups[key]) do
      local inl = pandoc.List({ pandoc.Link(ch.title, "#" .. ch.id) })
      local other = (kind == "type") and ch.cooks or ch.types
      if #other > 0 then
        inl:insert(pandoc.Space())
        inl:insert(span("recipe-index-aside", { pandoc.Str("(" .. table.concat(other, ", ") .. ")") }))
      end
      items[#items + 1] = { pandoc.Plain(inl) }
    end
    out:insert(pandoc.BulletList(items))
  end
  return out
end

local function tag_chips(ch)
  local inl = pandoc.List()
  local function add(label, vals, prefix)
    if #vals == 0 then return end
    if #inl > 0 then inl:insert(pandoc.Str("  ")) end
    inl:insert(pandoc.Str(label .. ": "))
    for i, v in ipairs(vals) do
      if i > 1 then inl:insert(pandoc.Str(", ")) end
      inl:insert(pandoc.Link(v, "#" .. prefix .. "-" .. slug(v)))
    end
  end
  add("Type", ch.types, "type")
  add("Cook", ch.cooks, "cook")
  if #inl == 0 then return nil end
  return div("recipe-tags", { pandoc.Plain(inl) })
end

------------------------------------------------------------------------
-- main
------------------------------------------------------------------------

function Pandoc(doc)
  -- pass 1: collect chapters (level-1 headers) with their tags
  local chapters, cur = {}, nil
  for _, b in ipairs(doc.blocks) do
    if b.t == "Header" and b.level == 1 then
      cur = { id = b.identifier, title = stringify(b.content), types = {}, cooks = {} }
      chapters[#chapters + 1] = cur
    elseif cur then
      if is_recipe_block(b) then cur.recipe = true end
      scan_tags(b, cur)
    end
  end

  -- pass 2: rewrite
  local out, ch_idx, ch = pandoc.List(), 0, nil
  for _, b in ipairs(doc.blocks) do
    if b.t == "Header" and b.level == 1 then
      ch_idx = ch_idx + 1; ch = chapters[ch_idx]
      out:insert(b)
    elseif is_recipe_block(b) then
      local blocks = convert_recipe(b.text)
      if blocks then
        out:insert(div("recipe", blocks))
        local chips = ch and tag_chips(ch)
        if chips then out:insert(chips) end
      else
        out:insert(b)
      end
    elseif b.t == "Div" and b.classes:includes("recipe-index") then
      if b.classes:includes("by-type") then out:extend(build_index("type", chapters))
      elseif b.classes:includes("by-cook") then out:extend(build_index("cook", chapters))
      else out:insert(b) end
    else
      out:insert(b)
    end
  end
  doc.blocks = out
  return doc
end
