--[[--
排版引擎:把拷贝漫画给的一堆碎图,重新拼成一屏一屏。

**为什么需要这东西**:拷贝漫画的接口并不返回「页」,返回的是把整条漫画
随手切开的碎块 —— 实测同一话里有 1500x691、1500x250、1477x1125 这种,
条漫更是被切成一串 640x500 的方块。直接一块一图当页看,每页都是从画面
中间断开的,这就是「每页切的都不对」的由来。

所以这里先判断这一话是哪种货色:

- **条漫(strip)**:所有碎块拼回一条长图,再按屏幕高度重新裁 ——
  裁之前还会在下沿附近找一条空白横线,尽量不把分镜劈两半。
- **单页漫画(page)**:碎块本来就是一页一页的,原样保留,
  只把跨页大图(横着的)拆成两页。

对外只有一个「一屏一屏往下走」的接口,在线阅读和打包 CBZ 共用同一套,
所以看到的和下下来的完全一致。
]]

local ImageUtil = require("kocomic/imageutil")
local ImgHeader = require("kocomic/imgheader")
local Levels = require("kocomic/levels")
local logger = require("logger")

local Pager = {}
Pager.__index = Pager

local CACHE_SIZE = 3

--- @param source { count = 张数, getData = function(index) -> data | nil, err }
--- @param opts { page_w, page_h, mode = "auto"/"strip"/"page", split_spread = "none"/"rtl"/"ltr" }
function Pager.new(source, opts)
    opts = opts or {}
    return setmetatable({
        source = source,
        page_w = opts.page_w,
        page_h = opts.page_h,
        requested_mode = opts.mode or "auto",
        split_spread = opts.split_spread or "rtl",
        auto_levels = opts.auto_levels ~= false,
        levels_opts = opts.levels_opts,
        gamma = opts.gamma or 1,
        extras = opts.extras,        -- 正文后面还要接的页(吐槽),每项是个「画一页」的函数
        mode = nil,
        dims = {},          -- [i] = {w=, h=}
        cache = {},         -- [i] = bb
        cache_order = {},
        cursors = {},       -- [n] = 第 n 屏的起点
    }, Pager)
end

-- —————————————— 素材 ——————————————

function Pager:getDim(index)
    if self.dims[index] then
        return self.dims[index]
    end
    if index < 1 or index > self.source.count then
        return nil
    end
    local data, err = self.source.getData(index)
    if not data then
        return nil, err
    end
    local width, height = ImgHeader.imageSize(data)
    if not width then    -- 文件头认不出来(webp 之类),只好真解一次
        local bb = ImageUtil.decode(data)
        if bb then
            width, height = ImageUtil.size(bb)
            ImageUtil.free(bb)
        end
    end
    if not width or width == 0 or height == 0 then
        return nil, "读不出图片尺寸"
    end
    self.dims[index] = { w = width, h = height }
    return self.dims[index]
end

--- 拿解码好的图。条漫模式统一缩到一屏宽,单页模式保持原尺寸(拼版时再缩)。
function Pager:getImage(index)
    if self.cache[index] then
        return self.cache[index]
    end
    local data, err = self.source.getData(index)
    if not data then
        return nil, err
    end
    local bb, decode_err = ImageUtil.decode(data, self.mode == "strip" and self.page_w or nil)
    if not bb then
        return nil, decode_err
    end
    self:enhance(bb)
    self.cache[index] = bb
    self.cache_order[#self.cache_order + 1] = index
    while #self.cache_order > CACHE_SIZE do
        local oldest = table.remove(self.cache_order, 1)
        if self.cache[oldest] and oldest ~= index then
            ImageUtil.free(self.cache[oldest])
            self.cache[oldest] = nil
        end
    end
    return bb
end

--- 拉一下黑白点。扫描件常常纸不白、墨不黑,整张挤在中间那段灰里,
--- 水墨屏上就显得发灰;这里按每张图自适应地拉开,比无脑加对比度稳。
function Pager:enhance(bb)
    if not self.auto_levels and self.gamma == 1 then
        return
    end
    local lut
    if self.auto_levels then
        local histogram = ImageUtil.histogram(bb)
        if not histogram then
            return
        end
        local opts = {}
        for key, value in pairs(self.levels_opts or {}) do
            opts[key] = value
        end
        opts.gamma = self.gamma
        lut = Levels.computeLut(histogram, opts)
    else
        lut = Levels.gammaLut(self.gamma)
    end
    if lut then
        ImageUtil.applyLut(bb, lut)
    end
end

--- 正文后面接的额外页(吐槽)。可以在 start() 之后再塞。
function Pager:setExtras(extras)
    self.extras = extras
end

function Pager:firstExtraCursor()
    if self.extras and #self.extras > 0 then
        return { extra = 1 }
    end
    return nil
end

--- 只丢掉解码缓存(判完型要按新模式重解一遍)
function Pager:clearCache()
    for index, bb in pairs(self.cache) do
        ImageUtil.free(bb)
        self.cache[index] = nil
    end
    self.cache_order = {}
end

--- 彻底收摊:缓存和吐槽页的部件一起放掉
function Pager:close()
    self:clearCache()
    if self.extras and self.extras.free then
        self.extras.free()
        self.extras = nil
    end
end

-- —————————————— 判型 ——————————————

local function inkOf(values)
    local dark = 0
    for _, value in ipairs(values) do
        if value < 224 then
            dark = dark + 1
        end
    end
    return dark / #values
end

local function similarityOf(a, b)
    local diff = 0
    for i = 1, math.min(#a, #b) do
        diff = diff + math.abs(a[i] - b[i])
    end
    return 1 - diff / math.min(#a, #b) / 255
end

--- 上一张的最后一行和下一张的第一行接得上吗?
-- 条漫是从一整条图上定高切下来的,接缝处两行几乎一模一样(实测相似度 0.97 以上);
-- 分开扫的漫画页,接缝两边是各自的白边或不相干的画面(实测 0.86 以下)。
function Pager:seamsLookContinuous()
    local checked, continuous = 0, 0
    for index = 1, math.min(4, self.source.count - 1) do
        local upper = self:getImage(index)
        local lower = self:getImage(index + 1)
        if upper and lower then
            local bottom = ImageUtil.rowSample(upper, upper:getHeight() - 1, 64)
            local top = ImageUtil.rowSample(lower, 0, 64)
            if bottom and top then
                checked = checked + 1
                -- 两边都是白边的话说明本来就是各自独立的页,不算连续
                if similarityOf(bottom, top) > 0.93
                        and math.max(inkOf(bottom), inkOf(top)) > 0.05 then
                    continuous = continuous + 1
                end
            end
        end
    end
    if checked == 0 then
        return nil
    end
    return continuous * 2 >= checked, continuous, checked
end

function Pager:detectMode()
    if self.mode then
        return self.mode
    end
    if self.requested_mode == "strip" or self.requested_mode == "page" then
        self.mode = self.requested_mode
        return self.mode
    end
    -- 一、长得像不像一页纸?正常漫画页高宽比 1.4 上下
    local sample = math.min(6, self.source.count)
    local page_like, total, uniform = 0, 0, 0
    local first_dim = self:getDim(1)
    for index = 1, sample do
        local dim = self:getDim(index)
        if dim then
            total = total + 1
            local ratio = dim.h / dim.w
            if ratio >= 1.15 and ratio <= 1.95 then
                page_like = page_like + 1
            end
            if first_dim and dim.w == first_dim.w and dim.h == first_dim.h then
                uniform = uniform + 1
            end
        end
    end
    if total == 0 then
        self.mode = "page"
        return self.mode
    end
    if page_like * 2 >= total then
        self.mode = "page"
        logger.info("KoComic: 排版=单页(样本", total, "页型", page_like, ")")
        return self.mode
    end
    -- 二、不像页,那就看碎块之间接不接得上:接得上是条漫,接不上多半是跨页扫描
    local continuous, hits, checked = self:seamsLookContinuous()
    if continuous == nil then
        self.mode = (uniform * 5 >= total * 4) and "strip" or "page"
    else
        self.mode = continuous and "strip" or "page"
    end
    logger.info("KoComic: 排版=" .. self.mode, "(样本", total, "页型", page_like,
        "接缝连续", tostring(hits) .. "/" .. tostring(checked), ")")
    return self.mode
end

--- 用之前先叫这个:定模式、放好第一屏的光标。
function Pager:start()
    local mode = self:detectMode()
    -- 判型时是按原尺寸解的,条漫模式要的是缩到一屏宽的,清掉重来
    self:clearCache()
    if mode == "strip" then
        self.cursors[1] = { index = 1, y = 0 }
    else
        local views = self:viewsFor(1)
        self.cursors[1] = { index = 1, half = views[1] }
    end
    return mode
end

-- —————————————— 单页模式 ——————————————

--- 这张图要拆成几屏:跨页大图拆两半,其它就一屏
function Pager:viewsFor(index)
    local dim = self:getDim(index)
    if dim and self.split_spread ~= "none" and dim.w / dim.h > 1.15 then
        if self.split_spread == "ltr" then
            return { "left", "right" }
        end
        return { "right", "left" }    -- 日漫从右往左读
    end
    return { false }
end

local function nextPageCursor(self, cursor)
    local views = self:viewsFor(cursor.index)
    for i, half in ipairs(views) do
        if half == cursor.half and views[i + 1] ~= nil then
            return { index = cursor.index, half = views[i + 1] }
        end
    end
    local next_index = cursor.index + 1
    if next_index > self.source.count then
        return self:firstExtraCursor()
    end
    return { index = next_index, half = self:viewsFor(next_index)[1] }
end

function Pager:composePage(cursor)
    local bb, err = self:getImage(cursor.index)
    if not bb then
        return nil, err
    end
    local width, height = ImageUtil.size(bb)
    local src_x, src_w = 0, width
    if cursor.half == "left" then
        src_w = math.floor(width / 2)
    elseif cursor.half == "right" then
        src_x = math.floor(width / 2)
        src_w = width - src_x
    end
    -- 先算好缩放比,再把要用的那半边裁出来缩
    local scale = math.min(self.page_w / src_w, self.page_h / height)
    local draw_w = math.max(1, math.floor(src_w * scale + 0.5))
    local draw_h = math.max(1, math.floor(height * scale + 0.5))
    local page = ImageUtil.newPage(self.page_w, self.page_h, bb:getType())
    local piece = bb
    if src_x > 0 or src_w ~= width then
        piece = ImageUtil.newPage(src_w, height, bb:getType())
        ImageUtil.blit(piece, bb, 0, 0, src_x, 0, src_w, height)
    end
    local scaled = piece
    if draw_w ~= src_w or draw_h ~= height then
        scaled = ImageUtil.scaleTo(piece, draw_w, draw_h)   -- 不释放来源,下面自己收拾
    end
    ImageUtil.blit(page, scaled, math.floor((self.page_w - draw_w) / 2),
        math.floor((self.page_h - draw_h) / 2), 0, 0, draw_w, draw_h)
    if scaled ~= piece then
        ImageUtil.free(scaled)
    end
    if piece ~= bb then
        ImageUtil.free(piece)
    end
    return page, nextPageCursor(self, cursor)
end

-- —————————————— 条漫模式 ——————————————

--- 在页面下沿附近找一条干净的横线来切,免得把分镜从中间劈开。
-- 从底往上找连续的空白带,找到就切在带子中间;找不到就老实按整页切。
-- @return 切口的 y(等于 page_h 表示不用调整)
local function findCut(page, page_h, min_ratio, blank_ink, blank_rows)
    min_ratio = min_ratio or 0.82
    blank_ink = blank_ink or 0.01
    blank_rows = blank_rows or 3
    local lowest = math.floor(page_h * min_ratio)
    local band_end, band = nil, 0
    for y = page_h - 1, lowest, -1 do
        if ImageUtil.rowInk(page, y) <= blank_ink then
            if band == 0 then
                band_end = y
            end
            band = band + 1
            if band >= blank_rows then
                -- 继续往上把整条空白带吃完,然后切在带子中间
                local top = y
                while top > lowest and ImageUtil.rowInk(page, top - 1) <= blank_ink do
                    top = top - 1
                end
                return math.floor((top + band_end) / 2) + 1
            end
        else
            band = 0
        end
    end
    return page_h
end

--- 切口往回收的时候,把光标退回到对应的位置
local function rewind(pieces, amount)
    for i = #pieces, 1, -1 do
        local piece = pieces[i]
        local back = math.min(amount, piece.h)
        piece.h = piece.h - back
        amount = amount - back
        if piece.h > 0 then
            return { index = piece.index, y = piece.src_y + piece.h }
        end
        if amount <= 0 then
            return { index = piece.index, y = piece.src_y }
        end
    end
    local first = pieces[1]
    return { index = first and first.index or 1, y = first and first.src_y or 0 }
end

function Pager:composeStrip(cursor)
    local index, y = cursor.index, cursor.y
    local first    -- 开头几张要是坏的/下不来,跳过它们
    while index <= self.source.count do
        first = self:getImage(index)
        if first then
            break
        end
        index = index + 1
        y = 0
    end
    if not first then
        return nil, nil, "这一段的图都取不到"
    end
    local page = ImageUtil.newPage(self.page_w, self.page_h, first:getType())
    local pieces = {}
    local filled = 0
    while filled < self.page_h and index <= self.source.count do
        local bb = self:getImage(index)
        if not bb then
            index = index + 1     -- 这张下不来或者坏了,跳过
            y = 0
        else
            local img_w, img_h = ImageUtil.size(bb)
            local take = math.min(img_h - y, self.page_h - filled)
            if take > 0 then
                ImageUtil.blit(page, bb, 0, filled, 0, y, math.min(self.page_w, img_w), take)
                pieces[#pieces + 1] = { index = index, src_y = y, h = take }
                filled = filled + take
                y = y + take
            end
            if y >= img_h then
                index = index + 1
                y = 0
            end
        end
    end
    local next_cursor = { index = index, y = y }
    local has_more = index <= self.source.count
    if filled >= self.page_h and has_more then
        local cut = findCut(page, self.page_h)
        if cut < self.page_h then
            ImageUtil.whiteOut(page, 0, cut, self.page_w, self.page_h - cut)
            next_cursor = rewind(pieces, self.page_h - cut)
        end
    end
    if not has_more then
        next_cursor = self:firstExtraCursor()
    end
    return page, next_cursor
end

-- —————————————— 对外:一屏一屏地走 ——————————————

--- 画第 n 屏。返回一张 page_w × page_h 的图,用完记得 ImageUtil.free。
function Pager:render(n)
    local cursor = self.cursors[n]
    if not cursor then
        return nil
    end
    if cursor.extra then
        local renderer = self.extras and self.extras[cursor.extra]
        if not renderer then
            return nil
        end
        local ok, page = pcall(renderer)
        if not ok or not page then
            return nil, "吐槽页画不出来"
        end
        if self.extras[cursor.extra + 1] then
            self.cursors[n + 1] = { extra = cursor.extra + 1 }
        end
        return page
    end
    local page, next_cursor, err
    if self.mode == "strip" then
        page, next_cursor, err = self:composeStrip(cursor)
    else
        page, next_cursor, err = self:composePage(cursor)
    end
    if not page then
        return nil, err
    end
    if next_cursor then
        self.cursors[n + 1] = next_cursor
    end
    return page
end

function Pager:hasNext(n)
    return self.cursors[n + 1] ~= nil
end

--- 当前这屏读到第几张原图了(给进度条看的)
function Pager:sourceIndex(n)
    local cursor = self.cursors[n]
    if not cursor or cursor.extra then
        return self.source.count
    end
    return cursor.index
end

--- 这一屏是吐槽页吗(给页脚显示用)
function Pager:isExtra(n)
    local cursor = self.cursors[n]
    return cursor ~= nil and cursor.extra ~= nil
end

--- 走完全程,一屏一屏交给 callback(bb, n)。callback 返回 false 就中止。
function Pager:forEachPage(callback)
    self:start()
    local n = 1
    while true do
        local page, err = self:render(n)
        if not page then
            return n - 1, err
        end
        local go_on = callback(page, n)
        ImageUtil.free(page)
        if go_on == false then
            return n
        end
        if not self:hasNext(n) then
            return n
        end
        n = n + 1
    end
end

return Pager
