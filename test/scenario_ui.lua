--[[--
只测界面骨架:菜单能不能开、设置项在不在、点下去会不会炸。

不碰漫画数据接口(comic2 / chapters 这些连着打会被风控 210 限一阵子),
所以随时能跑:

    python test/run_test.py scenario_ui.lua
]]

local Config = require("kocomic/config")

local passed = 0
local function check(condition, message)
    if not condition then
        error("测试失败:" .. message, 2)
    end
    passed = passed + 1
    print("  ok  " .. message)
end

local function findItem(browser, text)
    for i, item in ipairs(browser.item_table) do
        if item.text and item.text:find(text, 1, true) then
            return item, i
        end
    end
end

local function lastShown(kind)
    for i = #TEST.shown, 1, -1 do
        if TEST.shown[i].kind == kind then
            return TEST.shown[i].widget
        end
    end
end

local function buttonTexts(dialog)
    local names = {}
    for _, row in ipairs(dialog.buttons or {}) do
        for _, button in ipairs(row) do
            names[#names + 1] = button.text
        end
    end
    return names
end

local function clickButton(dialog, text)
    for _, row in ipairs(dialog.buttons or {}) do
        for _, button in ipairs(row) do
            if button.text and button.text:find(text, 1, true) then
                button.callback()
                return true
            end
        end
    end
    error("按钮找不到:" .. text .. "(有的是:" .. table.concat(buttonTexts(dialog), " / ") .. ")")
end

print("\n[1] 开插件")
local KoComic = require("main")
local plugin = KoComic:new{ ui = { menu = { registerToMainMenu = function() end } } }
plugin:onShowKoComic()
local browser = plugin.browser
check(browser ~= nil, "浏览器开起来了")
check(#browser.item_table == 8, "首页 8 个入口")

print("\n[2] 设置页整页过一遍")
findItem(browser, "设置").kocomic_callback()
check(browser.state.view == "settings", "进了设置")
local expected = {
    "账号", "接口域名", "自动找可用接口", "图片清晰度", "排版方式", "跨页大图",
    "重裁后的图片质量", "自动色阶", "连原图一起去灰", "画面对比度", "裁页尺寸",
    "话末附上本话吐槽", "最多附多少条", "每本 CBZ 装几话", "下载目录",
    "下载完成后问我", "打包后保留原始图片", "补上阅读设置", "清空图片缓存", "忘掉",
}
for _, name in ipairs(expected) do
    check(findItem(browser, name) ~= nil, "有「" .. name .. "」")
end
check(#browser.item_table == #expected + 1, "一共 " .. #browser.item_table .. " 项(含下载目录那行路径)")

print("\n[3] 域名那一项")
findItem(browser, "接口域名").kocomic_callback()
local host_menu = lastShown("ButtonDialog")
check(host_menu ~= nil, "弹出了域名菜单")
local names = buttonTexts(host_menu)
check(names[1]:find("自动查找") ~= nil, "第一项是自动查找:" .. names[1])
check(names[2]:find("手动输入") ~= nil, "第二项是手动输入")
clickButton(host_menu, "手动输入")
local input = lastShown("InputDialog")
check(input ~= nil, "手动输入能开出输入框")
TEST.next_input = "https://api.example.com/x"
clickButton(input, "保存")
check(Config:get("api_host") == "api.example.com", "粘贴整条 URL 也能存对:" .. Config:get("api_host"))

print("\n[4] 历史域名能一键切回")
Config:set("host_history", { "api.mangacopy.com", "api.copy202601.com" })
browser:renderState(browser.state)
findItem(browser, "接口域名").kocomic_callback()
local menu2 = lastShown("ButtonDialog")
check(#buttonTexts(menu2) >= 4, "菜单里列出了历史:" .. table.concat(buttonTexts(menu2), " / "))
clickButton(menu2, "用回 api.copy202601.com")
check(Config:get("api_host") == "api.copy202601.com", "切回去了")

print("\n[5] 几个开关点一下都不炸")
local toggles = {
    { "自动色阶", "auto_levels", false },
    { "连原图一起去灰", "enhance_originals", true },
    { "话末附上本话吐槽", "append_comments", false },
    { "下载完成后问我", "auto_open", false },
}
for _, item in ipairs(toggles) do
    findItem(browser, item[1]).kocomic_callback()
    check(Config:get(item[2]) == item[3], item[1] .. " 切成了 " .. tostring(item[3]))
end

print("\n[6] 对比度")
findItem(browser, "画面对比度").kocomic_callback()
clickButton(lastShown("ButtonDialog"), "2.0")
check(Config:get("reader_contrast") == 2.0, "改成了 2.0")

print("\n[7] 报错时会提议自动找域名")
browser:reportError("网络不可用(timeout)")
local box = lastShown("ConfirmBox")
check(box ~= nil and box.text:find("自动找一个能用的") ~= nil, "网络类错误 → 提议换域名")
check(box.ok_text == "自动查找", "确认按钮是「自动查找」")
browser:reportError("接口被风控(210):請到官網更新最新APP")
check(lastShown("InfoMessage").text:find("210", 1, true) ~= nil, "风控这种就只提示,不瞎换域名")

print("\n[8] 回首页")
browser:goHome()
check(browser.state.view == "home", "回得去")

print("\n通过 " .. passed .. " 项检查")
return true
