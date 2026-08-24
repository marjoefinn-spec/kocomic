--[[--
只测「接口域名换了怎么办」这一块。

主 scenario 会打不少数据接口,连着跑几次容易被风控(210,按 IP 限一阵子);
这块只用 /api/v3/system/network2 体检,不受影响,可以随时单独跑:

    python test/run_test.py scenario_host.lua
]]

local Config = require("kocomic/config")
local HostFinder = require("kocomic/hostfinder")

local passed = 0
local function check(condition, message)
    if not condition then
        error("测试失败:" .. message, 2)
    end
    passed = passed + 1
    print("  ok  " .. message)
end

print("\n[1] 按规律现编域名")
local dated = HostFinder.datedHosts(os.time({ year = 2026, month = 8, day = 17 }))
check(dated[1] == "api.copy202611.com", "从三个月后往前倒推:" .. dated[1])
check(dated[4] == "api.copy202608.com", "第 4 个是当月:" .. dated[4])
local has_current = false
for _, host in ipairs(dated) do
    if host == "api.copy202601.com" then has_current = true end
end
check(has_current, "现在用的这个在名单里(共 " .. #dated .. " 个)")
local across = HostFinder.datedHosts(os.time({ year = 2026, month = 12, day = 1 }))
check(across[1] == "api.copy202703.com", "跨年进位对:" .. across[1])

print("\n[2] 候选顺序")
Config:set("api_host", "api.copy202601.com")
Config:set("host_history", {})
Config:set("share_hosts", {})
local candidates = HostFinder.candidates()
check(candidates[1] == "api.copy202601.com", "先试现在用的")
check(candidates[2] == "api.mangacopy.com", "再试常驻老域名:" .. candidates[2])
check(#candidates > 30, "一共 " .. #candidates .. " 个候选")

print("\n[3] 探活(真发请求)")
check(HostFinder.probe("api.copy202601.com") == true, "现用域名:通")
check(HostFinder.probe("api.copy199901.com") == false, "瞎编的域名:不通")

print("\n[4] 假装域名挂了,看能不能自己找回来")
Config:set("api_host", "api.copy199901.com")
local recovered, tried_count
HostFinder.search(function(host, tried)
    recovered, tried_count = host, tried
end)
check(recovered ~= nil, "自动找回:" .. tostring(recovered) .. "(试了 " .. tostring(tried_count) .. " 个)")
check(Config:get("api_host") == recovered, "设置里换过去了")
local history = Config:get("host_history")
check(type(history) == "table" and history[1] == recovered, "记进历史,以后能一键切回")
local shares = Config:get("share_hosts")
check(type(shares) == "table" and #shares > 0, "顺手记下官方站点域名:" .. table.concat(shares, ", "))

print("\n[5] 从报错文案里捡域名")
local Api = require("kocomic/api")
Config:set("share_hosts", {})
-- 210 那条报错里带着官网地址,实测 api.copy3000.com 是活的
Api.harvestHosts("請到官網更新最新APP(https://www.copy3000.com/download), 您或您身邊的人曾經下載過破解版本")
local picked = Config:get("share_hosts") or {}
check(picked[1] == "api.copy3000.com", "从 210 文案里捡到:" .. tostring(picked[1]))
check(HostFinder.probe(picked[1]) == true, "捡来的这个真是活的")

Config:set("share_hosts", {})
Api.harvestHosts("登录已过期,请重新登录")
check(#(Config:get("share_hosts") or {}) == 0, "文案里没地址就不乱记")

-- 真发一次必定失败的请求,确认整条链路不炸
local ok_call, err = Api:call(Api:url("/api/v3/member/collect/comics", { limit = 1 }))
check(ok_call == nil, "未登录访问收藏会正常报错:" .. tostring(err))

Config:set("api_host", "api.copy202601.com")
print("\n通过 " .. passed .. " 项检查")
return true
