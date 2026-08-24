--[[--
接口域名换了怎么办:自己去把新的找回来。

拷贝漫画的接口域名是会轮换的,当前这个 `api.copy202601.com` 名字里就带着年月。
实测同时活着的有好几个:api.copy202601.com、api.copy202602.com、
api.mangacopy.com、api.copymanga.fun —— 所以「挨个试一遍」是可行的。

候选来源(按这个顺序试,命中就停):

1. 现在用的那个(先确认是不是真的挂了)
2. 以前用通过的(存在设置里)
3. 上次从 `/api/v3/system/network2` 抓到的官方域名
4. 一串固定的老域名
5. 按 `api.copy{年月}.com` 的规律现编,从下个月往前倒推两年多

体检用 `/api/v3/system/network2`:够小够快,而且它还会顺带告诉我们
官方当前的站点域名,存下来给下次用。
]]

local Config = require("kocomic/config")
local JSON = require("json")
local Trapper = require("ui/trapper")
local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")

local HostFinder = {}

--- 一直有人在用的几个,放在生成的日期域名前面试
HostFinder.KNOWN_HOSTS = {
    "api.mangacopy.com",
    "api.copymanga.fun",
    "api.copy3000.com",
    "api.copymanga.net",
    "api.copymanga.tv",
    "api.copymanga.site",
    "api.copymanga.org",
    "api.copymanga.info",
}

local PROBE_PATH = "/api/v3/system/network2"
local MONTHS_BACK = 26      -- 往前倒推多少个月
local MONTHS_AHEAD = 3      -- 往后多编几个月(域名常常提前注册)

-- —————————————— 候选名单 ——————————————

local function appendUnique(list, seen, host)
    if type(host) ~= "string" then
        return
    end
    host = host:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^https?://", ""):gsub("/.*$", "")
    if host == "" or seen[host] then
        return
    end
    seen[host] = true
    list[#list + 1] = host
end

--- 按 api.copy{年月}.com 的规律现编域名,新的排前面
function HostFinder.datedHosts(now)
    now = now or os.time()
    local today = os.date("*t", now)
    local hosts = {}
    for offset = MONTHS_AHEAD, -MONTHS_BACK, -1 do
        local month = today.month + offset
        local year = today.year + math.floor((month - 1) / 12)
        month = ((month - 1) % 12) + 1
        hosts[#hosts + 1] = string.format("api.copy%04d%02d.com", year, month)
    end
    return hosts
end

--- 完整候选名单
function HostFinder.candidates(now)
    local list, seen = {}, {}
    appendUnique(list, seen, Config:get("api_host"))
    for _, host in ipairs(Config:get("host_history") or {}) do
        appendUnique(list, seen, host)
    end
    for _, host in ipairs(Config:get("share_hosts") or {}) do
        appendUnique(list, seen, host)
    end
    for _, host in ipairs(HostFinder.KNOWN_HOSTS) do
        appendUnique(list, seen, host)
    end
    for _, host in ipairs(HostFinder.datedHosts(now)) do
        appendUnique(list, seen, host)
    end
    return list
end

-- —————————————— 体检 ——————————————

--- 这个域名活着吗?活着的话顺带把它告诉我们的官方域名带回来。
function HostFinder.probe(host, block_timeout, total_timeout)
    local sink = {}
    socketutil:set_timeout(block_timeout or 4, total_timeout or 8)
    local code = socket.skip(1, http.request{
        url = "https://" .. host .. PROBE_PATH,
        headers = {
            ["User-Agent"] = "COPY/3.0.0",
            ["Accept"] = "application/json",
            ["Accept-Encoding"] = "identity",
            ["platform"] = "1",
            ["region"] = "1",
        },
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    if code ~= 200 then
        return false
    end
    local ok, parsed = pcall(JSON.decode, table.concat(sink))
    if not ok or type(parsed) ~= "table" or tonumber(parsed.code) ~= 200 then
        return false
    end
    -- 顺手记下官方站点域名,下次找的时候当线索
    local shares = {}
    local results = type(parsed.results) == "table" and parsed.results or {}
    if type(results.share) == "table" then
        for _, domain in ipairs(results.share) do
            if type(domain) == "string" and domain ~= "" then
                shares[#shares + 1] = "api." .. domain:gsub("^www%.", "")
            end
        end
    end
    return true, shares
end

local function remember(host, shares)
    Config:set("api_host", host)
    local history = Config:get("host_history") or {}
    local kept = { host }
    for _, old in ipairs(history) do
        if old ~= host and #kept < 5 then
            kept[#kept + 1] = old
        end
    end
    Config:set("host_history", kept)
    if shares and #shares > 0 then
        Config:set("share_hosts", shares)
    end
end

-- —————————————— 找 ——————————————

--- 挨个试,找到能用的就换过去。跑在 Trapper 协程里,过程中点屏幕可以中止。
-- on_finished(host, tried, aborted)
function HostFinder.search(on_finished)
    Trapper:wrap(function()
        Trapper:setPausedText("正在找可用的接口域名,要停吗?", "停下", "接着找")
        local hosts = HostFinder.candidates()
        local current = Config:get("api_host")
        local found, shares, tried, aborted
        for index, host in ipairs(hosts) do
            tried = index
            local go_on = Trapper:info(string.format(
                "正在试第 %d/%d 个域名…\n%s", index, #hosts, host), true, index % 3 ~= 0)
            if not go_on then
                aborted = true
                break
            end
            local ok, host_shares = HostFinder.probe(host)
            if ok then
                found, shares = host, host_shares
                break
            end
        end
        Trapper:reset()
        if found then
            remember(found, shares)
            logger.info("KoComic: 接口域名 ->", found, "(试了", tried, "个)")
        end
        if on_finished then
            on_finished(found, tried or 0, aborted, found == current)
        end
    end)
end

return HostFinder
