--[[--
把一话的吐槽排版成书页,接在这一话末尾。

拷贝漫画管章节评论叫「吐槽」,一话动辄几百条 —— 看完正文顺手翻两页评论,
是这类漫画阅读体验里挺重要的一半。

这里只干两件事:量一遍每条要占多高、按页塞满;真正画字交给 KOReader 的
TextBoxWidget(中日韩断行、字体回退都是现成的)。
]]

local Font = require("ui/font")
local ImageUtil = require("kocomic/imageutil")
local Screen = require("device").screen
local TextBoxWidget = require("ui/widget/textboxwidget")

local Comments = {}

local MAX_TEXT = 600      -- 太长的吐槽截一下,免得一条占满整页

local function scaled(size)
    return Screen:scaleBySize(size)
end

local function truncate(text)
    if #text <= MAX_TEXT then
        return text
    end
    -- 按字节截会切坏 UTF-8,退到最近的字符边界
    local cut = MAX_TEXT
    while cut > 1 and text:byte(cut + 1) and text:byte(cut + 1) >= 128
            and text:byte(cut + 1) <= 191 do
        cut = cut - 1
    end
    return text:sub(1, cut) .. "…"
end

--- 量好尺寸、排成一页页。
-- @return pages(每页是一串 block)、title 部件、总条数
function Comments.paginate(list, opts)
    local margin = opts.margin or scaled(30)
    local inner = opts.width - margin * 2
    local base = opts.font_size or 19
    local title = TextBoxWidget:new{
        text = opts.title or "本话吐槽",
        face = Font:getFace("tfont", base + 3),
        width = inner,
        bold = true,
    }
    local title_height = title:getSize().h + scaled(16)
    local usable = opts.height - margin * 2

    local pages = {}
    local current, used = {}, title_height
    for _, comment in ipairs(list) do
        local meta = TextBoxWidget:new{
            text = (comment.user or "匿名") .. "    " .. (comment.time or ""),
            face = Font:getFace("cfont", base - 5),
            width = inner,
        }
        local body = TextBoxWidget:new{
            text = truncate(comment.text or ""),
            face = Font:getFace("cfont", base),
            width = inner,
        }
        local block = {
            meta = meta,
            body = body,
            height = meta:getSize().h + body:getSize().h + scaled(8),
        }
        local needed = block.height + scaled(16)
        if #current > 0 and used + needed > usable then
            pages[#pages + 1] = current
            current, used = {}, title_height
        end
        current[#current + 1] = block
        used = used + needed
    end
    if #current > 0 then
        pages[#pages + 1] = current
    end
    return pages, title
end

--- 画一页
function Comments.renderPage(blocks, title, opts, page_no, page_total)
    local margin = opts.margin or scaled(30)
    local inner = opts.width - margin * 2
    local page = ImageUtil.newPage(opts.width, opts.height)
    local y = margin
    title:paintTo(page, margin, y)
    y = y + title:getSize().h + scaled(8)
    ImageUtil.drawRule(page, margin, y, inner, 2)
    y = y + scaled(14)
    for _, block in ipairs(blocks) do
        block.meta:paintTo(page, margin, y)
        y = y + block.meta:getSize().h + scaled(2)
        block.body:paintTo(page, margin, y)
        y = y + block.body:getSize().h + scaled(10)
        ImageUtil.drawRule(page, margin, y, inner, 1)
        y = y + scaled(14)
    end
    if page_total and page_total > 1 then
        local footer = TextBoxWidget:new{
            text = string.format("吐槽 %d / %d", page_no, page_total),
            face = Font:getFace("cfont", (opts.font_size or 19) - 5),
            width = inner,
            alignment = "center",
        }
        footer:paintTo(page, margin, opts.height - margin - footer:getSize().h)
        footer:free()
    end
    return page
end

--- 排好版,交出一串「画一页」的函数,pager 当额外页接在正文后面。
-- 返回的表上带 free(),pager 关掉时会调用。
function Comments.buildPages(list, opts)
    if not list or #list == 0 then
        return nil
    end
    local ok, pages, title = pcall(Comments.paginate, list, opts)
    if not ok or not pages or #pages == 0 then
        return nil
    end
    local renderers = {}
    for index, blocks in ipairs(pages) do
        renderers[index] = function()
            return Comments.renderPage(blocks, title, opts, index, #pages)
        end
    end
    renderers.free = function()
        title:free()
        for _, blocks in ipairs(pages) do
            for _, block in ipairs(blocks) do
                block.meta:free()
                block.body:free()
            end
        end
    end
    return renderers
end

--- 取吐槽 + 排版,一步到位。取不到就返回 nil(正文照看不误)。
function Comments.buildForChapter(comic, chapter, opts)
    local Api = require("kocomic/api")
    local Config = require("kocomic/config")
    if not Config:get("append_comments") then
        return nil
    end
    local list = Api:chapterComments(chapter.uuid, Config:get("comments_limit"))
    if not list or #list == 0 then
        return nil
    end
    return Comments.buildPages(list, {
        width = opts.width,
        height = opts.height,
        font_size = opts.font_size,
        title = string.format("《%s》%s · 吐槽 %d 条", comic.name, chapter.name, #list),
    }), #list
end

return Comments
