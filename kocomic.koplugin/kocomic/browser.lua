--[[--
KoComic 的界面:一个 Menu,靠 self.paths 这条栈在「首页 → 列表 → 漫画 → 章节」之间来回走。

原版 kComics 是自己往 framebuffer 上画按钮的,这里全部换成 KOReader 的部件,
翻页、长按、搜索框、路径选择这些就都白捡了。
]]

local Api = require("kocomic/api")
local ButtonDialog = require("ui/widget/buttondialog")
local Config = require("kocomic/config")
local ConfirmBox = require("ui/widget/confirmbox")
local Downloader = require("kocomic/downloader")
local ImageViewer = require("ui/widget/imageviewer")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local PathChooser = require("ui/widget/pathchooser")
local SpinWidget = require("ui/widget/spinwidget")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local VERSION = "1.2"

-- —————————————— 通用小工具 ——————————————

local function notify(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

--- 转菊花 → 干活 → 关菊花。任务是同步的,期间界面会卡住,这在 KOReader 里很常见。
local function loading(text, task)
    local message = InfoMessage:new{ text = text or "正在加载…" }
    UIManager:show(message)
    UIManager:forceRePaint()
    local ok, result, extra = pcall(task)
    UIManager:close(message)
    UIManager:forceRePaint()
    if not ok then
        return nil, tostring(result)
    end
    return result, extra
end

local function humanSize(bytes)
    if not bytes then return "" end
    if bytes >= 1024 * 1024 then
        return string.format("%.1f MB", bytes / 1024 / 1024)
    end
    return string.format("%d KB", math.max(1, math.floor(bytes / 1024)))
end

-- —————————————— 部件 ——————————————

local Browser = Menu:extend{
    title = "看漫画",
    is_popout = false,
    is_borderless = true,
    title_bar_fm_style = true,
    title_shrink_font_to_fit = true,
}

function Browser:init()
    self.title = "看漫画"
    self.item_table = self:homeItems()
    self.title_bar_left_icon = "appbar.menu"
    self.onLeftButtonTap = function()
        self:showActionMenu()
    end
    Menu.init(self)
    self.state = { view = "home", title = "看漫画", subtitle = "" }
end

-- —————————————— 视图切换 ——————————————

function Browser:buildItems(state)
    if state.view == "list" then
        return self:listItems(state)
    elseif state.view == "comic" then
        return self:comicItems(state)
    elseif state.view == "library" then
        return self:libraryItems(state)
    elseif state.view == "settings" then
        return self:settingsItems(state)
    end
    return self:homeItems()
end

function Browser:renderState(state, item_number)
    self.state = state
    local items = self:buildItems(state)
    self:switchItemTable(state.title, items, item_number, nil, state.subtitle or "")
end

function Browser:pushState(state)
    table.insert(self.paths, state)
    self:renderState(state)
end

function Browser:goHome()
    self.paths = {}
    self:renderState({ view = "home", title = "看漫画", subtitle = "" })
end

function Browser:onReturn()
    table.remove(self.paths)
    local previous = self.paths[#self.paths]
    if previous then
        self:renderState(previous, previous.select_number)
    else
        self:goHome()
    end
    return true
end

function Browser:onHoldReturn()
    self:goHome()
    return true
end

-- 覆盖掉默认实现:默认的 onMenuSelect 选完就会把整个 Menu 关掉
function Browser:onMenuSelect(item)
    if item.kocomic_callback then
        item.kocomic_callback()
    end
    return true
end

function Browser:onMenuHold(item)
    if item.kocomic_hold_callback then
        item.kocomic_hold_callback()
    end
    return true
end

function Browser:requireNetwork(callback)
    NetworkMgr:runWhenOnline(callback)
end

--- 报错。要是像域名挂了(拷贝漫画的接口域名隔段时间就换),顺手问要不要自动找一个。
-- @param retry 换到新域名之后要重试的动作
function Browser:reportError(message, retry)
    message = tostring(message or "出错了")
    if message:find("网络不可用", 1, true) or message:find("请求失败", 1, true) then
        UIManager:show(ConfirmBox:new{
            text = "连不上接口:\n" .. Config:get("api_host")
                .. "\n\n拷贝漫画的域名隔段时间就换一个,现在自动找一个能用的吗?",
            ok_text = "自动查找",
            cancel_text = "先算了",
            ok_callback = function()
                self:findHost(retry)
            end,
        })
    else
        notify(message)
    end
end

--- 挨个试候选域名,找到能用的就换过去
function Browser:findHost(after)
    local HostFinder = require("kocomic/hostfinder")
    self:requireNetwork(function()
        HostFinder.search(function(host, tried, aborted, unchanged)
            UIManager:nextTick(function()
                if host and unchanged then
                    notify("现在这个域名是通的:" .. host .. "\n那问题多半在别处(网络或风控)")
                elseif host then
                    notify(string.format("已切换到 %s\n(试了 %d 个)", host, tried))
                    if after then
                        after()
                    end
                elseif aborted then
                    notify("已停下,域名没换")
                else
                    notify(string.format("试了 %d 个域名都不通。\n可以去网页版看看最新域名,再手动填。", tried))
                end
                if self.state and self.state.view == "settings" then
                    self:renderState(self.state)
                end
            end)
        end)
    end)
end

-- —————————————— 首页 ——————————————

function Browser:homeItems()
    local self_ref = self
    local account = Config:isLoggedIn() and (Config:get("username") ~= "" and Config:get("username") or "已登录") or "未登录"
    return {
        {
            text = "搜索漫画",
            kocomic_callback = function() self_ref:showSearchDialog() end,
        },
        {
            text = "最近更新",
            kocomic_callback = function()
                self_ref:openList("最近更新", function(offset)
                    return Api:comics("-datetime_updated", offset)
                end)
            end,
        },
        {
            text = "人气推荐",
            kocomic_callback = function()
                self_ref:openList("人气推荐", function(offset)
                    return Api:comics("-popular", offset)
                end)
            end,
        },
        {
            text = "排行榜",
            mandatory = "日 / 周 / 月 / 总",
            kocomic_callback = function() self_ref:showRankDialog() end,
        },
        {
            text = "我的收藏",
            mandatory = account,
            kocomic_callback = function() self_ref:openFavorites() end,
        },
        {
            text = "我的书架",
            mandatory = "已下载",
            kocomic_callback = function()
                self_ref:pushState({
                    view = "library",
                    title = "我的书架",
                    subtitle = Config:getDownloadDir(),
                    dir = Config:getDownloadDir(),
                })
            end,
        },
        {
            text = "设置",
            kocomic_callback = function()
                self_ref:pushState({ view = "settings", title = "设置", subtitle = "" })
            end,
        },
        {
            text = "关于 KoComic",
            kocomic_callback = function() self_ref:showAbout() end,
        },
    }
end

function Browser:showAbout()
    UIManager:show(TextViewer:new{
        title = "关于 KoComic",
        text = table.concat({
            "KoComic " .. VERSION,
            "",
            "在 KOReader 里逛拷贝漫画:搜索、收藏、下载,",
            "下载的章节会打包成 CBZ,直接用 KOReader 自己的阅读器看。",
            "",
            "移植自 kComics(lxdklp,GPL-3.0)",
            "https://github.com/lxdklp/kComics",
            "",
            "漫画数据来自拷贝漫画,本插件不提供任何内容,",
            "接口域名随时可能变,变了就去设置里改。",
            "",
            "当前接口:" .. Config:get("api_host"),
            "下载目录:" .. Config:getDownloadDir(),
        }, "\n"),
    })
end

-- —————————————— 搜索与列表 ——————————————

function Browser:showSearchDialog()
    local dialog
    dialog = InputDialog:new{
        title = "搜索漫画",
        input = Config:get("last_search") or "",
        input_hint = "作品名 / 作者",
        buttons = {{
            {
                text = "取消",
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = "搜索",
                is_enter_default = true,
                callback = function()
                    local keyword = dialog:getInputText()
                    UIManager:close(dialog)
                    if keyword and keyword ~= "" then
                        Config:set("last_search", keyword)
                        self:openList("搜索:" .. keyword, function(offset)
                            return Api:search(keyword, offset)
                        end)
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Browser:showRankDialog()
    local dialog
    local ranks = {
        { "日榜", "day" },
        { "周榜", "week" },
        { "月榜", "month" },
        { "总榜", "total" },
    }
    local buttons = {}
    for _, rank in ipairs(ranks) do
        buttons[#buttons + 1] = {{
            text = rank[1],
            align = "left",
            callback = function()
                UIManager:close(dialog)
                self:openList("排行榜 · " .. rank[1], function(offset)
                    return Api:ranks(rank[2], offset)
                end)
            end,
        }}
    end
    dialog = ButtonDialog:new{ title = "看哪个榜?", title_align = "center", buttons = buttons }
    UIManager:show(dialog)
end

--- fetch(offset) 要返回 items, total
function Browser:openList(title, fetch)
    self:requireNetwork(function()
        local items, total = loading("正在加载…", function() return fetch(0) end)
        if not items then
            self:reportError(total, function() self:openList(title, fetch) end)
            return
        end
        if #items == 0 then
            notify("一部也没找到")
            return
        end
        self:pushState({
            view = "list",
            title = title,
            subtitle = string.format("共 %d 部", total or #items),
            items = items,
            total = total or #items,
            fetch = fetch,
        })
    end)
end

function Browser:openFavorites()
    if not Config:isLoggedIn() then
        UIManager:show(ConfirmBox:new{
            text = "看收藏要先登录拷贝漫画账号,现在登录吗?",
            ok_text = "去登录",
            ok_callback = function() self:showLoginDialog() end,
        })
        return
    end
    self:openList("我的收藏", function(offset)
        return Api:favorites(offset)
    end)
end

function Browser:listItems(state)
    local items = {}
    for i, comic in ipairs(state.items) do
        -- 收藏夹里显示账号那边的阅读进度比显示作者有用
        local note = comic.author ~= "" and comic.author or nil
        if comic.browse_name then
            note = "读到 " .. comic.browse_name
        elseif comic.latest_name then
            note = "最新 " .. comic.latest_name
        end
        items[#items + 1] = {
            text = comic.name,
            mandatory = note,
            kocomic_callback = function()
                state.select_number = i
                self:openComic(comic)
            end,
        }
    end
    if #state.items < (state.total or 0) then
        items[#items + 1] = {
            text = string.format("加载更多(%d / %d)", #state.items, state.total),
            kocomic_callback = function() self:loadMore(state) end,
        }
    end
    return items
end

function Browser:loadMore(state)
    self:requireNetwork(function()
        local anchor = #state.items
        local items, total = loading("正在加载…", function() return state.fetch(anchor) end)
        if not items then
            notify("加载失败:" .. tostring(total))
            return
        end
        if #items == 0 then
            state.total = anchor
        else
            for _, comic in ipairs(items) do
                state.items[#state.items + 1] = comic
            end
            state.total = total or state.total
        end
        state.subtitle = string.format("共 %d 部", state.total)
        self:renderState(state, anchor)
    end)
end

-- —————————————— 漫画详情 ——————————————

function Browser:openComic(comic)
    self:requireNetwork(function()
        local info, err = loading("正在读取作品信息…", function()
            return Api:comicInfo(comic.path_word)
        end)
        if not info then
            self:reportError(err, function() self:openComic(comic) end)
            return
        end
        local group = info.groups[1]
        local chapters, chapter_err = loading("正在读取章节列表…", function()
            return Api:chapters(info.path_word, group.path_word)
        end)
        if not chapters then
            notify("读取章节失败:" .. tostring(chapter_err))
            return
        end
        local state = self:makeComicState(info, 1, chapters)
        if Config:isLoggedIn() then
            local status = loading("正在读取阅读进度…", function()
                return Api:comicStatus(info.path_word)
            end)
            if status and (status.browse_name or status.browse_id) then
                state.status = status
                state.subtitle = state.subtitle .. " · 读到 " .. (status.browse_name or "?")
            end
        end
        self:pushState(state)
    end)
end

function Browser:makeComicState(info, group_index, chapters)
    local group = info.groups[group_index]
    local parts = {}
    if info.authors ~= "" then parts[#parts + 1] = info.authors end
    if info.status ~= "" then parts[#parts + 1] = info.status end
    parts[#parts + 1] = string.format("%d 话", #chapters)
    if #info.groups > 1 then parts[#parts + 1] = group.name end
    return {
        view = "comic",
        title = info.name,
        subtitle = table.concat(parts, " · "),
        info = info,
        group_index = group_index,
        chapters = chapters,
        selection = nil,   -- 多选模式下是 { [uuid] = true }
        reversed = false,
    }
end

local function orderedChapters(state)
    if not state.reversed then
        return state.chapters
    end
    local reversed = {}
    for i = #state.chapters, 1, -1 do
        reversed[#reversed + 1] = state.chapters[i]
    end
    return reversed
end

local function selectionCount(state)
    local count = 0
    for _ in pairs(state.selection or {}) do
        count = count + 1
    end
    return count
end

function Browser:comicItems(state)
    local info = state.info
    local items = {}
    items[#items + 1] = {
        text = "简介 · 封面",
        mandatory = info.updated ~= "" and info.updated or nil,
        kocomic_callback = function() self:showComicInfo(info) end,
    }
    if #info.groups > 1 then
        items[#items + 1] = {
            text = "分组:" .. info.groups[state.group_index].name,
            mandatory = "切换",
            kocomic_callback = function() self:showGroupDialog(state) end,
        }
    end
    if state.selection then
        items[#items + 1] = {
            text = string.format("下载选中的 %d 话", selectionCount(state)),
            mandatory = "开始",
            kocomic_callback = function() self:downloadSelection(state) end,
        }
        items[#items + 1] = {
            text = "退出多选",
            kocomic_callback = function()
                state.selection = nil
                self:renderState(state)
            end,
        }
    else
        items[#items + 1] = {
            text = string.format("下载全部 %d 话", #state.chapters),
            kocomic_callback = function()
                self:confirmDownload(state, state.chapters, string.format("要下载全部 %d 话吗?", #state.chapters))
            end,
        }
    end
    local list = orderedChapters(state)
    local offset = #items
    for i, chapter in ipairs(list) do
        local downloaded = Downloader.getChapterFile(info.path_word, chapter.uuid)
        local text = chapter.name
        if state.selection then
            text = (state.selection[chapter.uuid] and "✓ " or "□ ") .. text
        end
        local mandatory
        if downloaded then
            mandatory = "已下载"
        elseif chapter.size > 0 then
            mandatory = string.format("%d 页", chapter.size)
        end
        -- 账号那边读到的位置(拷贝漫画 App / 网页版同步过来的)
        local status = state.status
        if status and ((status.browse_id and status.browse_id == chapter.uuid)
                or (not status.browse_id and status.browse_name == chapter.name)) then
            mandatory = downloaded and "已下载 · 读到这里" or "读到这里"
            state.browse_item_index = offset + i
        end
        items[#items + 1] = {
            text = text,
            mandatory = mandatory,
            kocomic_callback = function()
                if state.selection then
                    state.selection[chapter.uuid] = not state.selection[chapter.uuid] or nil
                    self:renderState(state, offset + i)
                else
                    self:showChapterDialog(state, chapter, i, list, downloaded)
                end
            end,
            kocomic_hold_callback = function()
                state.selection = state.selection or {}
                state.selection[chapter.uuid] = not state.selection[chapter.uuid] or nil
                self:renderState(state, offset + i)
            end,
        }
    end
    return items
end

function Browser:showComicInfo(info)
    local lines = {}
    if info.authors ~= "" then lines[#lines + 1] = "作者:" .. info.authors end
    if info.status ~= "" then lines[#lines + 1] = "状态:" .. info.status end
    if info.tags ~= "" then lines[#lines + 1] = "题材:" .. info.tags end
    if info.updated ~= "" then lines[#lines + 1] = "更新:" .. info.updated end
    if info.brief ~= "" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = info.brief
    end
    local text = table.concat(lines, "\n")
    if info.cover == "" then
        UIManager:show(TextViewer:new{ title = info.name, text = text })
        return
    end
    local cover_dir = Config:getCacheDir() .. "/covers"
    util.makePath(cover_dir)
    local cover_path = cover_dir .. "/" .. info.path_word .. ".jpg"
    if (lfs.attributes(cover_path, "size") or 0) == 0 then
        loading("正在取封面…", function()
            return Api:downloadImage(info.cover, cover_path)
        end)
    end
    if (lfs.attributes(cover_path, "size") or 0) == 0 then
        UIManager:show(TextViewer:new{ title = info.name, text = text })
        return
    end
    UIManager:show(ImageViewer:new{
        file = cover_path,
        fullscreen = true,
        with_title_bar = true,
        title_text = info.name,
        caption = text,
        buttons_visible = true,
    })
end

function Browser:showGroupDialog(state)
    local dialog
    local buttons = {}
    for index, group in ipairs(state.info.groups) do
        buttons[#buttons + 1] = {{
            text = group.name .. (group.count > 0 and string.format("(%d)", group.count) or ""),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                if index == state.group_index then return end
                self:requireNetwork(function()
                    local chapters, err = loading("正在读取章节列表…", function()
                        return Api:chapters(state.info.path_word, group.path_word)
                    end)
                    if not chapters then
                        notify("读取章节失败:" .. tostring(err))
                        return
                    end
                    local new_state = self:makeComicState(state.info, index, chapters)
                    self.paths[#self.paths] = new_state
                    self:renderState(new_state)
                end)
            end,
        }}
    end
    dialog = ButtonDialog:new{ title = "选择分组", title_align = "center", buttons = buttons }
    UIManager:show(dialog)
end

--- 在线阅读:边下边看,分页和下载下来的完全一致
function Browser:readOnline(state, chapter)
    local start_index = 1
    for i, item in ipairs(state.chapters) do
        if item.uuid == chapter.uuid then
            start_index = i
            break
        end
    end
    self:requireNetwork(function()
        local ComicReader = require("kocomic/reader")
        local reader, err = ComicReader.open{
            comic = state.info,
            chapters = state.chapters,
            chapter_index = start_index,
            on_chapter_done = function()
                if self.state == state then
                    self:renderState(state)
                end
            end,
        }
        if not reader then
            notify("打不开:" .. tostring(err))
        end
    end)
end

function Browser:showChapterDialog(state, chapter, index, list, downloaded)
    local dialog
    local buttons = {}
    buttons[#buttons + 1] = {{
        text = "在线阅读(边下边看)",
        align = "left",
        callback = function()
            UIManager:close(dialog)
            self:readOnline(state, chapter)
        end,
    }}
    if downloaded then
        buttons[#buttons + 1] = {{
            text = "打开已下载的这一本",
            align = "left",
            callback = function()
                UIManager:close(dialog)
                self:openFile(downloaded)
            end,
        }}
    end
    buttons[#buttons + 1] = {{
        text = "下载这一话",
        align = "left",
        callback = function()
            UIManager:close(dialog)
            self:startDownload(state, { chapter })
        end,
    }}
    local remaining = #list - index + 1
    if remaining > 1 then
        buttons[#buttons + 1] = {{
            text = "从这一话开始,往后下载…",
            align = "left",
            callback = function()
                UIManager:close(dialog)
                UIManager:show(SpinWidget:new{
                    title_text = "下载多少话?",
                    info_text = "从「" .. chapter.name .. "」开始",
                    value = math.min(5, remaining),
                    value_min = 1,
                    value_max = remaining,
                    value_step = 1,
                    value_hold_step = 10,
                    ok_text = "下载",
                    callback = function(spin)
                        local chapters = {}
                        for i = index, index + spin.value - 1 do
                            chapters[#chapters + 1] = list[i]
                        end
                        self:startDownload(state, chapters)
                    end,
                })
            end,
        }}
    end
    buttons[#buttons + 1] = {{
        text = "多选下载",
        align = "left",
        callback = function()
            UIManager:close(dialog)
            state.selection = { [chapter.uuid] = true }
            self:renderState(state)
        end,
    }}
    dialog = ButtonDialog:new{ title = chapter.name, title_align = "center", buttons = buttons }
    UIManager:show(dialog)
end

function Browser:downloadSelection(state)
    local chapters = {}
    for _, chapter in ipairs(state.chapters) do
        if state.selection and state.selection[chapter.uuid] then
            chapters[#chapters + 1] = chapter
        end
    end
    if #chapters == 0 then
        notify("还没选中任何一话")
        return
    end
    self:startDownload(state, chapters)
end

function Browser:confirmDownload(state, chapters, question)
    UIManager:show(ConfirmBox:new{
        text = question,
        ok_text = "下载",
        ok_callback = function()
            self:startDownload(state, chapters)
        end,
    })
end

function Browser:startDownload(state, chapters)
    if #chapters == 0 then return end
    -- 章节要按原顺序下,不然合并出来的书是倒着的
    local ordered = {}
    for _, chapter in ipairs(state.chapters) do
        for _, wanted in ipairs(chapters) do
            if wanted.uuid == chapter.uuid then
                ordered[#ordered + 1] = chapter
                break
            end
        end
    end
    self:requireNetwork(function()
        Downloader:run(state.info, ordered, function(result)
            if self.state == state then
                state.selection = nil
                self:renderState(state)
            end
            self:showDownloadResult(result)
        end)
    end)
end

function Browser:showDownloadResult(result)
    local summary = Downloader.summary(result)
    local first = result.files[1]
    if first and Config:get("auto_open") then
        UIManager:nextTick(function()
            UIManager:show(ConfirmBox:new{
                text = summary .. "\n\n现在就看吗?",
                ok_text = "开始看",
                cancel_text = "待会儿",
                ok_callback = function() self:openFile(first) end,
            })
        end)
    else
        UIManager:nextTick(function() notify(summary) end)
    end
end

-- —————————————— 书架(本地文件)——————————————

function Browser:libraryItems(state)
    local dir = state.dir
    local dirs, files = {}, {}
    local ok = pcall(function()
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".." then
                local path = dir .. "/" .. name
                local mode = lfs.attributes(path, "mode")
                if mode == "directory" then
                    dirs[#dirs + 1] = { name = name, path = path }
                elseif mode == "file" and name:lower():match("%.cbz$") then
                    files[#files + 1] = { name = name, path = path,
                        size = lfs.attributes(path, "size") }
                end
            end
        end
    end)
    if not ok then
        return { { text = "读不了这个目录:" .. dir } }
    end
    table.sort(dirs, function(a, b) return a.name < b.name end)
    table.sort(files, function(a, b) return a.name < b.name end)
    local items = {}
    for _, entry in ipairs(dirs) do
        items[#items + 1] = {
            text = entry.name,
            mandatory = "文件夹",
            kocomic_callback = function()
                self:pushState({
                    view = "library",
                    title = entry.name,
                    subtitle = entry.path,
                    dir = entry.path,
                })
            end,
        }
    end
    for _, entry in ipairs(files) do
        items[#items + 1] = {
            text = entry.name:gsub("%.cbz$", ""),
            mandatory = humanSize(entry.size),
            kocomic_callback = function() self:openFile(entry.path) end,
            kocomic_hold_callback = function() self:showFileDialog(state, entry) end,
        }
    end
    if #items == 0 then
        items[#items + 1] = { text = "这里还什么都没有" }
    end
    return items
end

function Browser:showFileDialog(state, entry)
    local dialog
    dialog = ButtonDialog:new{
        title = entry.name,
        title_align = "center",
        buttons = {
            {{
                text = "打开",
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    self:openFile(entry.path)
                end,
            }},
            {{
                text = "删除",
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    UIManager:show(ConfirmBox:new{
                        text = "删掉「" .. entry.name .. "」?",
                        ok_text = "删除",
                        ok_callback = function()
                            os.remove(entry.path)
                            local record_dir = entry.path:match("(.*)/")
                            for path_word in pairs(Config:get("library") or {}) do
                                local record = Downloader.getRecord(path_word)
                                if record and record.dir == record_dir then
                                    Downloader.forgetFile(path_word, entry.path)
                                end
                            end
                            self:renderState(state)
                        end,
                    })
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

function Browser:openFile(path)
    if lfs.attributes(path, "mode") ~= "file" then
        notify("文件不在了:" .. path)
        return
    end
    self:onCloseAllMenus()
    UIManager:nextTick(function()
        if self.ui and self.ui.document then
            self.ui:switchDocument(path)
        elseif self.ui and self.ui.openFile then
            self.ui:openFile(path)
        else
            require("apps/reader/readerui"):showReader(path)
        end
    end)
end

-- —————————————— 设置 ——————————————

function Browser:settingsItems(state)
    local items = {}
    local function refresh()
        self:renderState(state)
    end

    items[#items + 1] = {
        text = "账号",
        mandatory = Config:isLoggedIn()
            and (Config:get("username") ~= "" and Config:get("username") or "已登录")
            or "未登录",
        kocomic_callback = function()
            if Config:isLoggedIn() then
                UIManager:show(ConfirmBox:new{
                    text = "退出登录?收藏功能会用不了。",
                    ok_text = "退出",
                    ok_callback = function()
                        Config:logout()
                        refresh()
                    end,
                })
            else
                self:showLoginDialog(refresh)
            end
        end,
    }
    items[#items + 1] = {
        text = "接口域名",
        mandatory = Config:get("api_host"),
        kocomic_callback = function()
            local menu
            local buttons = {
                {{
                    text = "自动查找可用域名(推荐)",
                    align = "left",
                    callback = function()
                        UIManager:close(menu)
                        self:findHost(refresh)
                    end,
                }},
                {{
                    text = "手动输入",
                    align = "left",
                    callback = function()
                        UIManager:close(menu)
                        self:showHostInput(refresh)
                    end,
                }},
            }
            for _, host in ipairs(Config:get("host_history") or {}) do
                if host ~= Config:get("api_host") then
                    buttons[#buttons + 1] = {{
                        text = "用回 " .. host,
                        align = "left",
                        callback = function()
                            UIManager:close(menu)
                            Config:set("api_host", host)
                            refresh()
                        end,
                    }}
                end
            end
            menu = ButtonDialog:new{
                title = "当前:" .. Config:get("api_host")
                    .. "\n拷贝漫画的域名隔段时间就换一个",
                title_align = "center",
                buttons = buttons,
            }
            UIManager:show(menu)
        end,
    }
    items[#items + 1] = {
        text = "  自动找可用接口",
        mandatory = "现在就找",
        kocomic_callback = function()
            self:findHost(refresh)
        end,
    }
    items[#items + 1] = {
        text = "图片清晰度",
        mandatory = Config:get("image_size") == "c800x" and "省流 800px" or "清晰 1500px",
        kocomic_callback = function()
            local dialog
            dialog = ButtonDialog:new{
                title = "图片清晰度",
                title_align = "center",
                buttons = {
                    {{
                        text = "清晰(1500px,推荐)",
                        align = "left",
                        callback = function()
                            UIManager:close(dialog)
                            Config:set("image_size", "c1500x")
                            refresh()
                        end,
                    }},
                    {{
                        text = "省流(800px)",
                        align = "left",
                        callback = function()
                            UIManager:close(dialog)
                            Config:set("image_size", "c800x")
                            refresh()
                        end,
                    }},
                },
            }
            UIManager:show(dialog)
        end,
    }
    return self:settingsItemsRest(items, refresh)
end

--- 手动填接口域名
function Browser:showHostInput(refresh)
    local dialog
    dialog = InputDialog:new{
                title = "拷贝漫画接口域名",
                input = Config:get("api_host"),
                description = "接口挂了或者换域名了就改这里,不要带 https://",
                buttons = {{
                    { text = "取消", id = "close", callback = function() UIManager:close(dialog) end },
                    {
                        text = "保存",
                        is_enter_default = true,
                        callback = function()
                            local host = dialog:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                            host = host:gsub("^https?://", ""):gsub("/.*$", "")
                            UIManager:close(dialog)
                            if host ~= "" then
                                Config:set("api_host", host)
                                refresh()
                            end
                        end,
                    },
                }},
            }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- 设置页剩下的那些项(上面那半截管账号和域名)
function Browser:settingsItemsRest(items, refresh)
    local layout_names = { auto = "自动判断", strip = "条漫:重新裁页", page = "单页:保留原图" }
    items[#items + 1] = {
        text = "排版方式",
        mandatory = layout_names[Config:get("layout_mode")] or "自动判断",
        kocomic_callback = function()
            local dialog
            local function choose(mode)
                return function()
                    UIManager:close(dialog)
                    Config:set("layout_mode", mode)
                    refresh()
                end
            end
            dialog = ButtonDialog:new{
                title = "拷贝漫画给的是切碎的图,不是排好的页",
                title_align = "center",
                buttons = {
                    {{ text = "自动判断(推荐)", align = "left", callback = choose("auto") }},
                    {{ text = "都当条漫:拼起来按屏幕重裁", align = "left", callback = choose("strip") }},
                    {{ text = "都当单页漫画:一张图一页", align = "left", callback = choose("page") }},
                },
            }
            UIManager:show(dialog)
        end,
    }
    local spread_names = { none = "不拆", rtl = "右→左(日漫)", ltr = "左→右" }
    items[#items + 1] = {
        text = "跨页大图拆成两页",
        mandatory = spread_names[Config:get("split_spread")] or "右→左(日漫)",
        kocomic_callback = function()
            local order = { "rtl", "ltr", "none" }
            local current = Config:get("split_spread")
            for i, value in ipairs(order) do
                if value == current then
                    Config:set("split_spread", order[i % #order + 1])
                    break
                end
            end
            refresh()
        end,
    }
    items[#items + 1] = {
        text = "重裁后的图片质量",
        mandatory = tostring(Config:get("jpeg_quality")),
        kocomic_callback = function()
            UIManager:show(SpinWidget:new{
                title_text = "重裁后的图片质量",
                info_text = "只影响条漫重裁出来的页;单页漫画是原图直接进包,不重新编码",
                value = Config:get("jpeg_quality"),
                value_min = 50,
                value_max = 95,
                value_step = 5,
                value_hold_step = 10,
                default_value = 85,
                callback = function(spin)
                    Config:set("jpeg_quality", spin.value)
                    refresh()
                end,
            })
        end,
    }
    items[#items + 1] = {
        text = "自动色阶(去灰)",
        mandatory = Config:get("auto_levels") and "开" or "关",
        kocomic_callback = function()
            Config:set("auto_levels", not Config:get("auto_levels"))
            refresh()
        end,
    }
    items[#items + 1] = {
        text = "  连原图一起去灰",
        mandatory = Config:get("enhance_originals") and "开(会重新编码)" or "关(保原图)",
        kocomic_callback = function()
            Config:set("enhance_originals", not Config:get("enhance_originals"))
            refresh()
        end,
    }
    items[#items + 1] = {
        text = "画面对比度",
        mandatory = tostring(Config:get("reader_contrast")),
        kocomic_callback = function()
            local dialog
            local ladder = { 0.8, 1.0, 1.5, 2.0, 4.0 }
            local labels = { "0.8 更淡", "1.0 KOReader 默认", "1.5 推荐", "2.0 更浓", "4.0 死黑" }
            local buttons = {}
            for i, value in ipairs(ladder) do
                buttons[#buttons + 1] = {{
                    text = labels[i],
                    align = "left",
                    callback = function()
                        UIManager:close(dialog)
                        Config:set("reader_contrast", value)
                        refresh()
                    end,
                }}
            end
            dialog = ButtonDialog:new{
                title = "写进书里的对比度\n(改完对已下载的书,用下面「补上阅读设置」重写)",
                title_align = "center",
                buttons = buttons,
            }
            UIManager:show(dialog)
        end,
    }
    items[#items + 1] = {
        text = "  裁页尺寸",
        mandatory = string.format("%d × %d", Config:getPageWidth(), Config:getPageHeight()),
        kocomic_callback = function()
            UIManager:show(InfoMessage:new{
                text = "条漫会按这个尺寸重新裁页,默认就是当前这块屏幕。\n"
                    .. "换设备看的话,建议在新设备上重新下载。",
            })
        end,
    }
    items[#items + 1] = {
        text = "话末附上本话吐槽",
        mandatory = Config:get("append_comments") and "开" or "关",
        kocomic_callback = function()
            Config:set("append_comments", not Config:get("append_comments"))
            refresh()
        end,
    }
    items[#items + 1] = {
        text = "  最多附多少条",
        mandatory = tostring(Config:get("comments_limit")),
        kocomic_callback = function()
            UIManager:show(SpinWidget:new{
                title_text = "话末最多附多少条吐槽",
                info_text = "一话热门的能有几百条,附太多会多出好几页",
                value = Config:get("comments_limit"),
                value_min = 5,
                value_max = 200,
                value_step = 5,
                value_hold_step = 20,
                default_value = 40,
                callback = function(spin)
                    Config:set("comments_limit", spin.value)
                    refresh()
                end,
            })
        end,
    }
    items[#items + 1] = {
        text = "每本 CBZ 装几话",
        mandatory = tostring(Config:get("chapters_per_book")),
        kocomic_callback = function()
            UIManager:show(SpinWidget:new{
                title_text = "每本 CBZ 装几话",
                info_text = "装多了翻起来连贯,但生成慢、文件大",
                value = Config:get("chapters_per_book"),
                value_min = 1,
                value_max = 50,
                value_step = 1,
                value_hold_step = 5,
                default_value = 1,
                callback = function(spin)
                    Config:set("chapters_per_book", spin.value)
                    refresh()
                end,
            })
        end,
    }
    items[#items + 1] = {
        text = "下载目录",
        mandatory = "选择",
        kocomic_callback = function()
            UIManager:show(PathChooser:new{
                select_directory = true,
                show_files = false,
                path = Config:getDownloadDir(),
                onConfirm = function(path)
                    Config:set("download_dir", path)
                    refresh()
                end,
            })
        end,
    }
    items[#items + 1] = {
        text = "  当前:" .. Config:getDownloadDir(),
        kocomic_callback = function()
            self:pushState({
                view = "library",
                title = "我的书架",
                subtitle = Config:getDownloadDir(),
                dir = Config:getDownloadDir(),
            })
        end,
    }
    items[#items + 1] = {
        text = "下载完成后问我要不要看",
        mandatory = Config:get("auto_open") and "开" or "关",
        kocomic_callback = function()
            Config:set("auto_open", not Config:get("auto_open"))
            refresh()
        end,
    }
    items[#items + 1] = {
        text = "打包后保留原始图片",
        mandatory = Config:get("keep_cache") and "开" or "关",
        kocomic_callback = function()
            Config:set("keep_cache", not Config:get("keep_cache"))
            refresh()
        end,
    }
    items[#items + 1] = {
        text = "给书架里的书补上阅读设置",
        mandatory = "修一下",
        kocomic_callback = function()
            UIManager:show(ConfirmBox:new{
                text = "KOReader 对图片书的默认缩放是「内容-宽度」,会把一页撑到溢出、"
                    .. "再从画面中间切成两屏 —— 看着就像被乱切。\n\n"
                    .. "给书架里所有 CBZ 写上「整页显示」?",
                ok_text = "都修一下",
                ok_callback = function()
                    local fixed = Downloader.fixReaderDefaults(Config:getDownloadDir())
                    notify(string.format("已给 %d 本写上整页显示,重新打开就好了", fixed))
                end,
            })
        end,
    }
    items[#items + 1] = {
        text = "清空图片缓存",
        mandatory = humanSize(self:cacheSize()),
        kocomic_callback = function()
            UIManager:show(ConfirmBox:new{
                text = "清空下载缓存?已经打包好的 CBZ 不受影响。",
                ok_text = "清空",
                ok_callback = function()
                    ffiUtil.purgeDir(Config:getCacheDir())
                    util.makePath(Config:getCacheDir())
                    refresh()
                end,
            })
        end,
    }
    items[#items + 1] = {
        text = "忘掉「已下载」记录",
        kocomic_callback = function()
            UIManager:show(ConfirmBox:new{
                text = "清掉章节列表上的已下载标记?文件不会被删。",
                ok_text = "清掉",
                ok_callback = function()
                    Config:set("library", {})
                    refresh()
                end,
            })
        end,
    }
    return items
end

function Browser:cacheSize()
    local total = 0
    local function walk(dir)
        local ok = pcall(function()
            for name in lfs.dir(dir) do
                if name ~= "." and name ~= ".." then
                    local path = dir .. "/" .. name
                    local mode = lfs.attributes(path, "mode")
                    if mode == "directory" then
                        walk(path)
                    elseif mode == "file" then
                        total = total + (lfs.attributes(path, "size") or 0)
                    end
                end
            end
        end)
        return ok
    end
    walk(Config:getCacheDir())
    return total
end

function Browser:showLoginDialog(on_success)
    local dialog
    dialog = MultiInputDialog:new{
        title = "登录拷贝漫画",
        fields = {
            { text = Config:get("username"), hint = "用户名" },
            { text = "", hint = "密码", text_type = "password" },
        },
        buttons = {{
            {
                text = "取消",
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = "登录",
                callback = function()
                    local fields = dialog:getFields()
                    UIManager:close(dialog)
                    local username, password = fields[1], fields[2]
                    if username == "" or password == "" then
                        notify("用户名和密码都要填")
                        return
                    end
                    self:requireNetwork(function()
                        local token, err = loading("正在登录…", function()
                            return Api:login(username, password)
                        end)
                        if not token then
                            notify("登录失败:" .. tostring(err))
                            return
                        end
                        Config:set("username", username)
                        Config:set("token", token)
                        notify("登录成功")
                        if on_success then on_success() end
                    end)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- —————————————— 左上角的操作菜单 ——————————————

function Browser:showActionMenu()
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
    local state = self.state
    if state.view == "comic" then
        if state.browse_item_index then
            add("跳到上次读到的那一话", function()
                self:renderState(state, state.browse_item_index)
            end)
        end
        add("收藏 / 取消收藏", function() self:toggleFavorite(state) end)
        add("多选下载", function()
            state.selection = state.selection or {}
            self:renderState(state)
        end)
        add(state.reversed and "章节按正序排" or "章节按倒序排", function()
            state.reversed = not state.reversed
            self:renderState(state)
        end)
        add("刷新章节列表", function()
            self:requireNetwork(function()
                local group = state.info.groups[state.group_index]
                local chapters, err = loading("正在刷新…", function()
                    return Api:chapters(state.info.path_word, group.path_word, true)
                end)
                if not chapters then
                    notify("刷新失败:" .. tostring(err))
                    return
                end
                state.chapters = chapters
                self:renderState(state)
            end)
        end)
    elseif state.view == "list" then
        add("搜索漫画", function() self:showSearchDialog() end)
    elseif state.view == "library" then
        add("刷新", function() self:renderState(state) end)
    end
    add("回到首页", function() self:goHome() end)
    add("设置", function()
        self:pushState({ view = "settings", title = "设置", subtitle = "" })
    end)
    dialog = ButtonDialog:new{
        buttons = buttons,
        shrink_unneeded_width = true,
        anchor = function()
            return self.title_bar.left_button.image.dimen
        end,
    }
    UIManager:show(dialog)
end

function Browser:toggleFavorite(state)
    if not Config:isLoggedIn() then
        UIManager:show(ConfirmBox:new{
            text = "收藏要先登录拷贝漫画账号,现在登录吗?",
            ok_text = "去登录",
            ok_callback = function() self:showLoginDialog() end,
        })
        return
    end
    self:requireNetwork(function()
        local path_word = state.info.path_word
        local is_fav, err = loading("正在查收藏状态…", function()
            return Api:isFavorite(path_word)
        end)
        if is_fav == nil then
            notify("查询失败:" .. tostring(err))
            return
        end
        local ok, set_err = loading(is_fav and "正在取消收藏…" or "正在收藏…", function()
            return Api:setFavorite(path_word, not is_fav)
        end)
        if not ok then
            notify("操作失败:" .. tostring(set_err))
            return
        end
        notify(is_fav and "已取消收藏" or "已加入收藏")
    end)
end

return Browser
