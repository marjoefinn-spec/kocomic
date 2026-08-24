--[[--
下载调度:拉图片 → 重新排版 → 打包 CBZ → 记账。

排版这一步是关键:拷贝漫画给的是随手切开的碎图,直接装进 CBZ 每页都断在
奇怪的地方。这里用 pager 把碎图重新拼成一屏一屏(条漫)或者理成规规矩矩的
单页(普通漫画),再打包 —— 所以 KOReader 打开时每页正好一屏。

整个过程跑在 Trapper 的协程里,下载途中点一下屏幕就能中止。
]]

local Api = require("kocomic/api")
local Cbz = require("kocomic/cbz")
local Config = require("kocomic/config")
local ImageUtil = require("kocomic/imageutil")
local Pager = require("kocomic/pager")
local Trapper = require("ui/trapper")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local Downloader = {}

-- —————————————— 路径与命名 ——————————————

local function safeName(name)
    return util.getSafeFilename(name or "未知", nil, 180)
end

function Downloader.getComicDir(comic_name)
    return Config:getDownloadDir() .. "/" .. safeName(comic_name)
end

--- 一本 CBZ 的书名:单话用话名,多话用「首话~末话」
local function bookName(comic_name, chapters)
    local suffix
    if #chapters == 1 then
        suffix = chapters[1].name
    else
        suffix = chapters[1].name .. "~" .. chapters[#chapters].name
    end
    return safeName(comic_name .. " - " .. suffix)
end

--- 按设置里的「每本几话」把章节切成一册册
local function groupChapters(chapters, per_book)
    local books = {}
    for i = 1, #chapters, per_book do
        local book = {}
        for j = i, math.min(i + per_book - 1, #chapters) do
            book[#book + 1] = chapters[j]
        end
        books[#books + 1] = book
    end
    return books
end

-- —————————————— 已下载记账 ——————————————
-- 记在插件设置里,用来在章节列表上打勾、以及直接打开已下载的那一本

local function getLibrary()
    local library = Config:get("library")
    return type(library) == "table" and library or {}
end

function Downloader.getRecord(path_word)
    return getLibrary()[path_word]
end

--- 这一话下载过吗?下过就返回 CBZ 的完整路径。
function Downloader.getChapterFile(path_word, uuid)
    local record = getLibrary()[path_word]
    if not record or type(record.chapters) ~= "table" then
        return nil
    end
    local filename = record.chapters[uuid]
    if not filename then
        return nil
    end
    local path = (record.dir or "") .. "/" .. filename
    if lfs.attributes(path, "mode") == "file" then
        return path
    end
    return nil
end

local function remember(comic, dir, chapters, filename)
    local library = getLibrary()
    local record = library[comic.path_word] or {}
    record.name = comic.name
    record.dir = dir
    record.chapters = type(record.chapters) == "table" and record.chapters or {}
    for _, chapter in ipairs(chapters) do
        record.chapters[chapter.uuid] = filename
    end
    library[comic.path_word] = record
    Config:set("library", library)
end

--- 文件被删掉之后把记账清干净
function Downloader.forgetFile(path_word, path)
    local library = getLibrary()
    local record = library[path_word]
    if not record or type(record.chapters) ~= "table" then
        return
    end
    local filename = path:match("([^/]+)$")
    for uuid, name in pairs(record.chapters) do
        if name == filename then
            record.chapters[uuid] = nil
        end
    end
    Config:set("library", library)
end

-- —————————————— 图片来源 ——————————————

function Downloader.cacheDirFor(comic, chapter)
    return Config:getCacheDir() .. "/" .. (comic.path_word ~= "" and comic.path_word or "comic")
        .. "/" .. chapter.uuid
end

--- 和在线阅读共用同一份缓存:在线看过的图,下载时不用再下一遍
function Downloader.makeSource(comic, chapter, pages)
    local dir = Downloader.cacheDirFor(comic, chapter)
    util.makePath(dir)
    local function pathFor(index)
        return string.format("%s/p%04d.img", dir, pages[index].index)
    end
    return {
        count = #pages,
        dir = dir,
        pathFor = pathFor,
        isCached = function(index)
            return pages[index] ~= nil and (lfs.attributes(pathFor(index), "size") or 0) > 0
        end,
        getData = function(index)
            if not pages[index] then
                return nil, "没有这一张"
            end
            local path = pathFor(index)
            if (lfs.attributes(path, "size") or 0) == 0 then
                local ok, err = Api:downloadImage(pages[index].url, path)
                if not ok then
                    return nil, err
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

-- —————————————— 下载 ——————————————

local function progressText(comic, chapter, chapter_no, chapter_total, line)
    local lines = { "《" .. comic.name .. "》" }
    if chapter_total > 1 then
        lines[#lines + 1] = string.format("第 %d/%d 话 · %s", chapter_no, chapter_total, chapter.name)
    else
        lines[#lines + 1] = chapter.name
    end
    lines[#lines + 1] = line or "正在获取图片列表…"
    return table.concat(lines, "\n")
end

--- 把一话的图片全下到缓存目录。返回 source,中止或失败返回 nil。
local function fetchChapter(comic, chapter, chapter_no, chapter_total, result)
    if not Trapper:info(progressText(comic, chapter, chapter_no, chapter_total)) then
        result.aborted = true
        return nil
    end
    local pages, err = Api:chapterPages(comic.path_word, chapter.uuid)
    if not pages then
        result.errors[#result.errors + 1] = chapter.name .. ":" .. tostring(err)
        return nil
    end
    local source = Downloader.makeSource(comic, chapter, pages)
    for i = 1, source.count do
        if not source.isCached(i) then
            local ok, download_err = Api:downloadImage(pages[i].url, source.pathFor(i))
            if not ok then
                result.errors[#result.errors + 1] =
                    string.format("%s 第%d张:%s", chapter.name, i, tostring(download_err))
            end
        end
        -- 每 4 张认真检查一次「用户是不是想中止」,其余的只刷新文字
        local check_dismiss = (i % 4 == 0) or (i == source.count)
        local go_on = Trapper:info(
            progressText(comic, chapter, chapter_no, chapter_total,
                string.format("正在下载 %d/%d 张", i, source.count)),
            true, not check_dismiss)
        if not go_on then
            result.aborted = true
            return nil
        end
    end
    return source
end

-- —————————————— 排版打包 ——————————————

--- 把一话排好版,产出 CBZ 里的条目。
-- 条漫:重新裁成一屏一屏,存成灰度 JPEG。
-- 单页漫画:原图直接进包(不重新编码,不掉画质),只有跨页大图拆成两页。
local function layoutChapter(comic, chapter, source, prefix, work_dir, entries, result, report)
    local pager = Pager.new(source, {
        page_w = Config:getPageWidth(),
        page_h = Config:getPageHeight(),
        mode = Config:get("layout_mode"),
        split_spread = Config:get("split_spread"),
        auto_levels = Config:get("auto_levels"),
    })
    local ok, mode = pcall(function() return pager:start() end)
    if not ok then
        result.errors[#result.errors + 1] = chapter.name .. ":排版失败 " .. tostring(mode)
        pager:close()
        return
    end
    local quality = Config:get("jpeg_quality")
    local enhance_originals = Config:get("auto_levels") and Config:get("enhance_originals")
    local serial = 0
    -- 正文后面接本话吐槽(取不到就算了)
    if Config:get("append_comments") then
        report("正在取本话吐槽…")
        local Comments = require("kocomic/comments")
        local built_ok, extras, count = pcall(function()
            return Comments.buildForChapter(comic, chapter, {
                width = Config:getPageWidth(),
                height = Config:getPageHeight(),
            })
        end)
        if built_ok and type(extras) == "table" then
            pager:setExtras(extras)
            result.comments = result.comments + (tonumber(count) or 0)
        end
    end
    local function nextPath()
        serial = serial + 1
        return string.format("%s/%s%04d.jpg", work_dir, prefix:gsub("/", "_"), serial), serial
    end

    if mode == "page" then
        result.mode_page = result.mode_page + 1
        for index = 1, source.count do
            local views = pager:viewsFor(index)
            if views[1] == false then
                local entry_name = string.format("%sp%04d", prefix, index * 2)
                if enhance_originals then
                    -- 原尺寸不动,只把黑白点拉一下,再重新编码
                    local bb = pager:getImage(index)
                    if bb then
                        local path = nextPath()
                        ImageUtil.saveJpeg(bb, path, quality)
                        entries[#entries + 1] = { path = path, name = entry_name }
                    else
                        entries[#entries + 1] = { path = source.pathFor(index), name = entry_name }
                    end
                else
                    -- 原样收进包里,不重新编码
                    entries[#entries + 1] = { path = source.pathFor(index), name = entry_name }
                end
            else
                -- 跨页大图:从中间劈开,按阅读顺序放两页
                local bb = pager:getImage(index)
                if not bb then
                    result.errors[#result.errors + 1] =
                        string.format("%s 第%d张读不出来", chapter.name, index)
                else
                    local width, height = ImageUtil.size(bb)
                    local half = math.floor(width / 2)
                    for order, side in ipairs(views) do
                        local x = (side == "left") and 0 or half
                        local piece_w = (side == "left") and half or (width - half)
                        local piece = ImageUtil.newPage(piece_w, height, bb:getType())
                        ImageUtil.blit(piece, bb, 0, 0, x, 0, piece_w, height)
                        local path = nextPath()
                        ImageUtil.saveJpeg(piece, path, quality)
                        ImageUtil.free(piece)
                        entries[#entries + 1] = {
                            path = path,
                            name = string.format("%sp%04d", prefix, index * 2 + order - 1),
                        }
                    end
                end
            end
            if index % 8 == 0 then
                report(string.format("正在整理 %d/%d 张", index, source.count))
            end
        end
        -- 原图直进包这条路不走 pager 的翻页,吐槽页得自己画
        for extra_index = 1, #(pager.extras or {}) do
            local ok_extra, page = pcall(pager.extras[extra_index])
            if ok_extra and page then
                local path = nextPath():gsub("%.jpg$", ".png")
                ImageUtil.savePng(page, path)
                ImageUtil.free(page)
                entries[#entries + 1] = {
                    path = path,
                    name = string.format("%sz%04d", prefix, extra_index),
                }
            end
        end
    else
        result.mode_strip = result.mode_strip + 1
        local aborted = false
        pager:forEachPage(function(page, n)
            local path = nextPath()
            local saved
            if pager:isExtra(n) then
                path = path:gsub("%.jpg$", ".png")
                saved = ImageUtil.savePng(page, path)    -- 文字页用 PNG,清楚
            else
                saved = ImageUtil.saveJpeg(page, path, quality)
            end
            if saved then
                entries[#entries + 1] = { path = path, name = string.format("%sp%04d", prefix, n) }
            else
                result.errors[#result.errors + 1] = string.format("%s 第%d屏存盘失败", chapter.name, n)
            end
            if n % 4 == 0 then
                if report(string.format("正在重新裁页,已裁 %d 屏", n)) == false then
                    aborted = true
                    return false
                end
            end
        end)
        if aborted then
            result.aborted = true
        end
    end
    pager:close()
end

--- 给生成的 CBZ 写一份阅读设置。
-- KOReader 对图片文档的默认缩放是「内容 - 宽度」(自动裁白边再撑满宽度),
-- 漫画页比屏幕瘦一点,撑满宽度之后下面就溢出去了 —— 于是一页被切成两屏,
-- 断口还落在画面中间。这就是「每页切的都不对」的真凶。
-- 这里直接把这本书钉死成「整页 + 一页一翻」,不用用户自己去翻设置。
function Downloader.applyReaderDefaults(path)
    local ok, DocSettings = pcall(require, "docsettings")
    if not ok then
        return
    end
    local written = pcall(function()
        local settings = DocSettings:open(path)
        settings:saveSetting("zoom_mode", "page")           -- 整页显示,绝不溢出
        settings:saveSetting("kopt_zoom_mode_genus", 4)     -- 4 = page
        settings:saveSetting("kopt_zoom_mode_type", 2)      -- 2 = 整页(非宽/高)
        settings:saveSetting("kopt_page_scroll", 0)         -- 一页一页翻,不滚动
        settings:saveSetting("kopt_contrast", Config:get("reader_contrast"))  -- 默认那格偏灰
        settings:flush()
    end)
    if not written then
        logger.warn("KoComic: 写阅读设置失败", path)
    end
end

-- —————————————— 主流程 ——————————————

local function downloadBooks(comic, chapters, result)
    local per_book = math.max(1, tonumber(Config:get("chapters_per_book")) or 1)
    local books = groupChapters(chapters, per_book)
    local comic_dir = Downloader.getComicDir(comic.name)
    util.makePath(comic_dir)
    local work_dir = Config:getCacheDir() .. "/pack"
    local chapter_no = 0
    for _, book in ipairs(books) do
        local filename = bookName(comic.name, book) .. ".cbz"
        local out_path = comic_dir .. "/" .. filename
        if lfs.attributes(out_path, "mode") == "file" then
            result.skipped = result.skipped + 1
            chapter_no = chapter_no + #book
            remember(comic, comic_dir, book, filename)
        else
            ffiUtil.purgeDir(work_dir)
            util.makePath(work_dir)
            local entries = {}
            for i, chapter in ipairs(book) do
                chapter_no = chapter_no + 1
                local source = fetchChapter(comic, chapter, chapter_no, #chapters, result)
                if source and not result.aborted then
                    local prefix = #book > 1 and string.format("c%03d/", i) or ""
                    layoutChapter(comic, chapter, source, prefix, work_dir, entries, result,
                        function(line)
                            return Trapper:info(
                                progressText(comic, chapter, chapter_no, #chapters, line), true)
                        end)
                end
                if result.aborted then
                    break
                end
            end
            if #entries > 0 and not result.aborted then
                Trapper:info("正在打包:\n" .. filename, false, true)
                local path, stats = Cbz.create(out_path, entries)
                if path then
                    Downloader.applyReaderDefaults(path)
                    result.files[#result.files + 1] = path
                    result.pages = result.pages + (type(stats) == "table" and stats.count or 0)
                    remember(comic, comic_dir, book, filename)
                else
                    result.errors[#result.errors + 1] = filename .. ":" .. tostring(stats)
                end
            end
            ffiUtil.purgeDir(work_dir)
        end
        if result.aborted then
            break
        end
    end
    -- 打包完成后清掉原始图片(中途放弃的话留着,下次能接着下)
    if not result.aborted and not Config:get("keep_cache") then
        ffiUtil.purgeDir(Config:getCacheDir() .. "/"
            .. (comic.path_word ~= "" and comic.path_word or "comic"))
    end
end

--- 给已经下载好的书补上阅读设置(插件早期版本下的书没有这份设置)
function Downloader.fixReaderDefaults(dir)
    local fixed = 0
    local function walk(path)
        local ok = pcall(function()
            for name in lfs.dir(path) do
                if name ~= "." and name ~= ".." then
                    local full = path .. "/" .. name
                    local mode = lfs.attributes(full, "mode")
                    if mode == "directory" then
                        walk(full)
                    elseif mode == "file" and name:lower():match("%.cbz$") then
                        Downloader.applyReaderDefaults(full)
                        fixed = fixed + 1
                    end
                end
            end
        end)
        return ok
    end
    walk(dir or Config:getDownloadDir())
    return fixed
end

--- 下载入口。on_finished(result) 在下载结束后回调。
function Downloader:run(comic, chapters, on_finished)
    Trapper:wrap(function()
        Trapper:setPausedText("下载已暂停,要中止吗?", "中止下载", "继续下载")
        local result = { files = {}, errors = {}, skipped = 0, pages = 0, comments = 0,
                         mode_strip = 0, mode_page = 0, aborted = false }
        downloadBooks(comic, chapters, result)
        Trapper:reset()
        logger.info("KoComic: 下载结束", #result.files, "本,", #result.errors, "个问题")
        if on_finished then
            on_finished(result)
        end
    end)
end

--- 把下载结果说成人话
function Downloader.summary(result)
    local lines = {}
    if #result.files > 0 then
        lines[#lines + 1] = string.format("已生成 %d 本 CBZ,共 %d 页", #result.files, result.pages)
        if result.mode_strip > 0 and result.mode_page == 0 then
            lines[#lines + 1] = "(按条漫重新裁的页,每页正好一屏)"
        elseif result.mode_page > 0 and result.mode_strip == 0 then
            lines[#lines + 1] = "(单页漫画,保留原图画质)"
        end
    end
    if (result.comments or 0) > 0 then
        lines[#lines + 1] = string.format("话末附了 %d 条吐槽", result.comments)
    end
    if result.skipped > 0 then
        lines[#lines + 1] = string.format("%d 本已存在,跳过", result.skipped)
    end
    if result.aborted then
        lines[#lines + 1] = "下载已中止(下好的图片保留着,下次接着下)"
    end
    if #result.errors > 0 then
        lines[#lines + 1] = string.format("%d 处出错:", #result.errors)
        for i = 1, math.min(3, #result.errors) do
            lines[#lines + 1] = "· " .. result.errors[i]
        end
    end
    if #lines == 0 then
        lines[#lines + 1] = "什么都没下到"
    end
    return table.concat(lines, "\n")
end

return Downloader
