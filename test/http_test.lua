-- Exercise cloudhttp.dll outside Weasel: keep-alive latency, cache, timeout, offline.
-- usage: luarun http_test.lua <directory containing cloudhttp.dll>
package.cpath = arg[1] .. "\\?.dll;" .. package.cpath
local http = require("cloudhttp")

local function url(text)
  return "https://inputtools.google.com/request?text=" .. text ..
      "&itc=zh-t-i0-pinyin&num=5&cp=0&cs=1&ie=utf-8&oe=utf-8"
end

-- os.clock is wall time with the MSVC runtime that rime.dll uses.
local function ms() return math.floor(os.clock() * 1000) end

local function sleep(n)
  local stop = ms() + n
  while ms() < stop do end
end

-- Wait until the worker has finished `n` more requests.
local function wait_requests(n)
  local target, start = http.stats().requests + n, ms()
  while http.stats().requests < target and ms() - start < 20000 do sleep(50) end
  print(("     (worker finished %d requests after %d ms)"):format(n, ms() - start))
end

local failures = 0
local function get(label, u, timeout, want)
  local start = ms()
  local body, err = http.get(u, timeout)
  local took = ms() - start
  local s = http.stats()
  local got = body and "body" or err
  local ok = want == nil or got == want
  if not ok then failures = failures + 1 end
  print(("%-4s %-34s %5d ms  -> %-8s worker=%dms online=%s err=%d %s"):format(
    ok and "ok" or "FAIL", label, took, got, s.last_ms, tostring(s.online), s.last_error,
    body and body:sub(1, 60) or ""))
end

get("cold connection", url("nihao"), 3000, "body")
for _, text in ipairs({ "women", "womenqu", "womenqugong", "womenqugongyuan", "zhongguo",
  "taiwan", "jintian", "tianqi", "henhao", "xiexie" }) do
  get("warm " .. text, url(text), 1000, "body")
end
get("cache hit", url("nihao"), 1000, "body")

get("hanging server times out", "https://10.255.255.1/x", 150, "timeout")
get("then don't wait while offline", url("hao"), 1000, "offline")
wait_requests(2) -- the hanging request fails, then the queued one runs
get("queued request was cached", url("hao"), 1000, "body")
get("back online", url("haode"), 1000, "body")

get("unresolvable host fails fast", "https://nonexistent.invalid/x", 1000, "failed")
get("offline after failure", url("dajia"), 1000, "offline")
wait_requests(1)
get("probe succeeded meanwhile", url("dajia"), 1000, "body")
get("online again", url("dajiahao"), 1000, "body")

local s = http.stats()
print(("requests=%d hits=%d timeouts=%d failures=%d"):format(s.requests, s.hits, s.timeouts, failures))
os.exit(failures == 0 and 0 or 1)
