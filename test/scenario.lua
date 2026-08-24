--[[--
冒烟测试:走一遍用户的路,重点验排版。

拷贝漫画的图分三种货色,实测都拿真数据跑过:
  · 真条漫    我獨自升級      640x500 一串,接缝处画面连着 → 拼起来按屏幕重裁
  · 跨页扫描  進擊的學校      1477x1125 这种横的,一张两页  → 从中间劈开成两页
  · 单页漫画  ...獻上爆炎!   899x1296 规规矩矩一页一张   → 原图直接进包
最后还要检查生成的 CBZ 带上了阅读设置(整页显示),不然 KOReader 默认的
「内容-宽度」会把每页撑到溢出,再从画面中间切成两屏 —— 那就是用户看到的乱切。
]]

local Api = require("kocomic/api")
local Config = require("kocomic/config")
local Downloader = require("kocomic/downloader")
local Pager = require("kocomic/pager")

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

local function chapterItems(browser)
    local list = {}
    for _, item in ipairs(browser.item_table) do
        if item.kocomic_hold_callback then
            list[#list + 1] = item
        end
    end
    return list
end

local function lastShown(kind)
    for i = #TEST.shown, 1, -1 do
        if TEST.shown[i].kind == kind then
            return TEST.shown[i].widget
        end
    end
end

local function clickButton(dialog, text)
    for _, row in ipairs(dialog.buttons) do
        for _, button in ipairs(row) do
            if button.text and button.text:find(text, 1, true) then
                button.callback()
                return true
            end
        end
    end
    error("按钮找不到:" .. text)
end

--- 测试时每话只取前几张图,不然一话 90 张要下半天
local real_chapter_pages = Api.chapterPages
local function limitPages(limit)
    Api.chapterPages = function(self, path_word, uuid)
        local pages, err = real_chapter_pages(self, path_word, uuid)
        if not pages then return nil, err end
        local few = {}
        for i = 1, math.min(limit, #pages) do few[i] = pages[i] end
        return few
    end
end

local function openComic(keyword)
    local items, err = Api:search(keyword, 0, 3)
    assert(items and items[1], "搜不到 " .. keyword .. ":" .. tostring(err))
    local info, info_err = Api:comicInfo(items[1].path_word)
    if not info then
        -- 这套测试连着跑几遍会踩到风控:拷贝漫画按 IP 限 comic2/chapters 一小时左右
        if tostring(info_err):find("210", 1, true) then
            error("接口被风控(210)了 —— 连着跑太多次会按 IP 限一小时左右。\n"
                .. "        等一会儿再跑;这期间可以先跑 scenario_ui.lua 和 scenario_host.lua,"
                .. "那两套不碰这些接口。", 0)
        end
        error("读不到《" .. keyword .. "》:" .. tostring(info_err), 0)
    end
    local chapters = assert(Api:chapters(info.path_word, info.groups[1].path_word))
    return info, chapters
end

local function pagerFor(info, chapter)
    local pages = assert(Api:chapterPages(info.path_word, chapter.uuid))
    local source = Downloader.makeSource(info, chapter, pages)
    return Pager.new(source, { page_w = 1264, page_h = 1680, mode = "auto" }), source
end

-- —————————————— 1. 启动 ——————————————

print("\n[1] 加载插件")
local KoComic = require("main")
local plugin = KoComic:new{ ui = { menu = { registerToMainMenu = function() end } } }
plugin:onShowKoComic()
local browser = plugin.browser
check(browser ~= nil, "插件能打开浏览器")
check(#browser.item_table == 8, "首页有 8 个入口")
limitPages(8)

-- —————————————— 2. 判型三连 ——————————————

print("\n[2] 判型:真条漫")
local strip_info, strip_chapters = openComic("我独自升级")
local strip_pager, strip_source = pagerFor(strip_info, strip_chapters[1])
local dim = strip_pager:getDim(1)
print(string.format("      《%s》%s:碎图 %dx%d", strip_info.name, strip_chapters[1].name, dim.w, dim.h))
check(strip_pager:start() == "strip", "判成条漫(接缝连着)")

print("\n[3] 判型:跨页扫描")
local spread_info, spread_chapters = openComic("进击的学校")
local spread_pager = pagerFor(spread_info, spread_chapters[1])
local spread_dim = spread_pager:getDim(5)
print(string.format("      《%s》:第 5 张 %dx%d(横的,一张两页)",
    spread_info.name, spread_dim.w, spread_dim.h))
check(spread_pager:start() == "page", "判成单页漫画(接缝对不上,是分开扫的)")
check(spread_pager:viewsFor(5)[1] == "right", "横图会从中间劈开,右半页先看")

print("\n[4] 判型:规规矩矩的单页漫画")
local plain_info, plain_chapters = openComic("为这个美好的世界献上爆炎")
local plain_pager = pagerFor(plain_info, plain_chapters[1])
local plain_dim = plain_pager:getDim(1)
print(string.format("      《%s》:%dx%d(比例 %.2f)",
    plain_info.name, plain_dim.w, plain_dim.h, plain_dim.h / plain_dim.w))
check(plain_pager:start() == "page", "判成单页漫画")
check(plain_pager:viewsFor(3)[1] == false, "不是横图,不拆")
plain_pager:close()

-- —————————————— 4b. 自动色阶 ——————————————

print("\n[4b] 自动色阶(去灰)")
local Levels = require("kocomic/levels")
local ImageUtil = require("kocomic/imageutil")

-- 先用假直方图验算法本身:一张挤在 40~200 之间的「灰图」
local flat = {}
for i = 1, 256 do flat[i] = 0 end
for value = 40, 200 do flat[value + 1] = 1000 end
local lut, black, white = Levels.computeLut(flat)
check(lut ~= nil, string.format("认出黑点 %d、白点 %d", black, white))
check(lut[black + 1] == 0, "黑点被拉到 0")
check(lut[white + 1] == 255, "白点被拉到 255")
check(lut[121] > 120, "中间调整体变亮一点(" .. lut[121] .. ")")

-- 已经拉满的图不该再动
local full = {}
for i = 1, 256 do full[i] = 0 end
full[1], full[256] = 5000, 5000
check(Levels.computeLut(full) == nil, "本来就够黑够白的图不动它")

-- 几乎全白的页(只有一点点内容)不该被硬压黑
local blank = {}
for i = 1, 256 do blank[i] = 0 end
blank[251] = 100000
check(Levels.computeLut(blank) == nil, "纯色页不硬拉")

-- 作者故意画暗的页(全黑跨页/夜景)也不该被硬提亮
local dark = {}
for i = 1, 256 do dark[i] = 0 end
for value = 0, 40 do dark[value + 1] = 1000 end
check(Levels.computeLut(dark) == nil, "本来就暗的页不硬提亮")

-- 纯伽马表(在线阅读器用它对齐 KOReader 渲染时的对比度)
local gamma_lut = Levels.gammaLut(1.5)
check(gamma_lut ~= nil and gamma_lut[1] == 0 and gamma_lut[256] == 255, "伽马表两端不动")
check(gamma_lut[129] < 128, "中间调压暗了:128 → " .. gamma_lut[129])
check(Levels.gammaLut(1) == nil, "伽马 1 就是不处理")

-- 再拿真图走一遍完整链路
local sample_bb = assert(ImageUtil.decode(strip_source.getData(2)))
local before = ImageUtil.histogram(sample_bb)
local real_lut = Levels.computeLut(before)
if real_lut then
    ImageUtil.applyLut(sample_bb, real_lut)
    local after = ImageUtil.histogram(sample_bb)
    local function extremes(histogram)
        local low, high = 255, 0
        for i = 1, 256 do
            if (histogram[i] or 0) > 0 then
                low = math.min(low, i - 1)
                high = math.max(high, i - 1)
            end
        end
        return low, high
    end
    local low_before, high_before = extremes(before)
    local low_after, high_after = extremes(after)
    print(string.format("      真图:%d~%d → %d~%d", low_before, high_before, low_after, high_after))
    check(low_after <= low_before and high_after >= high_before, "真图的黑白点被拉开了")
else
    print("      这张真图本来就够黑够白,跳过")
    passed = passed + 1
end
ImageUtil.free(sample_bb)

-- —————————————— 4c. 本话吐槽 ——————————————

print("\n[4c] 话末附吐槽")
local Comments = require("kocomic/comments")
local roasts, roast_err = Api:chapterComments(strip_chapters[1].uuid, 30)
check(roasts ~= nil, "取到了吐槽 " .. tostring(roast_err or ""))
check(#roasts > 0, "《" .. strip_info.name .. "》" .. strip_chapters[1].name
    .. " 有 " .. #roasts .. " 条")
print("      最新一条:" .. roasts[1].user .. " | " .. roasts[1].time .. " | "
    .. roasts[1].text:sub(1, 40))
check(roasts[1].text ~= "" and roasts[1].user ~= "", "字段解析对了")

local comment_pages = Comments.buildPages(roasts, {
    width = 1264, height = 1680,
    title = "《" .. strip_info.name .. "》" .. strip_chapters[1].name .. " · 吐槽",
})
check(comment_pages ~= nil and #comment_pages > 0,
    #roasts .. " 条排成了 " .. #comment_pages .. " 页")
local rendered = comment_pages[1]()
check(rendered:getWidth() == 1264 and rendered:getHeight() == 1680, "吐槽页也是一屏大")
ImageUtil.free(rendered)
comment_pages.free()

check(Comments.buildPages({}, { width = 1264, height = 1680 }) == nil, "没有吐槽就不加页")

-- —————————————— 5. 条漫重裁 ——————————————

print("\n[5] 条漫重新裁页")
local screens = 0
strip_pager:forEachPage(function(page, n)
    screens = n
    check(page:getWidth() == 1264 and page:getHeight() == 1680,
        string.format("第 %d 屏正好一屏(%dx%d)", n, page:getWidth(), page:getHeight()))
    return n < 3
end)
check(screens >= 2, strip_source.count .. " 张碎图拼出了 " .. screens .. " 屏")
strip_pager:close()

-- —————————————— 6. 在线阅读 ——————————————

print("\n[6] 在线阅读器")
local ComicReader = require("kocomic/reader")
local reader, reader_err = ComicReader.open{
    comic = strip_info,
    chapters = strip_chapters,
    chapter_index = 1,
}
check(reader ~= nil, "阅读器开起来了 " .. tostring(reader_err or ""))
check(reader[1] ~= nil, "第一屏画出来了")
check(reader.pager.mode == "strip", "阅读器判型和下载一致")
reader:onNextScreen()
check(reader.screen_no == 2, "能往后翻")
reader:onTap(nil, { pos = { x = 200, y = 800 } })
check(reader.screen_no == 1, "点左边回上一屏")
reader:onSwipe(nil, { direction = "west" })
check(reader.screen_no == 2, "左划翻下一屏")
reader:onClose()
reader:onCloseWidget()
check(Config:get("reading_progress") ~= nil, "退出时记住了读到哪")

-- —————————————— 7. 下载条漫 ——————————————

print("\n[7] 下载条漫这一话")
browser:openComic({ path_word = strip_info.path_word })
check(browser.state.view == "comic", "详情页打开了:" .. browser.state.info.name)
chapterItems(browser)[1].kocomic_callback()
clickButton(lastShown("ButtonDialog"), "下载这一话")
local confirm = lastShown("ConfirmBox")
check(confirm ~= nil, "下载完成")
print("      " .. confirm.text:gsub("\n", " | "))
check(confirm.text:find("条漫", 1, true) ~= nil, "结果里说明按条漫裁的")
check(confirm.text:find("吐槽", 1, true) ~= nil, "结果里说明附了吐槽")

print("\n[8] 生成的书带上了阅读设置")
local settings_written = 0
for path, data in pairs(TEST_DOCSETTINGS) do
    settings_written = settings_written + 1
    check(data.zoom_mode == "page", "整页显示(不会再被撑到溢出后乱切):" .. path:match("([^/]+)$"))
    check(data.kopt_page_scroll == 0, "一页一翻,不用滚动模式")
    check(data.kopt_contrast == 1.5, "对比度写的是 1.5(KOReader 默认 1.0 那格偏灰)")
end
check(settings_written > 0, "写了 " .. settings_written .. " 份阅读设置")

-- —————————————— 8b. 账号阅读进度 ——————————————

print("\n[8b] 账号阅读进度的解析")
-- 收藏列表和 /query 接口的字段名不一样,各家客户端见过的写法都得认
check(Api.parseBrowse({ last_browse = { last_browse_id = "abc", last_browse_name = "第12话" } })
    .chapter_name == "第12话", "认得收藏列表里的 last_browse")
check(Api.parseBrowse({ browse = { chapter_id = "xyz", chapter_name = "第7话" } })
    .chapter_id == "xyz", "认得 /query 里的 browse.chapter_id")
check(Api.parseBrowse({ chapter_uuid = "u1", name = "序章" }).chapter_name == "序章",
    "认得 chapter_uuid/name 这种写法")
check(Api.parseBrowse({ browse = nil, collect = nil }) == nil, "没读过就是 nil")
check(Api.parseBrowse(nil) == nil, "给 nil 也不炸")

local fake_favorite = {
    last_browse = { last_browse_id = "ch-9", last_browse_name = "第09话" },
    comic = { name = "测试作品", path_word = "ceshi", last_chapter_name = "第20话",
              author = { { name = "某人" } } },
}
local shaped = Api.toComic(fake_favorite)
check(shaped.browse_name == "第09话" and shaped.latest_name == "第20话",
    "收藏夹条目里带上了「读到第09话 / 最新第20话」")

local status = Api:comicStatus(strip_info.path_word)
check(status ~= nil, "没登录时 /query 也能正常返回(collect/browse 都是空)")
check(status.collected == false and status.browse_name == nil, "没登录就是没收藏、没进度")

-- —————————————— 9. 单页漫画整条流程 ——————————————

print("\n[9] 下载单页漫画(应保留原图)")
browser:openComic({ path_word = plain_info.path_word })
check(browser.state.view == "comic", "详情页:" .. browser.state.info.name)
chapterItems(browser)[1].kocomic_callback()
clickButton(lastShown("ButtonDialog"), "下载这一话")
local plain_confirm = lastShown("ConfirmBox")
check(plain_confirm ~= nil, "下载完成")
print("      " .. plain_confirm.text:gsub("\n", " | "))
check(plain_confirm.text:find("原图", 1, true) ~= nil, "结果里说明保留原图")

-- —————————————— 10. 设置 ——————————————

print("\n[10] 设置页")
browser:goHome()
findItem(browser, "设置").kocomic_callback()
check(browser.state.view == "settings", "进入了设置")
check(findItem(browser, "排版方式").mandatory == "自动判断", "排版方式默认自动")
check(findItem(browser, "裁页尺寸").mandatory == "1264 × 1680", "裁页尺寸跟着屏幕")
local spread_item = findItem(browser, "跨页大图")
check(spread_item.mandatory:find("右→左") ~= nil, "跨页默认右→左")
spread_item.kocomic_callback()
check(Config:get("split_spread") == "ltr", "点一下能切换")

-- 接口域名自动查找单独测(scenario_host.lua,那块只用 network2,不会踩风控)

print("\n[11] 给老书补写阅读设置")
local fix_item = findItem(browser, "补上阅读设置")
check(fix_item ~= nil, "设置里有「补上阅读设置」")
fix_item.kocomic_callback()
lastShown("ConfirmBox").ok_callback()
check(lastShown("InfoMessage").text:find("整页显示", 1, true) ~= nil,
    "批量补写:" .. lastShown("InfoMessage").text)

print("\n[12] 书架")
browser:goHome()
findItem(browser, "我的书架").kocomic_callback()
check(#browser.item_table >= 2, "书架里有 " .. #browser.item_table .. " 部漫画")

print("\n通过 " .. passed .. " 项检查")
return true
