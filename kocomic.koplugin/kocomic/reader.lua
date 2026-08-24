--[[--
在线阅读器:边下边看,不用等整话下完。

每一屏都是 pager 现拼出来的,所以在线看到的分页和下载下来的 CBZ 完全一致。
下过的图片存在缓存里,翻回去不重下;看完随时可以「存成 CBZ」,一秒打包。
]]

local Api = require("kocomic/api")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local Config = require("kocomic/config")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local ImageUtil = require("kocomic/imageutil")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local Pager = require("kocomic/pager")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local Screen = Device.screen

local ComicReader = InputContainer:extend{
    comic = nil,          -- { name, path_word }
    chapters = nil,       -- 整个分组的章节表
    chapter_index = 1,
    on_chapter_done = nil,-- 关掉时回调,让书架/列表刷新标记
}

-- —————————————— 阅读进度 ——————————————

local function progressKey(comic, chapter)
    return (comic.path_word or "?") .. "/" .. (chapter.uuid or "?")
end

local function loadProgress(comic, chapter)
    local all = Config:get("reading_progress")
    if type(all) ~= "table" then
        return nil
    end
    return all[progressKey(comic, chapter)]
end

local function saveProgress(comic, chapter, cursor, screen_no)
    local all = Config:get("reading_progress")
    if type(all) ~= "table" then
        all = {}
    end
    all[progressKey(comic, chapter)] = cursor and
        { index = cursor.index, y = cursor.y, half = cursor.half, screen = screen_no } or nil
    Config:set("reading_progress", all)
end

-- —————————————— 图片来源 ——————————————

--- 现下现看:要哪张下哪张,存进缓存目录(和下载功能共用,下完能直接打包)
local function makeSource(comic, chapter)
    local pages, err = Api:chapterPages(comic.path_word, chapter.uuid)
    if not pages then
        return nil, err
    end
    local dir = Config:getCacheDir() .. "/" .. comic.path_word .. "/" .. chapter.uuid
    util.makePath(dir)
    local function pathFor(index)
        return string.format("%s/p%04d.img", dir, pages[index].index)
    end
    return {
        count = #pages,
        dir = dir,
        pages = pages,
        isCached = function(index)
            if not pages[index] then
                return true
            end
            return (lfs.attributes(pathFor(index), "size") or 0) > 0
        end,
        getData = function(index)
            if not pages[index] then
                return nil, "没有这一张"
            end
            local path = pathFor(index)
            if (lfs.attributes(path, "size") or 0) == 0 then
                local ok, download_err = Api:downloadImage(pages[index].url, path)
                if not ok then
                    return nil, download_err
                end
            end
            local file = io.open(path, "rb")
            if not file then
                return nil, "读不了缓存文件"
            end
            local data = file:read("*a")
            file:close()
            return data
        end,
    }
end

-- —————————————— 生命周期 ——————————————

--- 打开阅读器。失败返回 nil 和原因。
function ComicReader.open(opts)
    local reader = ComicReader:new(opts)
    if not reader:openChapter(reader.chapter_index) then
        return nil, reader.last_error
    end
    UIManager:show(reader)
    if not Config:get("reader_hint_shown") then
        Config:set("reader_hint_shown", true)
        UIManager:show(InfoMessage:new{
            text = "左右两侧点一下翻页,中间点一下出菜单(切换章节、存成 CBZ 都在里面)。",
            timeout = 4,
        })
    end
    return reader
end

function ComicReader:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    self.screen_no = 1
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
            NextScreen = { { Device.input.group.PgFwd } },
            PrevScreen = { { Device.input.group.PgBack } },
        }
    end
    if Device:isTouchDevice() then
        local range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
        self.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = range } },
            Swipe = { GestureRange:new{ ges = "swipe", range = range } },
        }
    end
end

function ComicReader:currentChapter()
    return self.chapters[self.chapter_index]
end

--- 切到某一话,从第一屏(或者上次读到的地方)开始
function ComicReader:openChapter(index, from_start)
    local chapter = self.chapters[index]
    if not chapter then
        self.last_error = "没有这一话"
        return false
    end
    local message = InfoMessage:new{ text = "正在打开《" .. chapter.name .. "》…" }
    UIManager:show(message)
    UIManager:forceRePaint()
    local source, err = makeSource(self.comic, chapter)
    if not source then
        UIManager:close(message)
        self.last_error = tostring(err)
        return false
    end
    if self.pager then
        self.pager:close()
    end
    self.chapter_index = index
    self.source = source
    self.pager = Pager.new(source, {
        page_w = Screen:getWidth(),
        page_h = Screen:getHeight(),
        mode = Config:get("layout_mode"),
        split_spread = Config:get("split_spread"),
        auto_levels = Config:get("auto_levels"),
        -- 下载的书是 KOReader 渲染时套伽马,在线阅读绕开了它,自己套一遍
        gamma = Config:get("reader_contrast"),
    })
    local ok, mode = pcall(function() return self.pager:start() end)
    -- 正文后面接上本话吐槽(取不到就算了,不耽误看正文)
    if ok and Config:get("append_comments") then
        local Comments = require("kocomic/comments")
        local built_ok, extras = pcall(function()
            return Comments.buildForChapter(self.comic, chapter, {
                width = Screen:getWidth(),
                height = Screen:getHeight(),
            })
        end)
        if built_ok and type(extras) == "table" then
            self.pager:setExtras(extras)
        end
    end
    UIManager:close(message)
    if not ok then
        self.last_error = tostring(mode)
        return false
    end
    self.screen_no = 1
    if not from_start then
        local saved = loadProgress(self.comic, chapter)
        if saved and (saved.index or 0) > 1 then
            self.pager.cursors[1] = { index = saved.index, y = saved.y, half = saved.half }
            self.screen_no = 1
            self.resumed_at = saved.screen
        end
    end
    return self:showScreen(1)
end

-- —————————————— 画面 ——————————————

--- 在页面左下角写一行进度,省得看不出读到哪了
function ComicReader:stampFooter(page)
    local chapter = self:currentChapter()
    local total = self.source.count
    local at = self.pager:sourceIndex(self.screen_no)
    local label
    if self.pager:isExtra(self.screen_no) then
        label = chapter.name .. "  ·  本话吐槽"
    else
        label = string.format("%s  ·  %d/%d", chapter.name, math.min(at, total), total)
    end
    local text = TextWidget:new{
        text = label,
        face = Font:getFace("cfont", 14),
        fgcolor = Blitbuffer.COLOR_GRAY_3,
    }
    local size = text:getSize()
    local x, y = 8, self.dimen.h - size.h - 6
    page:paintRect(x - 4, y - 2, size.w + 8, size.h + 4, Blitbuffer.COLOR_WHITE)
    text:paintTo(page, x, y)
    text:free()
end

function ComicReader:showScreen(n)
    if not self.pager.cursors[n] then
        return false
    end
    -- 这一屏要用的图还没下,先说一声,免得像死机
    local needed = self.pager:sourceIndex(n)
    local message
    if self.source.isCached and not self.source.isCached(needed) then
        message = InfoMessage:new{
            text = string.format("正在下载第 %d/%d 张…", needed, self.source.count),
        }
        UIManager:show(message)
        UIManager:forceRePaint()
    end
    local page, err = self.pager:render(n)
    if message then
        UIManager:close(message)
    end
    if not page then
        self.last_error = tostring(err or "这一屏画不出来")
        UIManager:show(InfoMessage:new{ text = self.last_error })
        return false
    end
    self.screen_no = n
    self:stampFooter(page)
    if self[1] then
        self[1]:free()
    end
    self[1] = ImageWidget:new{ image = page, image_disposable = true }
    UIManager:setDirty(self, function() return "full", self.dimen end)
    self:scheduleNext()
    return true
end

--- 读着这一屏的工夫,把后面两张图先下了
function ComicReader:scheduleNext()
    if self.prefetch_scheduled then
        return
    end
    self.prefetch_scheduled = true
    UIManager:scheduleIn(0.6, function()
        self.prefetch_scheduled = false
        if self.closed or not self.source then
            return
        end
        local from = self.pager:sourceIndex(self.screen_no)
        for index = from, math.min(from + 2, self.source.count) do
            if self.closed then
                return
            end
            if self.source.isCached and not self.source.isCached(index) then
                self.source.getData(index)
                return    -- 一次只下一张,别把界面卡太久
            end
        end
    end)
end

-- —————————————— 翻页 ——————————————

function ComicReader:onNextScreen()
    if self.pager:hasNext(self.screen_no) then
        self:showScreen(self.screen_no + 1)
    else
        self:askNextChapter()
    end
    return true
end

function ComicReader:onPrevScreen()
    if self.screen_no > 1 then
        self:showScreen(self.screen_no - 1)
    else
        UIManager:show(InfoMessage:new{ text = "已经是这一话的开头了", timeout = 1 })
    end
    return true
end

function ComicReader:askNextChapter()
    local next_index = self.chapter_index + 1
    if not self.chapters[next_index] then
        UIManager:show(InfoMessage:new{ text = "这是最后一话了", timeout = 2 })
        return
    end
    local dialog
    dialog = ButtonDialog:new{
        title = "这一话看完了",
        title_align = "center",
        buttons = {
            {{
                text = "看下一话:" .. self.chapters[next_index].name,
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    self:saveCurrentProgress(true)
                    self:openChapter(next_index, true)
                end,
            }},
            {{
                text = "存成 CBZ 收着",
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    self:saveAsCbz()
                end,
            }},
            {{
                text = "退出",
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    self:onClose()
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

-- —————————————— 输入 ——————————————

function ComicReader:onTap(_, ges)
    local x = ges.pos.x
    local width = self.dimen.w
    if x < width * 0.3 then
        return self:onPrevScreen()
    elseif x > width * 0.7 then
        return self:onNextScreen()
    end
    self:showMenu()
    return true
end

function ComicReader:onSwipe(_, ges)
    local direction = ges.direction
    if direction == "west" or direction == "north" then
        return self:onNextScreen()
    elseif direction == "east" or direction == "south" then
        return self:onPrevScreen()
    end
    return true
end

function ComicReader:showMenu()
    local dialog
    local buttons = {}
    local function add(text, callback)
        buttons[#buttons + 1] = {{
            text = text,
            align = "left",
            callback = function()
                UIManager:close(dialog)
                callback()
            end,
        }}
    end
    local mode_names = { auto = "自动", strip = "条漫(重新裁页)", page = "单页(原图)" }
    add(string.format("排版:%s", mode_names[Config:get("layout_mode")] or "自动"),
        function() self:showLayoutMenu() end)
    add("跳到第几张原图…", function() self:showJumpDialog() end)
    add("回到这一话开头", function()
        self.pager.cursors = { { index = 1, y = 0, half = self.pager.cursors[1].half } }
        self:showScreen(1)
    end)
    if self.chapters[self.chapter_index - 1] then
        add("上一话:" .. self.chapters[self.chapter_index - 1].name, function()
            self:saveCurrentProgress(true)
            self:openChapter(self.chapter_index - 1, true)
        end)
    end
    if self.chapters[self.chapter_index + 1] then
        add("下一话:" .. self.chapters[self.chapter_index + 1].name, function()
            self:saveCurrentProgress(true)
            self:openChapter(self.chapter_index + 1, true)
        end)
    end
    add("把这一话存成 CBZ", function() self:saveAsCbz() end)
    add("退出阅读", function() self:onClose() end)
    dialog = ButtonDialog:new{
        title = self.comic.name,
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function ComicReader:showLayoutMenu()
    local dialog
    local function choose(mode)
        return function()
            UIManager:close(dialog)
            Config:set("layout_mode", mode)
            self:openChapter(self.chapter_index, true)
        end
    end
    dialog = ButtonDialog:new{
        title = "这一话怎么排版",
        title_align = "center",
        buttons = {
            {{ text = "自动判断(推荐)", align = "left", callback = choose("auto") }},
            {{ text = "当条漫:拼起来重新裁页", align = "left", callback = choose("strip") }},
            {{ text = "当单页漫画:一张图一页", align = "left", callback = choose("page") }},
        },
    }
    UIManager:show(dialog)
end

function ComicReader:showJumpDialog()
    local dialog
    dialog = InputDialog:new{
        title = "跳到第几张原图",
        input_type = "number",
        input_hint = "1 - " .. self.source.count,
        buttons = {{
            { text = "取消", id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = "跳",
                is_enter_default = true,
                callback = function()
                    local value = tonumber(dialog:getInputText())
                    UIManager:close(dialog)
                    if not value then
                        return
                    end
                    value = math.min(math.max(1, math.floor(value)), self.source.count)
                    self.pager.cursors = { { index = value, y = 0,
                        half = self.pager.mode == "page" and self.pager:viewsFor(value)[1] or nil } }
                    self:showScreen(1)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- —————————————— 存盘与退出 ——————————————

function ComicReader:saveAsCbz()
    local Downloader = require("kocomic/downloader")
    local chapter = self:currentChapter()
    Downloader:run(self.comic, { chapter }, function(result)
        UIManager:show(InfoMessage:new{ text = Downloader.summary(result) })
        self.saved_something = true
    end)
end

function ComicReader:saveCurrentProgress(clear)
    local chapter = self:currentChapter()
    if not chapter then
        return
    end
    if clear then
        saveProgress(self.comic, chapter, nil)
    else
        saveProgress(self.comic, chapter, self.pager.cursors[self.screen_no],
            (self.resumed_at or 0) + self.screen_no)
    end
end

function ComicReader:onClose()
    self:saveCurrentProgress()
    UIManager:close(self)
    return true
end

function ComicReader:onCloseWidget()
    self.closed = true
    if self.pager then
        self.pager:close()
        self.pager = nil
    end
    if self[1] then
        self[1]:free()
        self[1] = nil
    end
    if self.on_chapter_done then
        self.on_chapter_done(self.saved_something)
    end
    return true
end

--- 退出到桌面之类的时候也别丢进度
function ComicReader:onSuspend()
    self:saveCurrentProgress()
end

return ComicReader
