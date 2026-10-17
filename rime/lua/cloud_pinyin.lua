-- Yunpin (雲拼): Google cloud pinyin for rime-ice on Weasel.
--
-- Puts Google's candidates (inputtools.google.com) in front of the local ones.
-- If Google doesn't answer within cloud_pinyin/timeout_ms, or there is no
-- network, only the local dictionary is used. Candidates are Simplified, and
-- simplifier@traditionalize converts them like every other candidate.
-- With cloud_pinyin/learn, a picked cloud candidate goes into the user
-- dictionary, so it comes up offline too, and so does a word made of several
-- picks that includes one.
--
-- HTTP is done by cloudhttp.dll (next to this file), which keeps the
-- connection warm on a background thread.

local M = {}

-- Segments from rime-ice's recognizer patterns, which aren't pinyin.
local skip_tags = { "punct", "radical_lookup", "unicode", "number", "calculator", "gregorian_to_lunar" }

-- Minimal JSON decoder. null decodes to false so arrays keep their indexes.
local function decode(s)
  local pos = 1
  local escapes = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

  local function fail(what) error(("bad JSON (%s) at %d"):format(what, pos), 0) end
  local function skip() pos = s:find("[^ \t\r\n]", pos) or #s + 1 end

  local function str()
    local parts = {}
    pos = pos + 1
    while true do
      local stop = s:find('["\\]', pos) or fail("unterminated string")
      parts[#parts + 1] = s:sub(pos, stop - 1)
      if s:sub(stop, stop) == '"' then
        pos = stop + 1
        return table.concat(parts)
      end
      local esc = s:sub(stop + 1, stop + 1)
      if esc == "u" then
        local code = tonumber(s:sub(stop + 2, stop + 5), 16) or fail("\\u escape")
        pos = stop + 6
        local low = code >= 0xD800 and code < 0xDC00 and s:match("^\\u(%x%x%x%x)", pos)
        low = low and tonumber(low, 16)
        if low and low >= 0xDC00 and low < 0xE000 then
          code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
          pos = pos + 6
        end
        parts[#parts + 1] = utf8.char(code)
      else
        parts[#parts + 1] = escapes[esc] or esc
        pos = stop + 2
      end
    end
  end

  local value
  local function items(close, item)
    pos = pos + 1
    skip()
    if s:sub(pos, pos) == close then
      pos = pos + 1
      return
    end
    while true do
      item()
      skip()
      local c = s:sub(pos, pos)
      pos = pos + 1
      if c == close then return end
      if c ~= "," then fail("expected , or " .. close) end
    end
  end

  function value()
    skip()
    local c = s:sub(pos, pos)
    if c == "{" then
      local t = {}
      items("}", function()
        skip()
        if s:sub(pos, pos) ~= '"' then fail("expected key") end
        local key = str()
        skip()
        if s:sub(pos, pos) ~= ":" then fail("expected :") end
        pos = pos + 1
        t[key] = value()
      end)
      return t
    elseif c == "[" then
      local t = {}
      items("]", function() t[#t + 1] = value() end)
      return t
    elseif c == '"' then
      return str()
    end
    local num = s:match("^-?%d[%d.eE+-]*", pos)
    if num then
      pos = pos + #num
      return tonumber(num) or fail("number")
    end
    for word, v in pairs({ ["true"] = true, ["false"] = false, ["null"] = false }) do
      if s:sub(pos, pos + #word - 1) == word then
        pos = pos + #word
        return v
      end
    end
    fail("unexpected character")
  end

  return value()
end

local function load_http()
  local dll = rime_api.get_user_data_dir() .. "\\lua\\?.dll"
  if not package.cpath:find(dll, 1, true) then
    package.cpath = dll .. ";" .. package.cpath
  end
  return require("cloudhttp")
end

-- A picked candidate's pinyin as the user dictionary stores it ("ni hao "), or
-- nil. Cloud candidates carry Google's. Dictionary candidates are decoded from
-- their syllables, so abbreviations and corrected typos get the real pinyin.
local function pinyin(env, cand)
  if cand.type == "cloud" then
    return cand.preedit ~= "" and cand.preedit .. " " or nil
  end
  local phrase = cand:to_phrase()
  if phrase and phrase.lang_name == env.memory.lang_name then
    local syllables = env.memory:decode(phrase.code)
    if #syllables > 0 then return table.concat(syllables, " ") .. " " end
  end
end

local function save(env, text, code)
  local entry = DictEntry()
  entry.text = text
  entry.custom_code = code
  env.memory:update_userdict(entry, 1, "")
end

-- Add picked cloud candidates to the user dictionary, and words made of
-- several picks if one of them is a cloud candidate. RIME learns words made of
-- dictionary picks only. A word with a pick that has no pinyin (English, a
-- date) isn't learned. Runs on commit: when the last pick completes the input,
-- the engine commits and clears the composition before select_notifier
-- reaches us.
local function learn(env, ctx)
  local text, code, picks, cloud = "", "", 0, false
  for _, seg in ipairs(ctx.composition:toSegmentation():get_segments()) do
    local cand = (seg.status == "kSelected" or seg.status == "kConfirmed") and seg:get_selected_candidate()
    cand = cand and cand:get_genuine()
    local py = cand and pinyin(env, cand)
    if cand and cand.type == "cloud" and py then
      save(env, cand.text, py)
      cloud = true
    end
    if not py then
      code = nil
    elseif code then
      text, code, picks = text .. cand.text, code .. py, picks + 1
    end
  end
  if code and picks > 1 and cloud then save(env, text, code) end
end

function M.init(env)
  local config = env.engine.schema.config
  local ns = env.name_space:gsub("^%*", "")
  env.endpoint = config:get_string(ns .. "/endpoint") or "https://inputtools.google.com/request"
  env.timeout = config:get_int(ns .. "/timeout_ms") or 200
  env.count = config:get_int(ns .. "/count") or 5
  env.comment = config:get_string(ns .. "/comment") or ""

  local ok, http = pcall(load_http)
  if not ok then
    log.error("cloud_pinyin: can't load cloudhttp.dll: " .. tostring(http))
    return
  end
  env.http = http

  if config:get_bool(ns .. "/learn") then
    env.memory = Memory(env.engine, env.engine.schema)
    env.on_commit = env.engine.context.commit_notifier:connect(function(ctx) learn(env, ctx) end)
  end
end

function M.func(input, seg, env)
  if not env.http or not input:find("^[a-z][a-z']*$") or not seg:has_tag("abc") then return end
  for _, tag in ipairs(skip_tags) do
    if seg:has_tag(tag) then return end
  end

  local url = ("%s?text=%s&itc=zh-t-i0-pinyin&num=%d&cp=0&cs=1&ie=utf-8&oe=utf-8")
      :format(env.endpoint, input:gsub("'", "%%27"), env.count)
  local body = env.http.get(url, env.timeout)
  if not body then return end

  local ok, reply = pcall(decode, body)
  local result = ok and type(reply) == "table" and reply[1] == "SUCCESS"
      and type(reply[2]) == "table" and reply[2][1]
  if type(result) ~= "table" or type(result[2]) ~= "table" then return end
  local info = type(result[4]) == "table" and result[4] or {}
  local lengths = type(info.matched_length) == "table" and info.matched_length or {}
  local annotations = type(info.annotation) == "table" and info.annotation or {}

  for i, text in ipairs(result[2]) do
    local length = tonumber(lengths[i]) or #input
    -- Latin-only candidates (the raw input, "A") aren't useful here.
    if type(text) == "string" and text:find("[\128-\255]") and length > 0 and length <= #input then
      local cand = Candidate("cloud", seg.start, seg.start + length, text, env.comment)
      -- Ahead of local candidates covering the same input.
      cand.quality = 100
      local annotation = annotations[i]
      if type(annotation) == "string" and annotation:find("^[a-z]+[a-z ]*$") then
        cand.preedit = annotation
      end
      yield(cand)
    end
  end
end

function M.fini(env)
  if env.on_commit then env.on_commit:disconnect() end
  env.memory = nil
end

-- Ordering. librime merges translators by comparing each one only with the
-- next in the list, so rime_ice.custom.yaml puts this translator right before
-- script_translator, where a cloud candidate goes ahead of the dictionary's
-- covering the same input. That also puts it ahead of what rime-ice ranks
-- above the dictionary (dates for rq, English words, custom phrases), so this
-- filter, first in the chain, holds each cloud candidate back until the next
-- dictionary candidate. Table translators' completions count as dictionary
-- too; they rank low anyway.
local dictionary_types = { phrase = true, user_phrase = true, sentence = true, completion = true }

M.filter = {}

function M.filter.func(input)
  local held = {}
  for cand in input:iter() do
    if cand.type == "cloud" then
      held[#held + 1] = cand
    else
      if dictionary_types[cand.type] then
        for _, c in ipairs(held) do yield(c) end
        held = {}
      end
      yield(cand)
    end
  end
  for _, c in ipairs(held) do yield(c) end
end

return M
